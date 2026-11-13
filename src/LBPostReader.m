#import "LB.h"
#import "LBPostReader.h"
#import "LBMdStore.h"
#import "LBDiagramPreview.h"
#import "LBMemos.h"
#import "LBPostEditor.h"
#import "LBMarkdown.h"
#import "LBNavigationController.h"
#import <WebKit/WebKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuickLook/QuickLook.h>
#import <AVKit/AVKit.h>

static NSString *LBReaderString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
// Full absolute dates in the reader, independent of list-relative LBDateText.
static NSString *LBReaderDateText(id value, id original) {
  double milliseconds = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0;
  NSDate *date = isfinite(milliseconds) && milliseconds > 0 && milliseconds < 253402300800000.0 ? [NSDate dateWithTimeIntervalSince1970:milliseconds / 1000.0] : nil;
  if (!date) {
    NSString *text = LBReaderString(original).length ? LBReaderString(original) : LBReaderString(value);
    if (text.length) {
      NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
      iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
      date = [iso dateFromString:text];
      if (!date) { iso.formatOptions = NSISO8601DateFormatWithInternetDateTime; date = [iso dateFromString:text]; }
      if (!date) for (NSString *format in @[@"yyyy-MM-dd HH:mm:ss.SSSZ", @"yyyy-MM-dd HH:mm:ssZ", @"yyyy-MM-dd"]) {
        NSDateFormatter *parser = [NSDateFormatter new]; parser.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; parser.dateFormat = format; parser.lenient = NO;
        date = [parser dateFromString:text]; if (date) break;
      }
    }
  }
  if (!date) return @"";
  NSDateFormatter *format = [NSDateFormatter new]; format.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"]; format.dateFormat = @"yyyy年MM月dd日 HH:mm:ss";
  return [format stringFromDate:date];
}
static BOOL LBReaderHTTPS(NSURL *url) {
  return [url.scheme.lowercaseString isEqualToString:@"https"] && url.host.length && !url.user.length && !url.password.length && url.absoluteString.length <= 4096;
}
static BOOL LBReaderSameOrigin(NSURL *a, NSURL *b) {
  return LBReaderHTTPS(a) && LBReaderHTTPS(b) && [a.host.lowercaseString isEqualToString:b.host.lowercaseString] &&
    (a.port.integerValue ?: 443) == (b.port.integerValue ?: 443);
}

#pragma mark - Read-only article asset capability (never exposed to memos)
@interface LBReaderResources : NSObject <WKURLSchemeHandler>
@property (nonatomic, readonly) NSURL *rootURL;
@property (nonatomic, readonly) NSString *host;
- (instancetype)initWithRoot:(NSURL *)root;
- (NSURL *)fileForURL:(NSURL *)url;
@end
@implementation LBReaderResources
- (instancetype)initWithRoot:(NSURL *)root {
  if ((self = [super init])) {
    _rootURL = root.URLByResolvingSymlinksInPath.URLByStandardizingPath;
    _host = NSUUID.UUID.UUIDString.lowercaseString;
  }
  return self;
}
- (NSURL *)fileForURL:(NSURL *)url {
  if (![url.scheme.lowercaseString isEqualToString:@"lbreader-resource"] ||
      ![url.host.lowercaseString isEqualToString:_host] || url.user.length || url.password.length || url.port || url.query.length || url.fragment.length) return nil;
  // Decode exactly once; reject separators, traversal and non-canonical paths.
  NSString *encoded = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].percentEncodedPath;
  NSArray<NSString *> *parts = [encoded componentsSeparatedByString:@"/"];
  if (parts.count != 4 || ![parts[1] isEqualToString:@"assets"]) return nil;
  NSString *note = parts[2].stringByRemovingPercentEncoding, *name = parts[3].stringByRemovingPercentEncoding;
  NSCharacterSet *ids = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
  if (!note.length || note.length > 200 || [note rangeOfCharacterFromSet:ids.invertedSet].location != NSNotFound || !name.length || name.length > 255 ||
      [name isEqualToString:@"."] || [name isEqualToString:@".."] || [name containsString:@"/"] || [name containsString:@"\\"] ||
      [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
  // A capability belongs to the selected root at creation time. Never rebind an
  // open reader to a newly selected folder. The store maps canonical /assets/ID/
  // references to flat OR per-article layout without creating directories.
  NSURL *activeRoot = LBMdStore.shared.articlesFolderURL.URLByResolvingSymlinksInPath.URLByStandardizingPath;
  if (![activeRoot.path isEqualToString:_rootURL.path]) return nil;
  NSURL *file = [LBMdStore.shared resourceURLForLocalPath:encoded];
  if (!file.isFileURL) return nil;
  // The store rejects symlink components; retain containment/regular-file guards
  // here as defence in depth before exposing bytes to WebKit or native preview.
  NSURL *resolved = file.URLByResolvingSymlinksInPath.URLByStandardizingPath;
  if (![resolved.path isEqualToString:file.URLByStandardizingPath.path] || ![resolved.path hasPrefix:[_rootURL.path stringByAppendingString:@"/"]]) return nil;
  NSNumber *regular = nil, *size = nil;
  if (![resolved getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil] || !regular.boolValue ||
      ![resolved getResourceValue:&size forKey:NSURLFileSizeKey error:nil] || size.unsignedLongLongValue > 256ULL * 1024 * 1024) return nil;
  return resolved;
}
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
  NSURL *file = [self fileForURL:task.request.URL];
  UTType *type = file ? [UTType typeWithFilenameExtension:file.pathExtension] : nil;
  NSString *mime = type.preferredMIMEType;
  NSSet *allowedMedia = [NSSet setWithArray:@[
    @"image/png", @"image/jpeg", @"image/gif", @"image/webp", @"image/heic", @"image/heif", @"image/avif", @"image/bmp", @"image/tiff",
    @"application/pdf",
    @"audio/mpeg", @"audio/mp4", @"audio/wav", @"audio/x-m4a", @"audio/aac", @"audio/ogg", @"audio/webm",
    @"video/mp4", @"video/quicktime", @"video/webm", @"video/x-m4v"
  ]];
  NSDictionary *attrs = file ? [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil] : nil;
  if (!file || ![task.request.HTTPMethod isEqualToString:@"GET"] || ![allowedMedia containsObject:mime ?: @""] || [attrs fileSize] > 256ULL * 1024 * 1024) {
    [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNoPermissionsToReadFile userInfo:nil]]; return;
  }
  NSData *data = [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:nil];
  if (!data || data.length > 256ULL * 1024 * 1024) { [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotOpenFile userInfo:nil]]; return; }
  NSURLResponse *response = [[NSURLResponse alloc] initWithURL:task.request.URL MIMEType:mime expectedContentLength:data.length textEncodingName:nil];
  [task didReceiveResponse:response]; [task didReceiveData:data]; [task didFinish];
}
- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task { /* synchronous, no retained task or transport */ }
@end

#pragma mark - Bounded native image preview
@interface LBReaderImageController () <UIScrollViewDelegate, NSURLSessionDataDelegate, UIGestureRecognizerDelegate>
@end
@implementation LBReaderImageController {
  NSURL *_url;
  NSURL *_localFile;
  UIScrollView *_scroll;
  UIImageView *_image;
  UILabel *_status;
  UIButton *_retry;
  NSURLSession *_session;
  NSMutableData *_bytes;
  BOOL _accepted;
  NSUInteger _imageGeneration;
  CGSize _fitViewport;
  UIPanGestureRecognizer *_panDismiss;
}
- (instancetype)initWithURL:(NSURL *)url { if ((self = [super init])) _url = url; return self; }
- (instancetype)initWithLocalFile:(NSURL *)file { if ((self = [super init])) { _localFile = file; } return self; }
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.blackColor;
  self.title = @"图片预览";
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
  _scroll = [UIScrollView new]; _scroll.delegate = self; _scroll.translatesAutoresizingMaskIntoConstraints = NO;
  _scroll.minimumZoomScale = 1; _scroll.maximumZoomScale = 5; _scroll.bouncesZoom = YES;
  [self.view addSubview:_scroll];
  [NSLayoutConstraint activateConstraints:@[
    [_scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [_scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    [_scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [_scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor]]];
  _image = [UIImageView new]; _image.contentMode = UIViewContentModeScaleAspectFit;
  _image.accessibilityLabel = @"文章图片；双指缩放，双击放大，下滑退出"; _image.isAccessibilityElement = YES;
  [_scroll addSubview:_image];
  UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(zoom:)];
  doubleTap.numberOfTapsRequired = 2; [_scroll addGestureRecognizer:doubleTap];
  _panDismiss = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanDismiss:)];
  _panDismiss.delegate = self;
  [self.view addGestureRecognizer:_panDismiss];
  _status = [UILabel new]; _status.textColor = UIColor.whiteColor; _status.textAlignment = NSTextAlignmentCenter;
  _status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; _status.numberOfLines = 0;
  _status.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:_status];
  _retry = [UIButton buttonWithType:UIButtonTypeSystem]; [_retry setTitle:@"重试" forState:UIControlStateNormal];
  _retry.translatesAutoresizingMaskIntoConstraints = NO; [_retry addTarget:self action:@selector(loadImage) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:_retry];
  [NSLayoutConstraint activateConstraints:@[
    [_status.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
    [_status.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor],
    [_status.widthAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor multiplier:.85],
    [_retry.topAnchor constraintEqualToAnchor:_status.bottomAnchor constant:12],
    [_retry.centerXAnchor constraintEqualToAnchor:_status.centerXAnchor]]];
  [self loadImage];
}
- (void)loadImage {
  _imageGeneration++;
  [_session invalidateAndCancel]; _session = nil; _bytes = [NSMutableData data]; _accepted = NO;
  if (_localFile && _localFile.isFileURL) {
    _status.hidden = YES; _retry.hidden = YES;
    NSUInteger generation = _imageGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)self->_localFile, NULL);
      UIImage *decoded = nil;
      if (source) {
        CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
          (id)kCGImageSourceCreateThumbnailFromImageAlways:@YES, (id)kCGImageSourceCreateThumbnailWithTransform:@YES,
          (id)kCGImageSourceThumbnailMaxPixelSize:@2560, (id)kCGImageSourceShouldCacheImmediately:@YES});
        if (image) { decoded = [UIImage imageWithCGImage:image]; CGImageRelease(image); }
        CFRelease(source);
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) owner = weakSelf;
        if (!owner || generation != owner->_imageGeneration) return;
        if (!decoded) { [owner failImage]; return; }
        owner->_image.image = decoded; owner->_status.hidden = YES; owner->_retry.hidden = YES;
        [owner fitImage];
      });
    });
    return;
  }
  _status.text = @"正在加载图片…"; _status.hidden = NO; _retry.hidden = YES;
  NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  cfg.HTTPCookieStorage = nil; cfg.HTTPShouldSetCookies = NO; cfg.URLCache = nil; cfg.URLCredentialStorage = nil;
  cfg.timeoutIntervalForRequest = 25; cfg.timeoutIntervalForResource = 45;
  _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:NSOperationQueue.mainQueue];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_url];
  [request setValue:@"image/*" forHTTPHeaderField:@"Accept"];
  [[_session dataTaskWithRequest:request] resume];
}
- (void)failImage {
  _status.hidden = NO; _status.text = @"图片暂不可用或超过 12 MB，点按重试"; _retry.hidden = NO;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
  completionHandler(LBReaderSameOrigin(request.URL, _url) ? request : nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
  if (session != _session || ![response isKindOfClass:NSHTTPURLResponse.class]) { completionHandler(NSURLSessionResponseCancel); return; }
  NSString *mime = response.MIMEType.lowercaseString;
  NSInteger status = [(NSHTTPURLResponse *)response statusCode];
  _accepted = LBReaderSameOrigin(response.URL, _url) && status >= 200 && status < 300 &&
    [mime hasPrefix:@"image/"] && ![mime isEqualToString:@"image/svg+xml"] && response.expectedContentLength <= 12 * 1024 * 1024;
  completionHandler(_accepted ? NSURLSessionResponseAllow : NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
  if (session != _session) { [task cancel]; return; }
  if (_bytes.length + data.length > 12 * 1024 * 1024) { _accepted = NO; [_bytes setLength:0]; [task cancel]; return; }
  [_bytes appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  if (session != _session) { [session finishTasksAndInvalidate]; return; }
  NSUInteger generation = _imageGeneration;
  NSData *data = (!error && _accepted && _bytes.length) ? [_bytes copy] : nil;
  _bytes = nil; _session = nil; [session finishTasksAndInvalidate];
  // Mutable transfer state is main-queue confined; decode an immutable snapshot.
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    UIImage *decoded = nil;
    if (data.length) {
      CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@NO});
      if (source) {
        CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
          (id)kCGImageSourceCreateThumbnailFromImageAlways:@YES, (id)kCGImageSourceCreateThumbnailWithTransform:@YES,
          (id)kCGImageSourceThumbnailMaxPixelSize:@2560, (id)kCGImageSourceShouldCacheImmediately:@YES});
        if (image) { decoded = [UIImage imageWithCGImage:image]; CGImageRelease(image); }
        CFRelease(source);
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) owner = weakSelf;
      if (!owner || generation != owner->_imageGeneration) return;
      if (!decoded) { [owner failImage]; return; }
      owner->_image.image = decoded; owner->_status.hidden = YES; owner->_retry.hidden = YES;
      [owner fitImage];
    });
  });
}
- (void)fitImage {
  if (!_image.image || _scroll.bounds.size.width <= 0 || _scroll.bounds.size.height <= 0) return;
  _fitViewport = _scroll.bounds.size;
  _scroll.zoomScale = 1;
  CGSize size = _image.image.size, bounds = _scroll.bounds.size;
  CGFloat scale = MIN(bounds.width / size.width, bounds.height / size.height);
  _image.frame = CGRectMake(0, 0, size.width * scale, size.height * scale);
  _scroll.contentSize = _image.frame.size; [self centerImage];
}
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (!CGSizeEqualToSize(_fitViewport, _scroll.bounds.size)) [self fitImage];
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { return _image; }
- (void)scrollViewDidZoom:(UIScrollView *)scrollView { [self centerImage]; }
- (void)centerImage {
  CGSize b = _scroll.bounds.size, s = _scroll.contentSize;
  _image.center = CGPointMake(MAX(b.width, s.width) / 2, MAX(b.height, s.height) / 2);
}
- (void)zoom:(UITapGestureRecognizer *)tap {
  if (_scroll.zoomScale > 1.1) { [_scroll setZoomScale:1 animated:YES]; return; }
  CGPoint p = [tap locationInView:_image]; CGSize b = _scroll.bounds.size;
  [_scroll zoomToRect:CGRectMake(p.x-b.width/6, p.y-b.height/6, b.width/3, b.height/3) animated:YES];
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
  if (gestureRecognizer == _panDismiss) {
    if (_scroll.zoomScale > 1.05 && _scroll.contentOffset.y > 5) return NO;
    CGPoint v = [_panDismiss velocityInView:self.view];
    return v.y > 0 && fabs(v.y) > fabs(v.x);
  }
  return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
  if (g == _panDismiss) return YES;
  return NO;
}
- (void)handlePanDismiss:(UIPanGestureRecognizer *)pan {
  CGPoint t = [pan translationInView:self.view];
  if (t.y < 0) t.y = 0;
  if (pan.state == UIGestureRecognizerStateChanged) {
    CGFloat progress = MIN(1.0, t.y / 240.0);
    CGFloat scale = 1.0 - progress * 0.25;
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:MAX(0.1, 1.0 - progress * 0.75)];
    _scroll.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(0, t.y), scale, scale);
  } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
    CGPoint v = [pan velocityInView:self.view];
    if (t.y > 60 || v.y > 450) {
      [self close];
    } else {
      [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0 options:0 animations:^{
        self.view.backgroundColor = UIColor.blackColor;
        self->_scroll.transform = CGAffineTransformIdentity;
      } completion:nil];
    }
  }
}
- (void)stopImageLoad {
  _imageGeneration++;
  [_session invalidateAndCancel]; _session = nil; _bytes = nil; _accepted = NO;
}
- (void)close { [self stopImageLoad]; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self stopImageLoad]; }
- (void)dealloc { [_session invalidateAndCancel]; }
@end

#pragma mark - Non-recognizing touch observer
// Observe touch-down, not pan recognition/touch-up. A tap, long press or a pan
// shorter than UIKit's recognition threshold must revoke pending top resets too.
@interface LBReaderTouchObserver : UIGestureRecognizer
@property (nonatomic, copy) void (^onTouch)(void);
@end
@implementation LBReaderTouchObserver
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (self.onTouch) self.onTouch();
  self.state = UIGestureRecognizerStateFailed;
}
@end

#pragma mark - Weak bridge, isolated from page JavaScript
@interface LBReaderBridge : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end
@implementation LBReaderBridge
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
  [self.target userContentController:controller didReceiveScriptMessage:message];
}
@end

@interface LBPostReaderViewController () <WKNavigationDelegate, WKScriptMessageHandler, QLPreviewControllerDataSource>
@end
@implementation LBPostReaderViewController {
  NSDictionary *_post;
  WKWebView *_web;
  WKContentWorld *_world;
  NSURL *_entry, *_site;
  LBReaderResources *_resources;
  NSURL *_previewFile;
  NSString *_token;
  UIView *_notice;
  UIActivityIndicatorView *_spinner;
  BOOL _ready, _rendered;
  // Initial positioning is a load-scoped capability, revoked on ANY native or
  // DOM interaction. Layout/font/diagram callbacks can never re-arm it.
  BOOL _initialTopPending, _initialTopDOMSettled;
  NSUInteger _initialTopCompletionGeneration;
  NSUInteger _loadGeneration;
}
- (instancetype)initWithPost:(NSDictionary *)post {
  if ((self = [super init])) {
    _post = [post copy];
    // Always reload the store's canonical body for saved articles. Unsaved
    // editor/memo previews retain their current body and explicit bodyFormat.
    if (![self memoPreview] && ![_post[@"isEditorPreview"] boolValue] && LBReaderString(_post[@"id"]).length) {
      NSDictionary *full = [LBMdStore.shared loadArticle:_post[@"id"]];
      if (full) { NSMutableDictionary *merged = [_post mutableCopy]; [merged addEntriesFromDictionary:full]; _post = merged; }
    }
  }
  return self;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = LBTheme.paper;
  if ([self memoPreview]) [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(memosConnectionChanged:) name:LBMemosDidChange object:nil];
  // Article title belongs to the site-styled document header, never duplicated in chrome.
  self.navigationItem.title = [self memoPreview] ? ([self hasPublishedDate] ? @"说说预览" : @"草稿预览") : @"";
  self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
  self.navigationItem.subtitle = nil;
  if ([self memoPreview] || [_post[@"isEditorPreview"] boolValue]) {
    // Previews never edit/publish/delete underneath the open editor.
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closePreview)];
  } else {
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis"] menu:[self postActionMenu]];
  }
  NSString *base = LBStore.siteURL ?: @"https://huowenlong.com";
  if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
  _site = [NSURL URLWithString:base];
  if ([_post[@"readerBaseURL"] isKindOfClass:NSString.class]) _site = [NSURL URLWithString:_post[@"readerBaseURL"]];

  NSURL *dir = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Reader" isDirectory:YES];
  _entry = [dir URLByAppendingPathComponent:@"index.html"];
  _token = NSUUID.UUID.UUIDString; _world = [WKContentWorld worldWithName:@"LongBlogReader"];
  WKWebViewConfiguration *config = [WKWebViewConfiguration new];
  if (![self memoPreview]) {
    _resources = [[LBReaderResources alloc] initWithRoot:LBMdStore.shared.articlesFolderURL];
    [config setURLSchemeHandler:_resources forURLScheme:@"lbreader-resource"];
  }
  config.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
  config.defaultWebpagePreferences.allowsContentJavaScript = YES;
  config.preferences.javaScriptCanOpenWindowsAutomatically = NO;
  LBReaderBridge *proxy = [LBReaderBridge new]; proxy.target = self;
  [config.userContentController addScriptMessageHandler:proxy contentWorld:_world name:@"reader"];
  static NSString *cachedReaderScript = nil;
  static dispatch_once_t scriptOnce;
  dispatch_once(&scriptOnce, ^{
    NSMutableString *joined = [NSMutableString string];
    for (NSString *name in @[ @"vendor/marked.umd.js", @"vendor/katex.min.js", @"vendor/site-highlight.js", @"vendor/mermaid.min.js", @"reader-mermaid.js", @"reader.js" ]) {
      NSString *source = [NSString stringWithContentsOfURL:[dir URLByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];
      if (source) [joined appendFormat:@"\n%@\n;", source];
    }
    cachedReaderScript = [joined copy];
  });
  if (!cachedReaderScript.length) { [self showFailure:@"阅读器资源缺失，请更新应用后重试。"]; return; }
  NSMutableString *script = [cachedReaderScript mutableCopy];
  // Trusted, constant memo-only chrome; author Markdown never becomes CSS or JS.
  // Keep shared Reader assets/article rendering unchanged and preserve their CSP.
  if ([self memoPreview]) [script appendString:
      @"\n(()=>{document.documentElement.classList.add('lb-memo-preview');"
       "const style=document.createElement('style');style.textContent='html.lb-memo-preview #title:empty,html.lb-memo-preview #meta:empty{display:none}html.lb-memo-preview .memo-preview-empty{color:var(--muted-foreground);text-align:center;padding:48px 0}';document.head.appendChild(style);"
       "window.LBMemoPreviewDidRender=payload=>{if(!payload.markdown.trim()){const p=document.createElement('p');p.className='memo-preview-empty';p.textContent='暂无内容';p.setAttribute('role','status');document.getElementById('content').replaceChildren(p);}};})();"];
  [script appendFormat:@"\n(()=>{const token='%@';const send=b=>window.webkit.messageHandlers.reader.postMessage({...b,token});window.LBReaderRender=payload=>{try{const result=window.LBReader.render(payload,document,send);if(payload.isMemo)window.LBMemoPreviewDidRender(payload);return result}catch(e){send({type:'error',value:''});throw new Error('Reader render failed')}};send({type:'ready',value:''});})();", _token];
  WKUserScript *userScript = [[WKUserScript alloc] initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES inContentWorld:_world];
  [config.userContentController addUserScript:userScript];
  _web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
  _web.navigationDelegate = self; _web.translatesAutoresizingMaskIntoConstraints = NO;
  _web.opaque = NO; _web.backgroundColor = LBTheme.paper;
  _web.scrollView.backgroundColor = UIColor.clearColor;
  // Article (and memo preview) WebKit lives inside the safe area. UIKit must not
  // add/restore a second navigation-bar inset after JS positioned the document at zero.
  _web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  _web.scrollView.automaticallyAdjustsScrollIndicatorInsets = NO;
  LBReaderTouchObserver *touchObserver = [LBReaderTouchObserver new];
  touchObserver.cancelsTouchesInView = NO; touchObserver.delaysTouchesBegan = NO; touchObserver.delaysTouchesEnded = NO;
  __weak typeof(self) weakTouchOwner = self;
  touchObserver.onTouch = ^{ [weakTouchOwner cancelInitialReaderTop]; };
  [_web addGestureRecognizer:touchObserver];
  [_web.scrollView.panGestureRecognizer addTarget:self action:@selector(readerPanChanged:)];
  _web.scrollView.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle;
  _web.scrollView.topEdgeEffect.hidden = YES;
  _web.scrollView.bottomEdgeEffect.hidden = YES;
  [self.view addSubview:_web];
  [NSLayoutConstraint activateConstraints:@[
    [_web.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [_web.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [_web.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [_web.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor]]];
  _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  _spinner.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:_spinner];
  [NSLayoutConstraint activateConstraints:@[[_spinner.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor], [_spinner.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor]]];
  [self retry];
}
- (void)showFailure:(NSString *)message {
  [_spinner stopAnimating]; [_notice removeFromSuperview]; _web.hidden = YES;
  __weak typeof(self) weakSelf = self;
  _notice = LBNotice(@"exclamationmark.triangle", @"文章暂时无法显示", message, @"重试", ^{ [weakSelf retry]; });
  _notice.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:_notice];
  [NSLayoutConstraint activateConstraints:@[
    [_notice.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [_notice.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    [_notice.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [_notice.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor]]];
}
- (void)cancelInitialReaderTop {
  if (!_initialTopPending) return;
  _initialTopPending = NO;
  if (_ready) [_web callAsyncJavaScript:@"window.LBReaderStopInitialTop?.();" arguments:@{} inFrame:nil inContentWorld:_world completionHandler:nil];
}
- (void)readerPanChanged:(UIPanGestureRecognizer *)pan {
  if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) [self cancelInitialReaderTop];
}
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  // Native navigation transitions and safe-area changes can finish AFTER the
  // isolated-world render callback. Keep the guarded session until both settle.
  if (_initialTopPending) [self resetReaderToTop];
  [self finishInitialReaderTopIfPossible];
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  // Does not re-arm: image/QuickLook/editor dismissal preserves reading position.
  [self finishInitialReaderTopIfPossible];
}
- (void)finishInitialReaderTopIfPossible {
  if (!_initialTopPending || !_initialTopDOMSettled || !self.view.window) return;
  NSUInteger generation = _loadGeneration;
  if (_initialTopCompletionGeneration == generation) return;
  _initialTopCompletionGeneration = generation;
  __weak typeof(self) weakSelf = self;
  void (^complete)(void) = ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) owner = weakSelf;
      if (!owner || owner->_loadGeneration != generation || !owner->_initialTopPending) return;
      [owner resetReaderToTop];
      owner->_initialTopPending = NO;
    });
  };
  id<UIViewControllerTransitionCoordinator> coordinator = self.transitionCoordinator;
  if (!coordinator || ![coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) { complete(); }]) complete();
}
// Editor preview positions itself in the DOM (caret anchor); a native reset to
// the top would fight that and land the author at the document start.
- (BOOL)positionsPreviewInDOM {
  return [_post[@"isEditorPreview"] boolValue] &&
      (LBReaderString(_post[@"previewAnchor"]).length || [_post[@"previewRatio"] doubleValue] > 0);
}
- (void)resetReaderToTop {
  if ([self positionsPreviewInDOM]) return;
  if (!_initialTopPending || !_web || _web.scrollView.dragging || _web.scrollView.tracking || _web.scrollView.decelerating) return;
  [_web layoutIfNeeded];
  UIEdgeInsets inset = _web.scrollView.adjustedContentInset;
  [_web.scrollView setContentOffset:CGPointMake(-inset.left, -inset.top) animated:NO];
}
- (void)retry {
  if (!_web) return;
  _initialTopPending = YES; _initialTopDOMSettled = NO; _initialTopCompletionGeneration = 0;
  [self resetReaderToTop];
  [_notice removeFromSuperview]; _notice = nil; _ready = NO; _rendered = NO;
  _web.hidden = NO; [_spinner startAnimating];
  NSUInteger generation = ++_loadGeneration;
  if (!LBReaderHTTPS(_site) || ![NSFileManager.defaultManager fileExistsAtPath:_entry.path]) {
    [self showFailure:@"站点地址必须为 HTTPS，且应用必须包含 Reader 资源。"]; return;
  }
  [_web loadFileURL:_entry allowingReadAccessToURL:[_entry URLByDeletingLastPathComponent]];
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    typeof(self) self = weakSelf;
    if (self && self->_loadGeneration == generation && !self->_ready) [self showFailure:@"阅读器初始化超时。请点按重试。"];
  });
}
- (BOOL)memoPreview { return [_post[@"isPrivateMemoPreview"] boolValue] || _post[@"memosGeneration"] != nil; }
- (BOOL)hasPublishedDate {
  id value = _post[@"publishedAt"];
  if (![value isKindOfClass:NSNumber.class]) return NO;
  double milliseconds = [value doubleValue];
  return isfinite(milliseconds) && milliseconds > 0 && milliseconds < 253402300800000.0;
}
- (void)closePreview {
  UINavigationController *nav = self.navigationController;
  if (nav.presentingViewController && nav.viewControllers.firstObject == self) [self dismissViewControllerAnimated:YES completion:nil];
  else [nav popViewControllerAnimated:YES];
}
- (BOOL)memosPreviewCurrent {
  return !_post[@"memosGeneration"] || [_post[@"memosGeneration"] unsignedIntegerValue] == LBMemosClient.shared.generation;
}
- (void)memosConnectionChanged:(NSNotification *)note {
  if ([self memosPreviewCurrent]) return;
  _loadGeneration++; _ready = NO; _rendered = NO;
  _post = @{@"memosGeneration":@0};
  [_web stopLoading];
  [_web loadHTMLString:@"<html><body></body></html>" baseURL:nil];
  [_web removeFromSuperview]; _web = nil;
  [self showFailure:@"Memos账户已变更，已清除此私密预览。请返回说说列表。"];
}
- (NSString *)currentMetaText {
  NSString *created = LBReaderDateText(_post[@"createdAt"], _post[@"createdAtString"]);
  NSString *updated = LBReaderDateText(_post[@"updatedAt"], _post[@"updatedAtString"]);
  NSString *published = LBReaderDateText(_post[@"publishedAt"], _post[@"publishedAtString"]);
  if ([self memoPreview]) {
    return published.length ? published : @"";
  }
  BOOL isPublished = [_post[@"publish"] boolValue];
  NSString *cDay = [created componentsSeparatedByString:@" "].firstObject;
  NSString *pDay = [published componentsSeparatedByString:@" "].firstObject;
  NSString *uDay = [updated componentsSeparatedByString:@" "].firstObject;
  if (isPublished) {
    NSString *primary = pDay.length ? pDay : (cDay.length ? cDay : @"时间未知");
    NSString *update = uDay.length ? uDay : primary;
    return [NSString stringWithFormat:@"发布：%@    更新：%@", primary, update];
  } else {
    NSString *primary = cDay.length ? cDay : (pDay.length ? pDay : @"时间未知");
    NSString *update = uDay.length ? uDay : primary;
    return [NSString stringWithFormat:@"创建：%@    更新：%@", primary, update];
  }
}

- (void)updateMetaTextInDOM {
  if (!_web) return;
  NSString *meta = [self currentMetaText];
  NSString *escaped = [[meta stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
  NSString *js = [NSString stringWithFormat:@"const m = document.getElementById('meta'); if (m) { m.textContent = '%@'; }", escaped];
  [_web evaluateJavaScript:js completionHandler:nil];
}

- (void)renderPost {
  if (!_ready || _rendered || ![self memosPreviewCurrent]) return;
  NSMutableArray *posts = [NSMutableArray array];
  for (NSDictionary *post in LBSiteData.shared.posts ?: @[]) {
    [posts addObject:@{@"id":LBReaderString(post[@"id"]), @"slug":LBReaderString(post[@"slug"]),
      @"title":LBReaderString(post[@"title"]), @"summary":LBReaderString(post[@"summary"])}];
  }
  NSString *meta = [self currentMetaText];
  BOOL editorPreview = [_post[@"isEditorPreview"] boolValue];
  BOOL allowDataImages = [_post[@"isLocalDraft"] boolValue] || [_post[@"isEditorPreview"] boolValue];
  NSDictionary *payload = @{@"html":LBReaderString(_post[@"html"]), @"title":[self memoPreview] ? @"" : LBReaderString(_post[@"title"]),
    @"meta":meta, @"summary":LBReaderString(_post[@"summary"]), @"site":_site.absoluteString, @"posts":posts,
    @"initialTopGeneration":[NSString stringWithFormat:@"%lu", (unsigned long)_loadGeneration], @"initialTopCancelled":@(!_initialTopPending),
    @"hasMarkdown":@([_post[@"markdown"] isKindOfClass:NSString.class]),
    @"bodyFormat":[self memoPreview] ? @"markdown" : LBReaderString(_post[@"bodyFormat"]),
    @"isEditorPreview":@(editorPreview), @"noteID":LBReaderString(_post[@"id"]),
    @"previewAnchor":editorPreview ? LBReaderString(_post[@"previewAnchor"]) : @"",
    @"previewRatio":@(editorPreview ? MIN(1.0, MAX(0.0, [_post[@"previewRatio"] doubleValue])) : 0.0),
    @"resourceBase":_resources ? [NSString stringWithFormat:@"lbreader-resource://%@/", _resources.host] : @"",
    @"memoSiteStyle":@([self memoPreview]),
    @"allowDataImages":@(allowDataImages),
    @"markdown":LBReaderString(_post[@"markdown"]), @"isMemo":@([self memoPreview])};
  NSUInteger generation = _loadGeneration;
  __weak typeof(self) weakSelf = self;
  [_web callAsyncJavaScript:@"return window.LBReaderRender(payload);" arguments:@{@"payload":payload} inFrame:nil inContentWorld:_world completionHandler:^(id result, NSError *error) {
    typeof(self) self = weakSelf;
    if (!self || self->_loadGeneration != generation) return;
    if (error) { [self showFailure:@"文章格式不受支持或内容过大。请重试，或使用右上角打开网页版。"]; return; }
    self->_rendered = YES; [self->_spinner stopAnimating];
    [self resetReaderToTop];
    // Re-evaluate adjusted safe-area insets on the following UIKit layout turn.
    // This is not viewDidAppear: returning from image/QuickLook keeps position.
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) owner = weakSelf;
      if (owner && owner->_loadGeneration == generation) [owner resetReaderToTop];
    });
  }];
}
- (BOOL)canActOnReader {
  UINavigationController *nav = self.navigationController;
  return self.isViewLoaded && self.view.window && nav.topViewController == self &&
      !nav.transitionCoordinator && !self.presentedViewController && !self.isBeingDismissed && !self.isMovingFromParentViewController;
}
- (BOOL)isEntry:(NSURL *)url { return url.isFileURL && [url.URLByStandardizingPath.path isEqualToString:_entry.URLByStandardizingPath.path]; }
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
  if (![self memosPreviewCurrent]) return;
  // No arbitrary page may call this bridge: isolated world + main frame + exact bundled file + nonce.
  if (message.webView != _web || !message.frameInfo.mainFrame || ![self isEntry:message.frameInfo.request.URL] ||
      ![message.name isEqualToString:@"reader"] || ![message.body isKindOfClass:NSDictionary.class]) return;
  NSDictionary *body = message.body;
  if (body.count != 3 || ![body[@"token"] isKindOfClass:NSString.class] || ![body[@"token"] isEqualToString:_token] ||
      ![body[@"type"] isKindOfClass:NSString.class] || ![body[@"value"] isKindOfClass:NSString.class]) return;
  NSString *type = body[@"type"], *value = body[@"value"];
  // Only the exact diagram action gets the larger bounded image allowance.
  // Nonce/main-frame/entry/schema validation above remains mandatory.
  if ([type isEqualToString:@"diagram"]) {
    if (!_ready || !_rendered || value.length > 8000000 || ![self canActOnReader]) return;
    NSNumber *generation = [self memoPreview] ? @(LBMemosClient.shared.generation) : nil;
    LBDiagramPreviewController *preview = [LBDiagramPreviewController previewWithDataURL:value memoGeneration:generation];
    if (preview) [self presentViewController:preview animated:YES completion:nil];
    return;
  }
  if (value.length > 262144) return;
  if ([type isEqualToString:@"ready"]) { if (!value.length && !_ready) { _ready = YES; [self renderPost]; } return; }
  if (!_ready) return;
  // Trusted renderer lifecycle, not an author-controlled article action. A
  // load-generation value prevents late Mermaid/font callbacks from an old DOM.
  if ([type isEqualToString:@"initial-top-interacted"] || [type isEqualToString:@"initial-top-settled"]) {
    if (![value isEqualToString:[NSString stringWithFormat:@"%lu", (unsigned long)_loadGeneration]]) return;
    if ([type isEqualToString:@"initial-top-interacted"]) [self cancelInitialReaderTop];
    else { _initialTopDOMSettled = YES; [self resetReaderToTop]; [self finishInitialReaderTopIfPossible]; }
    return;
  }
  if ([type isEqualToString:@"error"]) { if (!value.length) [self showFailure:@"文章解析失败。请重试或打开网页版。"]; return; }
  if (!_rendered || ![self canActOnReader]) return;
  if ([type isEqualToString:@"copy"]) { UIPasteboard.generalPasteboard.string = value; return; }
  if ([type isEqualToString:@"post"]) {
    if (value.length > 200) return;
    for (NSDictionary *post in LBSiteData.shared.posts ?: @[]) {
      if ([LBReaderString(post[@"id"]) isEqualToString:value]) {
        [self.navigationController pushViewController:[[LBPostReaderViewController alloc] initWithPost:post] animated:YES]; return;
      }
    }
    return;
  }
  if (value.length > 4096 || [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return;
  NSURL *url = [NSURL URLWithString:value];
  if (![self memoPreview] && [url.scheme.lowercaseString isEqualToString:@"lbreader-resource"]) {
    NSURL *file = [_resources fileForURL:url];
    if (!file) return;
    UTType *fileType = [UTType typeWithFilenameExtension:file.pathExtension];
    if ([type isEqualToString:@"image"] && [fileType conformsToType:UTTypeImage]) {
      UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[[LBReaderImageController alloc] initWithLocalFile:file]];
      navigation.modalPresentationStyle = UIModalPresentationFullScreen;
      [self presentViewController:navigation animated:YES completion:nil];
    } else if ([type isEqualToString:@"attachment"]) {
      if ([fileType conformsToType:UTTypeAudio] || [fileType conformsToType:UTTypeMovie]) {
        AVPlayerViewController *player = [AVPlayerViewController new]; player.player = [AVPlayer playerWithURL:file];
        [self presentViewController:player animated:YES completion:^{ [player.player play]; }];
      } else {
        _previewFile = file;
        QLPreviewController *preview = [QLPreviewController new]; preview.dataSource = self;
        [self presentViewController:preview animated:YES completion:nil];
      }
    }
    return;
  }
  if (!LBReaderHTTPS(url)) return;
  if ([type isEqualToString:@"image"] && LBReaderSameOrigin(url, _site)) {
    if (self.presentedViewController) return;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[[LBReaderImageController alloc] initWithURL:url]];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
  } else if ([type isEqualToString:@"attachment"]) {
    UTType *fileType = [UTType typeWithFilenameExtension:url.pathExtension];
    if ([fileType conformsToType:UTTypeAudio] || [fileType conformsToType:UTTypeMovie]) {
      AVPlayerViewController *player = [AVPlayerViewController new]; player.player = [AVPlayer playerWithURL:url];
      [self presentViewController:player animated:YES completion:^{ [player.player play]; }];
    } else {
      __weak typeof(self) weakSelf = self;
      NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (!location || error) {
          dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf openLink:url]; });
          return;
        }
        // `?f=a.pdf` style URLs have lastPathComponent "/", which previously
        // resolved to tmp itself and removed the whole temporary directory.
        NSString *name = url.lastPathComponent.length > 1 ? url.lastPathComponent : @"document.pdf";
        NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        NSURL *destURL = [folder URLByAppendingPathComponent:name];
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 200;
        if (status < 200 || status >= 300 ||
            ![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil] ||
            ![NSFileManager.defaultManager moveItemAtURL:location toURL:destURL error:nil]) {
          dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf openLink:url]; });
          return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          LBPostReaderViewController *strongSelf = weakSelf;
          if (!strongSelf) return;
          strongSelf->_previewFile = destURL;
          QLPreviewController *preview = [QLPreviewController new]; preview.dataSource = strongSelf;
          [strongSelf presentViewController:preview animated:YES completion:nil];
        });
      }];
      [task resume];
    }
  } else if ([type isEqualToString:@"link"]) [self openLink:url];
}
- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller { return _previewFile ? 1 : 0; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index { return _previewFile; }
- (void)openLink:(NSURL *)url {
  if (![self canActOnReader] || !LBReaderHTTPS(url)) return;
  if (LBReaderSameOrigin(url, _site)) {
    NSArray<NSString *> *parts = url.path.pathComponents;
    if (parts.count == 3 && [parts[1] isEqualToString:@"blog"]) {
      NSString *key = parts[2].stringByRemovingPercentEncoding ?: parts[2];
      for (NSDictionary *post in LBSiteData.shared.posts ?: @[]) {
        if ([LBReaderString(post[@"slug"]) isEqualToString:key] || [LBReaderString(post[@"id"]) isEqualToString:key]) {
          [self.navigationController pushViewController:[[LBPostReaderViewController alloc] initWithPost:post] animated:YES]; return;
        }
      }
      UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文章尚未同步" message:@"返回文章列表下拉刷新后重试。" preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
      [self presentViewController:alert animated:YES completion:nil]; return;
    }
  }
  LBOpenURL(self, url);
}
- (void)showArticleDetails {
  if (![self canActOnReader] || [self memoPreview]) return;
  NSMutableArray<NSString *> *lines = [NSMutableArray array];
  for (NSArray<NSString *> *field in @[@[@"创建", @"createdAt", @"createdAtString"], @[@"发布", @"publishedAt", @"publishedAtString"], @[@"更新", @"updatedAt", @"updatedAtString"]]) {
    NSString *exact = LBReaderDateText(_post[field[1]], _post[field[2]]);
    // Preserve unparseable legacy metadata verbatim, rather than silently lose
    // it. A missing publication time must not be synthesized from creation.
    NSString *original = LBReaderString(_post[field[2]]);
    if (!original.length) original = LBReaderString(_post[field[1]]);
    NSString *display = exact.length ? exact : (original.length ? original : @"未记录");
    [lines addObject:[NSString stringWithFormat:@"%@：%@", field[0], display]];
  }
  NSString *zone = NSTimeZone.localTimeZone.name;
  [lines addObject:[NSString stringWithFormat:@"\n时区：%@（当前设备）", zone]];
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"详情" message:[lines componentsJoinedByString:@"\n"] preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}
- (UIMenu *)postActionMenu {
  __weak typeof(self) weakSelf = self;
  UIAction *details = [UIAction actionWithTitle:@"详情" image:[UIImage systemImageNamed:@"info.circle"] identifier:nil handler:^(UIAction *a) {
    [weakSelf showArticleDetails];
  }];
  UIAction *edit = [UIAction actionWithTitle:@"编辑文章" image:[UIImage systemImageNamed:@"square.and.pencil"] identifier:nil handler:^(UIAction *a) {
    [weakSelf editCurrentPost];
  }];
  UIAction *publish = [UIAction actionWithTitle:@"发布文章" image:[UIImage systemImageNamed:@"paperplane"] identifier:nil handler:^(UIAction *a) {
    [weakSelf publishCurrentPost];
  }];
  UIAction *unpub = [UIAction actionWithTitle:@"下架文章" image:[UIImage systemImageNamed:@"archivebox"] identifier:nil handler:^(UIAction *a) {
    [weakSelf unpublishCurrentPost];
  }];
  UIAction *safari = [UIAction actionWithTitle:@"在浏览器中查看" image:[UIImage systemImageNamed:@"safari"] identifier:nil handler:^(UIAction *a) {
    [weakSelf openLive];
  }];
  UIAction *del = [UIAction actionWithTitle:@"永久删除文章" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) {
    [weakSelf confirmDeleteCurrentPost];
  }];
  del.attributes = UIMenuElementAttributesDestructive;

  BOOL published = [_post[@"publish"] boolValue];
  return [UIMenu menuWithChildren:published ? @[ details, edit, unpub, safari ] : @[ details, edit, publish, del ]];
}

- (void)editCurrentPost {
  NSString *noteId = _post[@"id"] ?: _post[@"slug"];
  if (!noteId.length) return;

  NSDictionary *full = [LBMdStore.shared loadArticle:noteId] ?: _post;
  NSMutableDictionary *postData = [full mutableCopy];
  if (![postData[@"markdown"] length] && [postData[@"html"] length]) {
    postData[@"markdown"] = LBHTMLToMarkdown(postData[@"html"]);
  }
  LBPostEditor *editor = [[LBPostEditor alloc] initWithPost:postData saved:^(NSDictionary *savedPost) {
    dispatch_async(dispatch_get_main_queue(), ^{
      NSDictionary *refreshed = [LBMdStore.shared loadArticle:noteId];
      if (refreshed) {
        self->_post = refreshed;
        self.navigationItem.title = @"";
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis"] menu:[self postActionMenu]];
        [self retry];
      } else {
        [self.navigationController popViewControllerAnimated:YES];
      }
    });
  }];
  LBNavigationController *nav = [[LBNavigationController alloc] initWithRootViewController:editor];
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)finishPublication:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (error) {
      UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"操作未完成" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
      if (!self.presentedViewController) [self presentViewController:alert animated:YES completion:nil];
      return;
    }
    NSDictionary *full = [LBMdStore.shared loadArticle:LBReaderString(self->_post[@"id"])];
    if (full) self->_post = full;
    self.navigationItem.title = @"";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis"] menu:[self postActionMenu]];
    [self updateMetaTextInDOM];
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
  });
}
- (void)publishCurrentPost {
  NSString *noteId = LBReaderString(_post[@"id"]);
  if (!noteId.length) return;
  NSError *err = nil;
  BOOL ok = [LBMdStore.shared stagePublishArticle:noteId error:&err];
  [self finishPublication:ok ? nil : err];
}

- (void)unpublishCurrentPost {
  NSString *noteId = _post[@"id"] ?: _post[@"slug"];
  if (!noteId.length) return;
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下架文章？" message:@"文章将转为草稿并暂存，可在文章列表点击右上角「保存预览」一并提交到 GitHub。" preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"下架文章" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
    NSError *err = nil;
    BOOL ok = [LBMdStore.shared stageUnpublishArticle:noteId error:&err];
    [self finishPublication:ok ? nil : err];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteCurrentPost {
  NSString *noteId = _post[@"id"] ?: _post[@"slug"];
  if (!noteId.length || [_post[@"publish"] boolValue]) return;
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认永久删除草稿？"
                                                               message:@"将删除本地草稿及其附件。此操作不可撤销。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"永久删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
    __weak typeof(self) weakSelf = self;
    [LBMdStore.shared deleteArticle:noteId done:^(NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) owner = weakSelf;
        if (!owner) return;
        if (error) { [owner finishPublication:error]; return; }
        [owner.navigationController popViewControllerAnimated:YES];
      });
    }];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)openLive {
  NSString *slug = [LBReaderString(_post[@"slug"]) stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"blog/%@/", slug] relativeToURL:_site].absoluteURL;
  if (LBReaderSameOrigin(url, _site)) LBOpenURL(self, url);
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  // The WebView itself never navigates to network pages, arbitrary files, custom schemes or frames.
  BOOL allow = action.targetFrame.mainFrame && [self isEntry:action.request.URL] && action.navigationType != WKNavigationTypeLinkActivated;
  decisionHandler(allow ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
  if (error.code != NSURLErrorCancelled) [self showFailure:@"本地阅读器加载失败，请重试。"];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
  if (error.code != NSURLErrorCancelled) [self showFailure:@"本地阅读器无法打开，请重试。"];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { [self showFailure:@"阅读器已释放内存，请点按重试。"]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_web.configuration.userContentController removeScriptMessageHandlerForName:@"reader" contentWorld:_world]; }
@end

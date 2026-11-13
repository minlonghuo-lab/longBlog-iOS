#import "LBMemoContentView.h"
#import "LBMemosCache.h"
#import <WebKit/WebKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>

static BOOL LBMemoIsImage(NSDictionary *resource) {
  NSString *mime = [resource[@"type"] lowercaseString] ?: @"";
  if ([mime hasPrefix:@"image/"]) return YES; // Includes image/heic, no JPEG-only path.
  if (mime.length && ![mime isEqual:@"application/octet-stream"] && ![mime isEqual:@"binary/octet-stream"]) return NO;
  UTType *type = [UTType typeWithFilenameExtension:[resource[@"filename"] pathExtension].lowercaseString];
  return [type conformsToType:UTTypeImage];
}

static BOOL LBMemoPlayable(NSDictionary *resource) {
  NSString *mime = [resource[@"type"] lowercaseString] ?: @"";
  if ([mime hasPrefix:@"video/"] || [mime hasPrefix:@"audio/"]) return YES;
  UTType *type = [UTType typeWithFilenameExtension:[resource[@"filename"] pathExtension].lowercaseString];
  return [type conformsToType:UTTypeMovie] || [type conformsToType:UTTypeAudio];
}

// A weak proxy avoids WKUserContentController -> view retain cycles.
@interface LBMemoBridge : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end
@implementation LBMemoBridge
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
  [self.target userContentController:controller didReceiveScriptMessage:message];
}
@end

@interface LBMemoAttachmentView : UIStackView
@property (nonatomic, copy) NSDictionary *resource;
@property (nonatomic, strong) NSURL *file;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) NSLayoutConstraint *imageHeight;
@property (nonatomic, copy) void (^action)(void);
@property (nonatomic) BOOL imageResource, loading, failed, layoutEnabled, wantsPreview;
- (instancetype)initWithResource:(NSDictionary *)resource action:(void (^)(void))action;
- (void)updateImageHeight;
@end
@implementation LBMemoAttachmentView
- (instancetype)initWithResource:(NSDictionary *)resource action:(void (^)(void))action {
  if ((self = [super initWithFrame:CGRectZero])) {
    _resource = [resource copy]; _action = [action copy]; self.axis = UILayoutConstraintAxisVertical; self.spacing = 6;
    NSString *type = resource[@"type"] ?: @""; _imageResource = LBMemoIsImage(resource);
    UILabel *name = [UILabel new]; name.text = resource[@"filename"] ?: @"附件";
    name.font = [LBTheme rounded:14 weight:UIFontWeightSemibold]; name.textColor = LBTheme.ink; name.numberOfLines = 0;
    if (!_imageResource) [self addArrangedSubview:name];
    if (_imageResource) {
      _imageView = [UIImageView new]; _imageView.contentMode = UIViewContentModeScaleAspectFit;
      _imageView.clipsToBounds = YES; _imageView.layer.cornerRadius = 12;
      _imageView.backgroundColor = [LBTheme.muted colorWithAlphaComponent:.08];
      _imageView.userInteractionEnabled = YES; _imageView.isAccessibilityElement = YES;
      _imageView.accessibilityLabel = [NSString stringWithFormat:@"%@；点按预览原图", name.text];
      _imageView.accessibilityTraits = UIAccessibilityTraitImage | UIAccessibilityTraitButton;
      [_imageView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(activate)]];
      [self addArrangedSubview:_imageView]; _imageHeight = [_imageView.heightAnchor constraintEqualToConstant:120]; _imageHeight.active = YES;
    }
    _status = [UILabel new]; _status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _status.textColor = LBTheme.muted; _status.numberOfLines = 0;
    _status.text = [NSString stringWithFormat:@"%@ · %@", type, [NSByteCountFormatter stringFromByteCount:[resource[@"size"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
    _status.hidden = _imageResource;
    [self addArrangedSubview:_status];
    _button = [UIButton buttonWithType:UIButtonTypeSystem]; _button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [_button setTitle:_imageResource ? @"等待鉴权加载…" : [type hasPrefix:@"video/"] ? @"播放视频" : [type hasPrefix:@"audio/"] ? @"播放音频" : @"打开文件" forState:UIControlStateNormal];
    [_button addTarget:self action:@selector(activate) forControlEvents:UIControlEventTouchUpInside];
    [self addArrangedSubview:_button];
  } return self;
}
- (void)activate { if (!_loading && _action) _action(); }
- (void)layoutSubviews { [super layoutSubviews]; [self updateImageHeight]; }
- (void)updateImageHeight {
  if (!_layoutEnabled) return;
  CGSize size = _imageView.image.size;
  if (size.width > 0 && size.height > 0 && self.bounds.size.width > 0) {
    CGFloat height = MAX(44, MIN(320, self.bounds.size.width * size.height / size.width));
    if (fabs(_imageHeight.constant - height) > .5) _imageHeight.constant = height;
  }
}
@end

static UIImage *LBMemoThumbnail(NSURL *file) {
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)file, (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@NO});
  if (!source) return nil;
  CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
    (id)kCGImageSourceCreateThumbnailFromImageAlways:@YES, (id)kCGImageSourceCreateThumbnailWithTransform:@YES,
    (id)kCGImageSourceThumbnailMaxPixelSize:@2048, (id)kCGImageSourceShouldCacheImmediately:@YES});
  UIImage *result = image ? [UIImage imageWithCGImage:image] : nil;
  if (image) CGImageRelease(image); CFRelease(source); return result;
}

@interface LBMemoContentView () <WKScriptMessageHandler, WKNavigationDelegate>
@end
@implementation LBMemoContentView {
  UIStackView *_stack, *_attachments;
  UILabel *_metadata, *_notice, *_initialBody;
  WKWebView *_web;
  WKContentWorld *_world;
  NSURL *_entry;
  NSLayoutConstraint *_webHeight;
  NSDictionary *_memo;
  NSUInteger _generation, _revision, _active;
  NSString *_nonce;
  BOOL _visible, _ready, _invalidated, _preparing;
  NSUInteger _webEpoch;
  CGFloat _pendingHeight;
  NSMutableArray<LBMemoAttachmentView *> *_queue;
  NSMutableArray<NSURLSessionTask *> *_tasks;
  NSMutableSet<NSURL *> *_files;
  void (^_preview)(NSURL *);
}
- (instancetype)initWithPreview:(void (^)(NSURL *))preview {
  if ((self = [super initWithFrame:CGRectZero])) {
    _preview = [preview copy]; _queue = [NSMutableArray array]; _tasks = [NSMutableArray array]; _files = [NSMutableSet set];
    UIVisualEffectView *glass = [LBTheme glassWithTint:[LBTheme.surface colorWithAlphaComponent:.35] interactive:NO];
    glass.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:24]];
    [self addSubview:glass]; glass.translatesAutoresizingMaskIntoConstraints = NO;
    _stack = [UIStackView new]; _stack.axis = UILayoutConstraintAxisVertical; _stack.spacing = 16; _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [glass.contentView addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
      [glass.topAnchor constraintEqualToAnchor:self.topAnchor], [glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor], [glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_stack.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor constant:18], [_stack.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor constant:-18],
      [_stack.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor constant:18], [_stack.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor constant:-18]]];
    _metadata = [UILabel new]; _metadata.font = [LBTheme rounded:12 weight:UIFontWeightMedium]; _metadata.textColor = LBTheme.muted; _metadata.numberOfLines = 0;
    [_stack addArrangedSubview:_metadata];
    // Synchronous, untruncated local text while the isolated WebKit renderer
    // starts. This view is replaced, never appended to the rendered Markdown.
    _initialBody = [UILabel new]; _initialBody.numberOfLines = 0;
    _initialBody.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; _initialBody.textColor = LBTheme.ink;
    _initialBody.adjustsFontForContentSizeCategory = YES; _initialBody.hidden = YES;
    [_stack addArrangedSubview:_initialBody];
    _notice = [UILabel new]; _notice.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; _notice.textColor = LBTheme.muted; _notice.numberOfLines = 0;
    [_stack addArrangedSubview:_notice];
    _attachments = [UIStackView new]; _attachments.axis = UILayoutConstraintAxisVertical; _attachments.spacing = 20;
    [_stack addArrangedSubview:_attachments];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cacheBecameAvailable:) name:LBMemosCacheDidChange object:nil];
  } return self;
}
- (void)prepareWebView {
  if (_web || _preparing || _invalidated || ![self currentRevision:_revision]) return;
  _preparing = YES; NSUInteger epoch = ++_webEpoch;
  NSURL *directory = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Reader" isDirectory:YES];
  // Bundle assets are large (notably Mermaid). Read off-main so a cold engine
  // cannot hold up the push's first frame. No memo/account data is cached here.
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSMutableString *source = [NSMutableString string]; BOOL complete = YES;
    for (NSString *name in @[@"vendor/marked.umd.js", @"vendor/katex.min.js", @"vendor/mermaid.min.js", @"reader-mermaid.js", @"reader.js", @"memo-detail.js"]) {
      NSString *part = [NSString stringWithContentsOfURL:[directory URLByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:NULL];
      if (!part) { complete = NO; break; }
      [source appendFormat:@"\n%@\n;", part];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (!self || epoch != self->_webEpoch || self->_invalidated) return;
      self->_preparing = NO;
      if (![self currentRevision:self->_revision]) { [self invalidateContent]; return; }
      if (!complete) { self->_notice.text = @"离线排版资源缺失，已显示本地 Markdown 正文。"; self->_notice.hidden = NO; return; }
      [self installWebViewWithSource:source directory:directory];
    });
  });
}
- (void)installWebViewWithSource:(NSMutableString *)source directory:(NSURL *)directory {
  _entry = [directory URLByAppendingPathComponent:@"memo-detail.html"];
  _world = [WKContentWorld worldWithName:@"LongBlogMemoDetail"]; _nonce = NSUUID.UUID.UUIDString;
  [source appendFormat:@"\nwindow.LBMemoDetail.install(document,b=>window.webkit.messageHandlers.memoDetail.postMessage({...b,nonce:'%@'}));", _nonce];
  WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
  configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
  configuration.preferences.javaScriptCanOpenWindowsAutomatically = NO;
  LBMemoBridge *bridge = [LBMemoBridge new]; bridge.target = self;
  [configuration.userContentController addScriptMessageHandler:bridge contentWorld:_world name:@"memoDetail"];
  [configuration.userContentController addUserScript:[[WKUserScript alloc] initWithSource:source injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES inContentWorld:_world]];
  _web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
  _web.navigationDelegate = self; _web.opaque = NO; _web.backgroundColor = UIColor.clearColor;
  _web.scrollView.backgroundColor = UIColor.clearColor; _web.scrollView.scrollEnabled = NO;
  _web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  _web.scrollView.bounces = NO; _web.translatesAutoresizingMaskIntoConstraints = NO; _web.hidden = YES;
  [_stack insertArrangedSubview:_web atIndex:2]; _webHeight = [_web.heightAnchor constraintEqualToConstant:44]; _webHeight.priority = 999; _webHeight.active = YES;
  [_web loadFileURL:_entry allowingReadAccessToURL:directory];
}
- (void)displayMemo:(NSDictionary *)memo generation:(NSUInteger)generation {
  if (generation != LBMemosClient.shared.generation) { [self invalidateContent]; return; }
  if (_memo && [_memo isEqual:memo] && _generation == generation && !_invalidated) return;
  [self clearContentState]; _invalidated = NO; _memo = [memo copy]; _generation = generation;
  NSString *vis = LBMemoVisibility(memo[@"visibility"]);
  if ([memo[@"rowStatus"] isEqual:@"ARCHIVED"]) vis = [vis stringByAppendingString:@" · 已归档"];
  _metadata.text = [NSString stringWithFormat:@"%@ · %@", LBRelativeTime([memo[@"createdTs"] longLongValue] * 1000), vis];
  _metadata.hidden = NO;
  NSString *markdown = [memo[@"content"] isKindOfClass:NSString.class] ? memo[@"content"] : @"";
  _initialBody.text = markdown.length ? markdown : @"（仅附件说说）"; _initialBody.hidden = NO;
  _notice.hidden = YES; _web.hidden = YES;
  [self prepareWebView];
  NSArray *resources = [memo[@"resourceList"] isKindOfClass:NSArray.class] ? memo[@"resourceList"] : @[];
  NSMutableArray *ordered = [NSMutableArray array];
  for (NSDictionary *resource in resources) if (LBMemoIsImage(resource)) [ordered addObject:resource];
  for (NSDictionary *resource in resources) if (!LBMemoIsImage(resource)) [ordered addObject:resource];
  __weak typeof(self) weakSelf = self;
  for (NSDictionary *resource in ordered) {
    if (LBMemoPlayable(resource) && self.installMedia) {
      UIView *host = [UIView new]; host.translatesAutoresizingMaskIntoConstraints = NO;
      [_attachments addArrangedSubview:host];
      BOOL audio = [[resource[@"type"] lowercaseString] hasPrefix:@"audio/"];
      if (audio) [host.heightAnchor constraintEqualToConstant:88].active = YES;
      else {
        NSLayoutConstraint *aspect = [host.heightAnchor constraintEqualToAnchor:host.widthAnchor multiplier:9.0 / 16.0];
        aspect.priority = 999; aspect.active = YES;
        [host.heightAnchor constraintLessThanOrEqualToConstant:240].active = YES;
      }
      self.installMedia(host, resource); continue;
    }
    LBMemoAttachmentView *row = [[LBMemoAttachmentView alloc] initWithResource:resource action:^{}]; row.layoutEnabled = _visible;
    __weak LBMemoAttachmentView *weakRow = row;
    row.action = ^{
      typeof(self) self = weakSelf; LBMemoAttachmentView *item = weakRow;
      if (!self || !item || ![self currentRevision:self->_revision]) return;
      if (LBMemoPlayable(item.resource) && self->_visible && self.playMedia) { self.playMedia(item.resource); return; }
      if (item.file) { if (self->_visible && self->_preview) self->_preview(item.file); return; }
      item.wantsPreview = !item.imageResource;
      if (![self->_queue containsObject:item]) [self->_queue addObject:item];
      [self pumpDownloads];
    };
    [_attachments addArrangedSubview:row];
    if (row.imageResource) [_queue addObject:row];
  }
  _attachments.hidden = resources.count == 0;
  [self renderMarkdown]; [self pumpDownloads];
}
- (BOOL)currentRevision:(NSUInteger)revision {
  return !_invalidated && _memo && _revision == revision && _generation == LBMemosClient.shared.generation;
}
- (void)renderMarkdown {
  if (!_ready || ![self currentRevision:_revision]) return;
  // Dummy HTTPS base is only for URL parsing. CSP blocks ALL network loads;
  // attachment dictionaries, URLs and account credentials are never passed here.
  NSDictionary *payload = @{ @"isMemo":@YES, @"markdown":_memo[@"content"] ?: @"", @"title":@"", @"meta":@"", @"site":@"https://memo.invalid/", @"posts":@[] };
  NSUInteger revision = _revision; __weak typeof(self) weakSelf = self;
  [_web callAsyncJavaScript:@"return window.LBMemoDetail.render(payload, revision);" arguments:@{@"payload":payload, @"revision":@(revision)} inFrame:nil inContentWorld:_world completionHandler:^(id result, NSError *error) {
    (void)result; typeof(self) self = weakSelf; if (!self || ![self currentRevision:revision]) return;
    if (error && !self->_initialBody.hidden) {
      self->_notice.text = @"正文排版失败，已显示本地 Markdown 正文。"; self->_notice.hidden = NO;
    }
  }];
}
- (void)setPageVisible:(BOOL)visible {
  _visible = visible;
  for (UIView *view in _attachments.arrangedSubviews) if ([view isKindOfClass:LBMemoAttachmentView.class]) ((LBMemoAttachmentView *)view).layoutEnabled = visible;
  if (_generation != LBMemosClient.shared.generation) { [self invalidateContent]; return; }
  if (visible && !_invalidated) {
    if (_pendingHeight > 0) _webHeight.constant = _pendingHeight;
    for (UIView *view in _attachments.arrangedSubviews) if ([view isKindOfClass:LBMemoAttachmentView.class]) [(LBMemoAttachmentView *)view updateImageHeight];
    [self setNeedsLayout];
  }
}
- (void)invalidateContent {
  ++_webEpoch; _preparing = NO;
  [self clearContentState];
  // A hidden WebKit process can defer JavaScript execution. Destroy its document
  // as well, rather than relying solely on an asynchronous clear() callback.
  [_web stopLoading]; _web.navigationDelegate = nil;
  [_web.configuration.userContentController removeScriptMessageHandlerForName:@"memoDetail" contentWorld:_world];
  [_web.configuration.userContentController removeAllUserScripts];
  [_web removeFromSuperview]; _web = nil; _ready = NO; _webHeight = nil;
}
- (void)clearContentState {
  if (self.resetDiagram) self.resetDiagram();
  _invalidated = YES; ++_revision; _memo = nil; _active = 0; _pendingHeight = 0;
  [_queue removeAllObjects]; for (NSURLSessionTask *task in _tasks) [task cancel]; [_tasks removeAllObjects];
  // Immediate native concealment is independent of visibility or JS completion.
  _web.hidden = YES; _initialBody.hidden = YES; _initialBody.text = nil;
  _metadata.text = nil; _notice.text = nil; _notice.hidden = YES;
  if (self.resetMedia) self.resetMedia();
  for (UIView *view in _attachments.arrangedSubviews.copy) {
    if ([view isKindOfClass:LBMemoAttachmentView.class]) {
      LBMemoAttachmentView *row = (LBMemoAttachmentView *)view;
      row.imageView.image = nil; row.file = nil; row.action = nil;
    }
    [_attachments removeArrangedSubview:view]; [view removeFromSuperview];
  }
  // Originals are owned by the account-scoped client cache, not this view.
  [_files removeAllObjects];
  // clear() has a monotonic revision so an older pending render cannot repopulate
  // the private DOM, including while the controller is hidden behind a sheet.
  if (_ready) [_web callAsyncJavaScript:@"window.LBMemoDetail.clear(revision);" arguments:@{@"revision":@(_revision)} inFrame:nil inContentWorld:_world completionHandler:nil];
}
- (void)cacheBecameAvailable:(NSNotification *)notification {
  (void)notification;
  if (!_visible || ![self currentRevision:_revision]) return;
  for (UIView *view in _attachments.arrangedSubviews) {
    if (![view isKindOfClass:LBMemoAttachmentView.class]) continue;
    LBMemoAttachmentView *row = (LBMemoAttachmentView *)view;
    if (row.imageResource && !row.file && !row.loading && [LBMemosClient.shared cachedResource:row.resource] && ![_queue containsObject:row]) [_queue addObject:row];
  }
  [self pumpDownloads];
}
- (void)pumpDownloads {
  if (![self currentRevision:_revision]) return;
  while (_active < 2 && _queue.count) {
    LBMemoAttachmentView *row = _queue.firstObject; [_queue removeObjectAtIndex:0];
    if (row.loading || row.file) continue;
    row.loading = YES; row.failed = NO; row.button.enabled = NO;
    [row.button setTitle:@"正在鉴权下载…" forState:UIControlStateNormal]; ++_active;
    NSUInteger revision = _revision; __weak typeof(self) weakSelf = self;
    NSURLSessionTask *task = [LBMemosClient.shared downloadResource:row.resource done:^(NSURL *file, NSError *error) {
      typeof(self) self = weakSelf;
      if (!self || ![self currentRevision:revision]) { (void)file; return; }
      if (file) [self->_files addObject:file];
      if (error || !file) { [self finishRow:row file:nil image:nil revision:revision]; return; }
      if (!row.imageResource) { [self finishRow:row file:file image:nil revision:revision]; return; }
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        UIImage *thumbnail = LBMemoThumbnail(file);
        dispatch_async(dispatch_get_main_queue(), ^{
          typeof(self) owner = weakSelf;
          if (!owner || ![owner currentRevision:revision]) { return; }
          [owner finishRow:row file:file image:thumbnail revision:revision];
        });
      });
    }];
    if (task) [_tasks addObject:task];
  }
}
- (void)finishRow:(LBMemoAttachmentView *)row file:(NSURL *)file image:(UIImage *)image revision:(NSUInteger)revision {
  if (![self currentRevision:revision]) return;
  if (_active) --_active; row.loading = NO; row.button.enabled = YES;
  if (!file || (row.imageResource && !image)) {
    if (file && row.imageResource && !image) [LBMemosClient.shared invalidateCachedResource:row.resource];
    if (file) [_files removeObject:file];
    row.failed = YES; row.status.hidden = NO; row.button.hidden = NO;
    row.status.text = @"附件未能加载，请检查网络后重试。";
    [row.button setTitle:@"重新鉴权加载" forState:UIControlStateNormal];
  } else {
    row.file = file; row.imageView.image = image;
    row.status.hidden = row.imageResource;
    row.button.hidden = row.imageResource;
    row.status.text = row.imageResource ? nil : @"已就绪";
    [row.button setTitle:row.imageResource ? @"" : @"打开附件" forState:UIControlStateNormal];
    if (_visible) [row updateImageHeight];
    if (row.wantsPreview && _visible && _preview) _preview(file);
  }
  row.wantsPreview = NO;
  [self pumpDownloads];
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
  (void)controller;
  if (message.webView != _web || !message.frameInfo.mainFrame || ![message.name isEqual:@"memoDetail"] ||
      !message.frameInfo.request.URL.isFileURL || ![message.frameInfo.request.URL.URLByStandardizingPath.path isEqual:_entry.URLByStandardizingPath.path] ||
      ![message.body isKindOfClass:NSDictionary.class]) return;
  NSDictionary *body = message.body;
  if (![body[@"nonce"] isEqual:_nonce]) return;
  if ([body[@"type"] isEqual:@"ready"]) {
    _ready = YES;
    if (_invalidated) [self invalidateContent]; else [self renderMarkdown]; return;
  }
  if (![body[@"revision"] isKindOfClass:NSNumber.class] || ![self currentRevision:[body[@"revision"] unsignedIntegerValue]]) return;
  NSString *type = body[@"type"];
  if ([type isEqual:@"diagram"]) {
    if (body.count != 4 || !_ready || !_visible || ![body[@"value"] isKindOfClass:NSString.class] ||
        [body[@"value"] length] > 8000000 || ![body[@"value"] hasPrefix:@"data:image/svg+xml;charset=utf-8,"]) return;
    if (self.openDiagram) self.openDiagram(body[@"value"], _generation);
    return;
  }
  if ([type isEqual:@"height"] && [body[@"value"] isKindOfClass:NSNumber.class]) {
    double height = [body[@"value"] doubleValue]; if (!isfinite(height) || height < 1 || height > 120000) return;
    _pendingHeight = ceil(height); if (_visible && fabs(_webHeight.constant - _pendingHeight) > .5) _webHeight.constant = _pendingHeight;
    if (!_initialBody.hidden) {
      // A revision-checked DOM measurement, not JS evaluation completion, is
      // the hand-off. Install the real height first; replace text atomically.
      _webHeight.constant = _pendingHeight;
      [UIView performWithoutAnimation:^{
        self->_initialBody.hidden = YES; self->_initialBody.text = nil;
        self->_web.hidden = NO; self->_notice.hidden = YES;
        [self setNeedsLayout];
      }];
    }
  } else if ([type isEqual:@"copy"] && _visible && [body[@"value"] isKindOfClass:NSString.class] && [body[@"value"] length] <= 262144) {
    UIPasteboard.generalPasteboard.string = body[@"value"];
  } else if ([type isEqual:@"link"] && _visible && [body[@"value"] isKindOfClass:NSString.class]) {
    NSURL *url = [NSURL URLWithString:body[@"value"]];
    if ([url.scheme.lowercaseString isEqual:@"https"] && url.host.length && !url.user.length && !url.password.length && url.absoluteString.length <= 4096) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
  }
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  (void)webView; NSURL *url = action.request.URL;
  decisionHandler(action.targetFrame.mainFrame && [url isEqual:_entry] && action.navigationType == WKNavigationTypeOther ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  if (webView != _web) return;
  if (![self currentRevision:_revision]) { [self invalidateContent]; return; }
  _ready = NO; _pendingHeight = 0;
  NSString *markdown = [_memo[@"content"] isKindOfClass:NSString.class] ? _memo[@"content"] : @"";
  _initialBody.text = markdown.length ? markdown : @"（仅附件说说）"; _initialBody.hidden = NO;
  _web.hidden = YES; _notice.hidden = YES;
  [_web loadFileURL:_entry allowingReadAccessToURL:[_entry URLByDeletingLastPathComponent]];
}
- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  for (NSURLSessionTask *task in _tasks) [task cancel];
  // Client owns disk cache lifetime; dropping this view must not redownload.
  [_files removeAllObjects];
  [_web.configuration.userContentController removeScriptMessageHandlerForName:@"memoDetail" contentWorld:_world];
}
@end

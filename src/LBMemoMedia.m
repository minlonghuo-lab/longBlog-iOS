#import "LBMemoMedia.h"
#import "LBMemosCache.h"
#import "LBAudioCenter.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>

// Player-scoped teardown prevents an idle/offscreen audio card from clearing
// another card's remote controls. Internal contract; public header unchanged.
@interface LBAudioCenter (LBMMOwnership)
+ (void)deactivatePlaybackForPlayer:(AVPlayer *)player;
@end

// The custom expand button presents a separate controller, so AVKit's inline
// willEndFullScreen delegate does not run for its Done/swipe dismissal.
@interface LBMMFullscreenController : AVPlayerViewController
@property (nonatomic, copy) void (^didClose)(void);
@end
@implementation LBMMFullscreenController
- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  if (self.didClose) self.didClose();
}
@end

static const int64_t LBMMCap = 32LL * 1024 * 1024;
static const int64_t LBMMChunk = 512LL * 1024;
static NSError *LBMMError(NSInteger code, NSString *message) {
  // Never forward underlying errors, URLs, bodies, or credentials to the UI.
  return [NSError errorWithDomain:@"LBMemoMedia" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL LBMMInteger(id n, BOOL positive) {
  if (![n isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)n) == CFBooleanGetTypeID()) return NO;
  double v = [n doubleValue];
  return isfinite(v) && floor(v) == v && v >= (positive ? 1 : 0) && v <= 9007199254740991.0;
}
static NSString *LBMMType(NSDictionary *resource) {
  id raw = resource[@"type"];
  if (![raw isKindOfClass:NSString.class] || [raw length] > 120) return nil;
  NSString *type = [raw lowercaseString];
  NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"^(audio|video)/[a-z0-9!#$&^_.+-]+$" options:0 error:NULL];
  return [rx numberOfMatchesInString:type options:0 range:NSMakeRange(0, type.length)] == 1 ? type : nil;
}
BOOL LBMemoIsPlayable(NSDictionary *resource) {
  return [resource isKindOfClass:NSDictionary.class] && LBMMInteger(resource[@"id"], YES) &&
      LBMMInteger(resource[@"creatorId"], YES) && LBMMInteger(resource[@"size"], YES) &&
      [resource[@"size"] longLongValue] <= LBMMCap && LBMMType(resource) != nil;
}
static NSURL *LBMMFileURL(NSString *base, NSNumber *identifier) {
  NSURLComponents *c = [NSURLComponents componentsWithString:base];
  if (![c.scheme.lowercaseString isEqual:@"https"] || !c.host.length || c.user != nil || c.password != nil ||
      c.query != nil || c.fragment != nil || (c.path.length && ![c.path isEqual:@"/"]) ||
      !LBMMInteger(identifier, YES) || (c.port && (!LBMMInteger(c.port, YES) || c.port.integerValue > 65535))) return nil;
  c.scheme = @"https"; c.host = c.host.lowercaseString;
  if ([c.port isEqual:@443]) c.port = nil;
  c.path = [NSString stringWithFormat:@"/api/v1/resource/%lld/file", identifier.longLongValue];
  return c.URL;
}
// Strict decimal parser, bounded BEFORE multiplication; HTTP fields are hostile.
static BOOL LBMMDecimal(NSString *text, int64_t *result) {
  if (!text.length || text.length > 16) return NO;
  int64_t value = 0;
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (c < '0' || c > '9' || value > (LBMMCap - (c - '0')) / 10) return NO;
    value = value * 10 + c - '0';
  }
  *result = value; return YES;
}
static BOOL LBMMContentRange(NSString *header, int64_t start, int64_t count, int64_t total) {
  if (![header hasPrefix:@"bytes "] || count <= 0 || start < 0 || total <= 0 || start >= total || count > total - start) return NO;
  NSArray<NSString *> *pair = [[header substringFromIndex:6] componentsSeparatedByString:@"/"];
  if (pair.count != 2) return NO;
  NSArray<NSString *> *bounds = [pair[0] componentsSeparatedByString:@"-"];
  int64_t a = 0, b = 0, t = 0;
  return bounds.count == 2 && LBMMDecimal(bounds[0], &a) && LBMMDecimal(bounds[1], &b) &&
      LBMMDecimal(pair[1], &t) && a == start && b >= a && b - a == count - 1 && t == total;
}
// End is exclusive. Clamp against the verified metadata without offset+length overflow.
static BOOL LBMMWindow(int64_t offset, int64_t current, NSInteger length, BOOL toEnd, int64_t size, int64_t *begin, int64_t *end) {
  if (size <= 0 || size > LBMMCap || offset < 0 || offset > size || current < offset || current > size || length < 0) return NO;
  int64_t amount = toEnd ? size - offset : MIN((int64_t)length, size - offset);
  *end = offset + amount; *begin = current;
  return current <= *end;
}

@interface LBMMRequest : NSObject
@property (nonatomic, strong) AVAssetResourceLoadingRequest *loading;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property int64_t next;
@property int64_t end;
@property int64_t start;
@property int64_t count;
@property int64_t received;
@property NSInteger status;
@property BOOL accepted;
@end
@implementation LBMMRequest
@end

// ALL state, AV resource-loader calls, NSURLSession callbacks and identity reads
// are main-queue confined. AVAssetResourceLoader.delegate is NOT retained by AV:
// controller -> loader -> session -> delegate(loader); explicit stop breaks cycle.
@interface LBMMResourceLoader : NSObject <AVAssetResourceLoaderDelegate, NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSURL *assetURL;
@property (nonatomic, copy) NSDictionary *resource;
@property NSUInteger generation;
@property (nonatomic, strong) NSNumber *userID;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableArray<LBMMRequest *> *pending;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, LBMMRequest *> *active;
@property (nonatomic, copy) void (^failure)(NSString *);
@property BOOL stopped;
@property BOOL verifiedHeaders;
- (instancetype)initWithResource:(NSDictionary *)resource;
- (BOOL)currentIdentity;
- (void)stop;
@end

@implementation LBMMResourceLoader
- (instancetype)initWithResource:(NSDictionary *)resource {
  if ((self = [super init])) {
    _resource = [resource copy]; _generation = LBMemosClient.shared.generation;
    _userID = LBMemosClient.shared.user[@"id"];
    _fileURL = LBMMFileURL(LBMemosClient.shared.baseURL, resource[@"id"]);
    NSURLComponents *parts = [NSURLComponents componentsWithURL:_fileURL resolvingAgainstBaseURL:NO];
    parts.scheme = @"lbmemos-media"; _assetURL = parts.URL;
    _pending = [NSMutableArray array]; _active = [NSMutableDictionary dictionary];
    NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.HTTPCookieStorage = nil; c.HTTPShouldSetCookies = NO; c.URLCache = nil; c.URLCredentialStorage = nil;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 120; c.HTTPMaximumConnectionsPerHost = 2;
    _session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:NSOperationQueue.mainQueue];
  }
  return self;
}
- (BOOL)currentIdentity {
  LBMemosClient *api = LBMemosClient.shared;
  return !self.stopped && self.generation == api.generation && api.configured && !api.authenticationRequired &&
      LBMMInteger(api.user[@"id"], YES) && [self.userID isEqual:api.user[@"id"]] &&
      [self.resource[@"creatorId"] isEqual:api.user[@"id"]] &&
      [self.fileURL isEqual:LBMMFileURL(api.baseURL, self.resource[@"id"])];
}
- (void)remove:(LBMMRequest *)r {
  if (r.task) { [self.active removeObjectForKey:@(r.task.taskIdentifier)]; [r.task cancel]; r.task = nil; }
  [self.pending removeObjectIdenticalTo:r];
}
- (void)fail:(LBMMRequest *)r code:(NSInteger)code message:(NSString *)message {
  [self remove:r];
  if (!r.loading.isCancelled && !r.loading.isFinished) [r.loading finishLoadingWithError:LBMMError(code, message)];
  // Avoid reentrant controller teardown from a URLSession completion handler.
  void (^failure)(NSString *) = self.failure;
  [self stop]; // One invalid response invalidates ALL concurrent requests.
  if (failure) dispatch_async(dispatch_get_main_queue(), ^{ failure(message); });
}
- (void)stop {
  if (self.stopped) return;
  self.stopped = YES; self.failure = nil;
  NSArray *requests = self.pending.copy;
  for (LBMMRequest *r in requests) {
    [self remove:r];
    if (!r.loading.isCancelled && !r.loading.isFinished)
      [r.loading finishLoadingWithError:LBMMError(4091, @"播放已停止或连接已改变。")];
  }
  [self.session invalidateAndCancel]; self.session = nil;
}
- (void)information:(LBMMRequest *)r {
  AVAssetResourceLoadingContentInformationRequest *info = r.loading.contentInformationRequest;
  if (info) {
    info.contentType = [UTType typeWithMIMEType:LBMMType(self.resource)].identifier ?: UTTypeData.identifier;
    info.contentLength = [self.resource[@"size"] longLongValue]; info.byteRangeAccessSupported = YES;
  }
}
- (void)complete:(LBMMRequest *)r {
  [self remove:r];
  if (!r.loading.isCancelled && !r.loading.isFinished) [r.loading finishLoading];
}
- (void)pump {
  if (![self currentIdentity]) { [self stop]; return; }
  for (LBMMRequest *r in self.pending.copy) {
    if (self.active.count >= 2) break;
    if (r.task) continue;
    if (self.verifiedHeaders) {
      [self information:r];
      if (r.next == r.end) { [self complete:r]; continue; }
    }
    r.start = r.next;
    r.count = MIN(LBMMChunk, r.end - r.next);
    // Metadata-only/EOF requests need one byte to validate server size/type.
    if (r.count == 0) { r.start = 0; r.count = 1; }
    r.received = 0; r.accepted = NO; r.status = 0;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.fileURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    request.HTTPShouldHandleCookies = NO;
    [request setValue:[@"Bearer " stringByAppendingString:LBMemosClient.shared.token] forHTTPHeaderField:@"Authorization"];
    [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", r.start, r.start + r.count - 1] forHTTPHeaderField:@"Range"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"no-store" forHTTPHeaderField:@"Cache-Control"];
    r.task = [self.session dataTaskWithRequest:request];
    self.active[@(r.task.taskIdentifier)] = r; [r.task resume];
  }
}
- (BOOL)resourceLoader:(AVAssetResourceLoader *)loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loading {
  if (![loading.request.URL isEqual:self.assetURL] || ![self currentIdentity]) {
    [loading finishLoadingWithError:LBMMError(4091, @"连接已改变，请重新验证身份。")]; return YES;
  }
  LBMMRequest *r = [LBMMRequest new]; r.loading = loading;
  AVAssetResourceLoadingDataRequest *d = loading.dataRequest;
  int64_t size = [self.resource[@"size"] longLongValue], begin = 0, end = 0;
  if (d && !LBMMWindow(d.requestedOffset, d.currentOffset, d.requestedLength, d.requestsAllDataToEndOfResource, size, &begin, &end)) {
    [loading finishLoadingWithError:LBMMError(1011, @"播放器请求的字节范围无效。")]; return YES;
  }
  r.next = begin; r.end = end;
  [self.pending addObject:r]; [self pump]; return YES;
}
- (void)resourceLoader:(AVAssetResourceLoader *)loader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loading {
  for (LBMMRequest *r in self.pending.copy) if (r.loading == loading) [self remove:r];
  [self pump];
}
- (LBMMRequest *)context:(NSURLSession *)session task:(NSURLSessionTask *)task {
  return session == self.session ? self.active[@(task.taskIdentifier)] : nil;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
  completionHandler(nil);
  LBMMRequest *r = [self context:session task:task];
  if (r) [self fail:r code:1004 message:@"为保护身份凭据，已拒绝媒体重定向。"];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
  // System TLS validation only; no trust bypass, login prompt, or stored HTTP credentials.
  completionHandler([challenge.protectionSpace.authenticationMethod isEqual:NSURLAuthenticationMethodServerTrust] ? NSURLSessionAuthChallengePerformDefaultHandling : NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
  LBMMRequest *r = [self context:session task:task];
  if (!r) { completionHandler(NSURLSessionResponseCancel); return; }
  if (![self currentIdentity]) { completionHandler(NSURLSessionResponseCancel); [self stop]; return; }
  NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
  r.status = http.statusCode;
  int64_t total = [self.resource[@"size"] longLongValue];
  NSString *actual = response.MIMEType.lowercaseString;
  NSString *family = [[LBMMType(self.resource) componentsSeparatedByString:@"/"] firstObject];
  BOOL generic = !actual.length || [actual isEqual:@"application/octet-stream"];
  BOOL valid = [response.URL isEqual:self.fileURL] && (generic || [actual hasPrefix:[family stringByAppendingString:@"/"]]);
  NSString *encoding = [http valueForHTTPHeaderField:@"Content-Encoding"];
  if (encoding.length && ![encoding.lowercaseString isEqual:@"identity"]) valid = NO;
  if (r.status == 206) {
    valid = valid && LBMMContentRange([http valueForHTTPHeaderField:@"Content-Range"], r.start, r.count, total) &&
        (response.expectedContentLength == NSURLResponseUnknownLength || response.expectedContentLength == r.count);
  } else if (r.status == 200) {
    // A Range-ignoring server may only supply offset zero, with exact size.
    // We stream/cancel at the bounded chunk, NEVER buffer its entire body.
    valid = valid && r.start == 0 && response.expectedContentLength == total &&
        ![http valueForHTTPHeaderField:@"Content-Range"].length;
  } else valid = NO;
  if (!valid) {
    completionHandler(NSURLSessionResponseCancel);
    BOOL unauthorized = r.status == 401; NSUInteger generation = self.generation;
    [self fail:r code:unauthorized ? 401 : 1006 message:unauthorized ? @"媒体身份验证失败，请重新验证连接。" : @"媒体响应的范围、大小或类型无效；服务器须支持字节范围播放。"];
    if (unauthorized) dispatch_async(dispatch_get_main_queue(), ^{
      if (generation == LBMemosClient.shared.generation) [LBMemosClient.shared requireAuthentication];
    });
    return;
  }
  r.accepted = YES; self.verifiedHeaders = YES; [self information:r];
  if (r.next == r.end) { completionHandler(NSURLSessionResponseCancel); [self complete:r]; [self pump]; return; }
  completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
  LBMMRequest *r = [self context:session task:task]; if (!r) return;
  if (![self currentIdentity]) { [self stop]; return; }
  if (!r.accepted || r.received > r.count || (r.status == 206 && data.length > (uint64_t)(r.count - r.received))) {
    [self fail:r code:1006 message:@"媒体返回了超出请求范围的数据。"]; return;
  }
  NSUInteger take = (NSUInteger)MIN((uint64_t)data.length, (uint64_t)(r.count - r.received));
  if (take) {
    NSData *slice = take == data.length ? data : [data subdataWithRange:NSMakeRange(0, take)];
    [r.loading.dataRequest respondWithData:slice]; r.received += take; r.next += take;
  }
  if (r.status == 200 && r.received == r.count) {
    // Explicit early cancellation, including when a single callback exceeds chunk.
    [self.active removeObjectForKey:@(task.taskIdentifier)]; [task cancel]; r.task = nil;
    if (r.next == r.end) [self complete:r];
    [self pump];
  }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  LBMMRequest *r = [self context:session task:task]; if (!r) return;
  if (![self currentIdentity]) { [self stop]; return; }
  [self.active removeObjectForKey:@(task.taskIdentifier)]; r.task = nil;
  if (error || !r.accepted || r.received != r.count) {
    [self fail:r code:1009 message:@"媒体传输中断或内容不完整，请重新点播。"]; return;
  }
  if (r.next == r.end) [self complete:r];
  [self pump];
}
@end

static void *LBMMStatusContext = &LBMMStatusContext;
@interface LBMMPlayerController : AVPlayerViewController
@property (nonatomic, strong) LBMMResourceLoader *mediaLoader;
@property (nonatomic, strong) AVPlayerItem *observedItem;
@property (nonatomic, strong) id identityObserver;
@property (nonatomic, strong) id playbackObserver;
@property NSUInteger accountGeneration;
@property BOOL started;
@property BOOL closed;
@property BOOL inlineMode;
@property (nonatomic, copy) void (^inlineFailure)(void);
@property (nonatomic, copy) NSString *failureMessage;
- (void)closeMedia;
- (void)showFailure:(NSString *)message;
@end
@implementation LBMMPlayerController
- (void)showFailure:(NSString *)message {
  self.failureMessage = message; [self closeMedia];
  if (self.inlineFailure) self.inlineFailure();
  if (!self.isViewLoaded) return;
  UILabel *label = [UILabel new]; label.text = message; label.numberOfLines = 0;
  label.textColor = UIColor.whiteColor; label.backgroundColor = UIColor.blackColor;
  label.textAlignment = NSTextAlignmentCenter; label.translatesAutoresizingMaskIntoConstraints = NO;
  UIView *host = self.contentOverlayView ?: self.view; [host addSubview:label];
  [NSLayoutConstraint activateConstraints:@[
    [label.leadingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.leadingAnchor constant:24],
    [label.trailingAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.trailingAnchor constant:-24],
    [label.centerYAnchor constraintEqualToAnchor:host.centerYAnchor]]];
}
- (void)viewDidLoad {
  [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
  if (self.failureMessage) [self showFailure:self.failureMessage];
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (self.accountGeneration != LBMemosClient.shared.generation) { [self closeMedia]; [self dismissViewControllerAnimated:NO completion:nil]; return; }
  if (!self.inlineMode && !self.started && !self.closed) {
    self.started = YES;
    // Only the controller presented by an explicit tap starts playback. AVKit
    // owns normal audio routing; no global audio-session override or microphone.
    [self.player play];
  }
}
- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated]; if (!self.inlineMode) [self closeMedia];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
  if (context != LBMMStatusContext) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
  // AVPlayerItem KVO need not arrive on main; never mutate UIKit/loader here.
  if ([(AVPlayerItem *)object status] == AVPlayerItemStatusFailed) {
    __weak LBMMPlayerController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      LBMMPlayerController *owner = weakSelf;
      if (owner && !owner.closed) [owner showFailure:@"此音视频无法播放，请检查网络或使用兼容的媒体格式。"];
    });
  }
}
- (void)closeMedia {
  if (self.closed) return; self.closed = YES;
  if (self.observedItem) [self.observedItem removeObserver:self forKeyPath:@"status" context:LBMMStatusContext];
  self.observedItem = nil;
  [self.player pause]; [self.player replaceCurrentItemWithPlayerItem:nil]; self.player = nil;
  [self.mediaLoader stop]; self.mediaLoader = nil;
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  if (self.identityObserver) [nc removeObserver:self.identityObserver]; self.identityObserver = nil;
  if (self.playbackObserver) [nc removeObserver:self.playbackObserver]; self.playbackObserver = nil;
}
- (void)dealloc { [self closeMedia]; }
@end

UIViewController *LBMemoMediaPlayer(NSDictionary *resource) {
  NSCAssert(NSThread.isMainThread, @"Media presentation requires the main queue");
  LBMMPlayerController *vc = [LBMMPlayerController new];
  LBMemosClient *api = LBMemosClient.shared; vc.accountGeneration = api.generation;
  if (!LBMemoIsPlayable(resource)) { [vc showFailure:@"不是可点播的音视频附件，或大小超过 32 MiB。"]; return vc; }
  // FIRST reuse the persistent original. It belongs to LBMemosCache; no copy,
  // full download, ownership transfer, invalidation or deletion takes place.
  NSURL *original = [api cachedResource:resource];
  AVPlayerItem *item = nil;
  if (original.isFileURL) item = [AVPlayerItem playerItemWithURL:original];
  else {
    if (!api.configured || api.authenticationRequired || !LBMMInteger(api.user[@"id"], YES) ||
        ![resource[@"creatorId"] isEqual:api.user[@"id"]] || !LBMMFileURL(api.baseURL, resource[@"id"])) {
      [vc showFailure:@"本地原文件尚未就绪，请联网并验证身份后点播。"]; return vc;
    }
    vc.mediaLoader = [[LBMMResourceLoader alloc] initWithResource:resource];
    __weak LBMMPlayerController *weakVC = vc;
    vc.mediaLoader.failure = ^(NSString *message) { [weakVC showFailure:message]; };
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:vc.mediaLoader.assetURL options:nil];
    [asset.resourceLoader setDelegate:vc.mediaLoader queue:dispatch_get_main_queue()];
    item = [AVPlayerItem playerItemWithAsset:asset];
  }
  vc.observedItem = item;
  [item addObserver:vc forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:LBMMStatusContext];
  vc.player = [AVPlayer playerWithPlayerItem:item];
  // Don't wait for a full-file predictive buffer on a tapped stream.
  vc.player.automaticallyWaitsToMinimizeStalling = NO;
  __weak LBMMPlayerController *weakVC = vc;
  vc.identityObserver = [NSNotificationCenter.defaultCenter addObserverForName:LBMemosDidChange object:api queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
    LBMMPlayerController *owner = weakVC;
    if (owner && owner.accountGeneration != LBMemosClient.shared.generation) {
      [owner closeMedia];
      if (owner.presentedViewController) [owner dismissViewControllerAnimated:NO completion:nil];
      else if (!owner.inlineMode) [owner dismissViewControllerAnimated:NO completion:nil];
    }
  }];
  vc.playbackObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
    [weakVC showFailure:@"此音视频无法播放，请检查网络或使用兼容的媒体格式。"];
  }];
  return vc;
}

// Inline owner retains the AVKit child and its resource-loader for exactly one
// memo epoch. Empty AVKit chrome/poster is safe; no remote asset before a tap.
static void *LBMMInlineRateContext = &LBMMInlineRateContext;
@interface LBMemoInlineMediaController () <AVPlayerViewControllerDelegate>
@property (nonatomic, readwrite, getter=isPresentingFullscreen) BOOL presentingFullscreen;
@end
@implementation LBMemoInlineMediaController {
  NSDictionary *_resource;
  LBMMPlayerController *_media;
  LBMMFullscreenController *_fullscreen;
  UIButton *_play;
  UIButton *_fullscreenBtn;
  UILabel *_time, *_name;
  UISlider *_seek;
  UIImageView *_poster;
  AVAssetImageGenerator *_generator;
  id _timeObserver;
  AVPlayer *_ratePlayer;
  BOOL _visible, _invalidated, _audio;
  NSUInteger _generation, _epoch;
  CMTime _resumeTime;
}
- (instancetype)initWithResource:(NSDictionary *)resource {
  if ((self = [super init])) {
    _resource = [resource copy]; _generation = LBMemosClient.shared.generation;
    _audio = [LBMMType(resource) hasPrefix:@"audio/"]; _resumeTime = kCMTimeZero;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appBecameInactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appBecameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cachedPosterAvailable:) name:LBMemosCacheDidChange object:nil];
  }
  return self;
}
- (BOOL)current {
  return !_invalidated && _generation == LBMemosClient.shared.generation;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = _audio ? LBTheme.accentSoft : UIColor.blackColor;
  self.view.layer.cornerRadius = 12; self.view.clipsToBounds = YES;
  _play = [UIButton buttonWithType:UIButtonTypeSystem];
  [_play setImage:[UIImage systemImageNamed:@"play.fill"] forState:UIControlStateNormal];
  _play.accessibilityLabel = _audio ? @"播放音频" : @"在卡片内播放视频";
  [_play addTarget:self action:@selector(togglePlayback) forControlEvents:UIControlEventTouchUpInside];
  _play.translatesAutoresizingMaskIntoConstraints = NO;
  if (_audio) {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform"]];
    icon.tintColor = LBTheme.accent; icon.translatesAutoresizingMaskIntoConstraints = NO;
    _play.tintColor = LBTheme.accent;
    _name = [UILabel new]; _name.textColor = LBTheme.ink; _name.text = _resource[@"filename"] ?: @"音频";
    _name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _name.translatesAutoresizingMaskIntoConstraints = NO;
    _time = [UILabel new]; _time.text = @"0:00 / --:--"; _time.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    _time.accessibilityLabel = @"播放进度与时长"; _time.translatesAutoresizingMaskIntoConstraints = NO;
    _seek = [UISlider new]; _seek.tintColor = LBTheme.accent; _time.textColor = LBTheme.muted;
    _seek.enabled = NO; _seek.accessibilityLabel = @"音频播放进度";
    _seek.translatesAutoresizingMaskIntoConstraints = NO;
    [_seek addTarget:self action:@selector(seekPlayback) forControlEvents:UIControlEventValueChanged];
    for (UIView *v in @[icon, _name, _play, _time, _seek]) [self.view addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
      [icon.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12], [icon.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:13],
      [icon.widthAnchor constraintEqualToConstant:20], [icon.heightAnchor constraintEqualToConstant:20],
      [_name.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8], [_name.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12],
      [_name.trailingAnchor constraintEqualToAnchor:_play.leadingAnchor constant:-8],
      [_play.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8], [_play.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:2],
      [_play.widthAnchor constraintEqualToConstant:44], [_play.heightAnchor constraintEqualToConstant:44],
      [_seek.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12], [_seek.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
      [_seek.topAnchor constraintEqualToAnchor:_name.bottomAnchor constant:2], [_seek.heightAnchor constraintEqualToConstant:24],
      [_time.leadingAnchor constraintEqualToAnchor:_seek.leadingAnchor], [_time.topAnchor constraintEqualToAnchor:_seek.bottomAnchor constant:1]]];
  } else {
    _poster = [UIImageView new]; _poster.contentMode = UIViewContentModeScaleAspectFit;
    _poster.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:_poster];
    [self pinView:_poster]; [self.view addSubview:_play];
    _play.tintColor = UIColor.whiteColor; _play.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:.4]; _play.layer.cornerRadius = 26;
    [NSLayoutConstraint activateConstraints:@[
      [_play.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor], [_play.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
      [_play.widthAnchor constraintEqualToConstant:52], [_play.heightAnchor constraintEqualToConstant:52]]];

    UIButtonConfiguration *fc = [UIButtonConfiguration glassButtonConfiguration];
    fc.image = [UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold]];
    fc.baseForegroundColor = UIColor.whiteColor;
    fc.baseBackgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.45];
    fc.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    _fullscreenBtn = [UIButton buttonWithConfiguration:fc primaryAction:nil];
    _fullscreenBtn.accessibilityLabel = @"全屏放大视频";
    __weak typeof(self) weakOwner = self;
    [_fullscreenBtn addAction:[UIAction actionWithHandler:^(UIAction *a) {
      [weakOwner openFullscreenVideo];
    }] forControlEvents:UIControlEventTouchUpInside];
    _fullscreenBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_fullscreenBtn];
    [NSLayoutConstraint activateConstraints:@[
      [_fullscreenBtn.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
      [_fullscreenBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
      [_fullscreenBtn.widthAnchor constraintEqualToConstant:36],
      [_fullscreenBtn.heightAnchor constraintEqualToConstant:36]
    ]];
  }
}
- (void)openFullscreenVideo {
  if (_audio || !_visible || ![self current] || self.presentingFullscreen) return;
  if (!_media) { [self togglePlayback]; }
  AVPlayer *p = _media.player;
  if (!p || _media.closed) return;
  UIViewController *parent = self.parentViewController ?: self;
  while (parent.parentViewController && ![parent isKindOfClass:UINavigationController.class]) {
    parent = parent.parentViewController;
  }
  if (!parent.view.window || parent.presentedViewController) return;
  [[UIImpactFeedbackGenerator feedbackGeneratorWithStyle:UIImpactFeedbackStyleLight forView:self.view] impactOccurred];
  LBMMFullscreenController *pvc = [LBMMFullscreenController new];
  pvc.player = p; pvc.showsPlaybackControls = YES;
  pvc.modalPresentationStyle = UIModalPresentationFullScreen;
  __weak typeof(self) weakSelf = self;
  __weak LBMMFullscreenController *weakFullscreen = pvc;
  pvc.didClose = ^{
    typeof(self) self = weakSelf;
    LBMMFullscreenController *fullscreen = weakFullscreen;
    if (!self || self->_fullscreen != fullscreen) return;
    self.presentingFullscreen = NO;
    fullscreen.player = nil; fullscreen.didClose = nil;
    self->_fullscreen = nil;
  };
  _fullscreen = pvc; self.presentingFullscreen = YES;
  // Expanding preserves the current paused/playing state. In particular, no
  // delayed presentation completion may restart a stopped/replaced player.
  [parent presentViewController:pvc animated:YES completion:nil];
  if (parent.presentedViewController != pvc) {
    pvc.didClose(); // rejected presentation must not leave a sticky flag
  }
}
- (void)pinView:(UIView *)view {
  view.translatesAutoresizingMaskIntoConstraints = NO;
  [NSLayoutConstraint activateConstraints:@[[view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor], [view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
}
- (void)loadCachedPoster {
  if (_audio || _poster.image || _generator || !_visible || ![self current]) return;
  NSURL *file = [LBMemosClient.shared cachedResource:_resource];
  if (!file.isFileURL) return; // NEVER thumbnail/preload the network asset.
  _generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:[AVURLAsset URLAssetWithURL:file options:nil]];
  _generator.appliesPreferredTrackTransform = YES; _generator.maximumSize = CGSizeMake(900, 506);
  NSUInteger epoch = _epoch; __weak typeof(self) weakSelf = self;
  [_generator generateCGImageAsynchronouslyForTime:kCMTimeZero completionHandler:^(CGImageRef image, CMTime actual, NSError *error) {
    UIImage *thumbnail = image && !error ? [UIImage imageWithCGImage:image] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (self && [self current] && epoch == self->_epoch && self->_visible) self->_poster.image = thumbnail;
    });
  }];
}
- (void)togglePlayback {
  if (!_visible || ![self current]) return;
  if (_media.closed) [self discardPlayer];
  if (!_media) {
    // The compatibility factory only creates the item; inlineMode suppresses
    // its legacy viewDidAppear autoplay. This path runs solely from the button.
    _media = (LBMMPlayerController *)LBMemoMediaPlayer(_resource); _media.inlineMode = YES; _media.delegate = self;
    __weak typeof(self) weakSelf = self;
    _media.inlineFailure = ^{
      typeof(self) self = weakSelf; if (!self || ![self current]) return;
      self->_play.hidden = NO; self->_play.accessibilityLabel = @"播放失败，点按重试";
      [self teardownNowPlaying];
      // Keep AVKit's sanitized error label. Move retry below it rather than
      // replacing the error overlay or obscuring its center line.
      if (!self->_audio) self->_play.transform = CGAffineTransformMakeTranslation(0, 48);
      else [self updateProgress];
    };
    [self addChildViewController:_media];
    if (!_audio) { [self.view insertSubview:_media.view belowSubview:_play]; [self pinView:_media.view]; }
    // Audio deliberately uses the compact native bar, not video chrome.
    [_media didMoveToParentViewController:self];
    _ratePlayer = _media.player;
    if (CMTIME_IS_NUMERIC(_resumeTime) && CMTimeCompare(_resumeTime, kCMTimeZero) > 0) [_ratePlayer seekToTime:_resumeTime];
    [_ratePlayer addObserver:self forKeyPath:@"rate" options:NSKeyValueObservingOptionNew context:LBMMInlineRateContext];
  }
  AVPlayer *player = _media.player;
  if (!player || _media.closed) {
    _time.text = _media.failureMessage ?: @"音频无法播放，请重新点播";
    if (_media.inlineFailure) _media.inlineFailure(); return;
  }
  _play.transform = CGAffineTransformIdentity;
  if (player.rate > 0) [self pausePlayback];
  else {
    if (self.willPlay) self.willPlay(self);
    double end = CMTimeGetSeconds(player.currentItem.duration), now = CMTimeGetSeconds(player.currentTime);
    if (isfinite(end) && end > 0 && isfinite(now) && now >= end) [player seekToTime:kCMTimeZero];
    [player play]; // explicit user tap only; no playback in visibility/observers.
    if (_audio) [self setupNowPlaying];
  }
  if (!_audio) _play.hidden = YES; // AVKit now owns play/pause and native expand.
  [self installTimeObserver]; [self updateProgress];
}
- (void)setupNowPlaying {
  if (!_audio || !_media.player) return;
  double duration = CMTimeGetSeconds(_media.player.currentItem.duration);
  NSString *name = _resource[@"filename"] ?: @"说说音频";
  [LBAudioCenter activatePlaybackWithTitle:name duration:duration player:_media.player];
}
- (void)updateNowPlaying {
  if (!_audio || !_media.player) return;
  double duration = CMTimeGetSeconds(_media.player.currentItem.duration);
  [LBAudioCenter updatePlaybackProgressWithPlayer:_media.player duration:duration];
}
- (void)teardownNowPlaying {
  if (!_audio) return;
  [LBAudioCenter deactivatePlaybackForPlayer:_ratePlayer];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
  if (context != LBMMInlineRateContext) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    typeof(self) self = weakSelf; if (!self || ![self current] || object != self->_ratePlayer) return;
    if (!self->_visible) { [self pausePlayback]; return; }
    // Also catches the native AVKit Play control after initial activation.
    if (self->_ratePlayer.rate > 0 && self.willPlay) self.willPlay(self);
    [self updateProgress]; [self updateNowPlaying];
  });
}
- (void)installTimeObserver {
  if (!_audio || !_visible || _timeObserver || !_ratePlayer) return;
  __weak typeof(self) weakSelf = self;
  _timeObserver = [_ratePlayer addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(.5, 600) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
    [weakSelf updateProgress];
  }];
}
- (void)removeTimeObserver {
  if (_timeObserver) [_ratePlayer removeTimeObserver:_timeObserver]; _timeObserver = nil;
}
- (void)updateProgress {
  if (!_audio) return;
  AVPlayer *player = _media.player;
  double duration = CMTimeGetSeconds(player.currentItem.duration), now = CMTimeGetSeconds(player.currentTime);
  BOOL ready = player.currentItem.status == AVPlayerItemStatusReadyToPlay && isfinite(duration) && duration > 0;
  now = isfinite(now) && now > 0 ? now : 0;
  _seek.enabled = ready; _seek.maximumValue = ready ? (float)duration : 1;
  if (!_seek.tracking) _seek.value = ready ? (float)MIN(now, duration) : 0;
  _time.text = _media.failureMessage ?: [NSString stringWithFormat:@"%ld:%02ld / %@", (long)(now / 60), (long)now % 60,
    ready ? [NSString stringWithFormat:@"%ld:%02ld", (long)(duration / 60), (long)duration % 60] : @"--:--"];
  BOOL playing = player.rate > 0;
  [_play setImage:[UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"] forState:UIControlStateNormal];
  _play.accessibilityLabel = playing ? @"暂停音频" : @"播放音频";
  _seek.accessibilityValue = _time.text;
}
- (void)seekPlayback {
  if (!_visible || ![self current] || !_seek.enabled || _media.player.currentItem.status != AVPlayerItemStatusReadyToPlay) return;
  [_media.player seekToTime:CMTimeMakeWithSeconds(_seek.value, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}
- (void)pausePlayback { [_media.player pause]; [self updateProgress]; [self updateNowPlaying]; }
- (void)setPageVisible:(BOOL)visible {
  _visible = visible;
  if (![self current]) { [self invalidateMedia]; return; }
  if (!visible) {
    [self pausePlayback]; [self removeTimeObserver]; [_generator cancelAllCGImageGeneration]; _generator = nil;
    // Stop authenticated requests rather than letting AVPlayer prefetch hidden.
    // A later Play tap rebuilds from cache-first and resumes the saved position.
    CMTime position = _media.player.currentTime;
    if (_media.player && CMTIME_IS_NUMERIC(position)) _resumeTime = position;
    [self discardPlayer]; if (!_audio) _play.hidden = NO;
  } else { [self loadCachedPoster]; [self installTimeObserver]; }
}
- (void)appBecameActive:(NSNotification *)note {
  if (_visible && [self current]) { [self installTimeObserver]; [self updateProgress]; [self loadCachedPoster]; }
}
- (void)cachedPosterAvailable:(NSNotification *)note { [self loadCachedPoster]; }
- (void)appBecameInactive:(NSNotification *)note {
  [self pausePlayback]; [self removeTimeObserver];
  CMTime position = _media.player.currentTime;
  if (_media.player && CMTIME_IS_NUMERIC(position)) _resumeTime = position;
  // Pausing alone permits AVFoundation to keep filling pending Range requests.
  // Release the transport; resuming requires a fresh explicit Play tap.
  [self discardPlayer]; _play.hidden = NO;
}
- (void)playerViewController:(AVPlayerViewController *)playerViewController willBeginFullScreenPresentationWithAnimationCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  self.presentingFullscreen = YES; // AVKit reuses this child and SAME player.
  __weak typeof(self) weakSelf = self;
  [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    if (context.isCancelled) weakSelf.presentingFullscreen = NO;
  }];
}
- (void)playerViewController:(AVPlayerViewController *)playerViewController willEndFullScreenPresentationWithAnimationCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  __weak typeof(self) weakSelf = self;
  BOOL registered = [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    if (!context.isCancelled) weakSelf.presentingFullscreen = NO;
  }];
  if (!registered) self.presentingFullscreen = NO;
}
- (void)discardPlayer {
  self.presentingFullscreen = NO;
  // Custom fullscreen is presented by an ancestor, not by _media itself.
  // Detach first; even a racing dismiss animation cannot retain/play the item.
  LBMMFullscreenController *fullscreen = _fullscreen; _fullscreen = nil;
  fullscreen.didClose = nil; fullscreen.player = nil;
  if (fullscreen.presentingViewController) [fullscreen dismissViewControllerAnimated:NO completion:nil];
  [self teardownNowPlaying];
  [self removeTimeObserver];
  if (_ratePlayer) [_ratePlayer removeObserver:self forKeyPath:@"rate" context:LBMMInlineRateContext]; _ratePlayer = nil;
  _media.delegate = nil; _media.inlineFailure = nil;
  if (_media.presentedViewController) [_media dismissViewControllerAnimated:NO completion:nil];
  [_media closeMedia];
  if (_media.parentViewController) { [_media willMoveToParentViewController:nil]; [_media.view removeFromSuperview]; [_media removeFromParentViewController]; }
  _media = nil;
}
- (void)invalidateMedia {
  if (_invalidated) return; _invalidated = YES; ++_epoch; _visible = NO;
  [_generator cancelAllCGImageGeneration]; _generator = nil; _poster.image = nil;
  [self discardPlayer]; self.view.hidden = YES; self.willPlay = nil;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_generator cancelAllCGImageGeneration]; [self discardPlayer]; }
@end

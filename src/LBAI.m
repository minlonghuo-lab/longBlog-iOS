#import "LBAI.h"
#include <stdint.h>
#include <stddef.h>

static NSString *const LBAIBaseKey = @"lb.ai.baseURL";
static NSString *const LBAIModelKey = @"lb.ai.model";
static NSString *const LBAIKeychainAccount = @"ai-api-key";
static const NSUInteger LBAIMaxBodyBytes = 4 * 1024 * 1024;
static const NSUInteger LBAIMaxLineBytes = 256 * 1024;
static const NSUInteger LBAIMaxEventBytes = 1024 * 1024;
static const NSUInteger LBAIMaxOutputCharacters = 2 * 1024 * 1024;

static NSError *LBAIError(NSInteger code, NSString *message) {
  return [NSError errorWithDomain:@"LBAIError" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Server error bodies are shown only as a short provider message, never the
// request, headers or key.
static NSString *LBAIServerMessage(NSData *body) {
  id json = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
  id error = [json isKindOfClass:NSDictionary.class] ? json[@"error"] : nil;
  id message = [error isKindOfClass:NSDictionary.class] ? error[@"message"] : error;
  if (![message isKindOfClass:NSString.class] || ![(NSString *)message length]) return nil;
  NSString *text = message;
  return text.length > 160 ? [[text substringToIndex:160] stringByAppendingString:@"…"] : text;
}

#pragma mark - Streaming task

// Scan only NEW bytes. The native helper is also exercised by the host fixture.
static size_t LBAINextLineBreak(const uint8_t *bytes, size_t length, size_t start) {
  for (size_t i = start; i < length; i++) {
    if (bytes[i] == '\r' || bytes[i] == '\n') return i;
  }
  return length;
}

@interface LBAIStream : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, copy) void (^onDelta)(NSString *);
@property (nonatomic, copy) void (^done)(NSString *, NSError *);
@property (atomic) BOOL cancelled;
- (void)cancel;
- (void)beginRequest:(NSURLRequest *)request;
- (void)completeWithText:(NSString *)text error:(NSError *)error;
@end

@implementation LBAIStream {
  // Parser state belongs ONLY to NSURLSession's serial delegate queue.
  NSMutableData *_pending, *_raw;
  NSMutableString *_event, *_full;
  NSInteger _status;
  BOOL _eventStream, _skipLF, _sawDone;
  NSUInteger _eventBytes;
  NSError *_parseError;
  // Delivery/task state is shared with main/cancel/preparation queues.
  NSURLSessionDataTask *_task;
  NSMutableString *_delivery;
  BOOL _flushScheduled, _completionQueued, _finished;
}
- (instancetype)init {
  if ((self = [super init])) {
    _pending = [NSMutableData data]; _raw = [NSMutableData data];
    _event = [NSMutableString string]; _full = [NSMutableString string];
    _delivery = [NSMutableString string];
  }
  return self;
}
- (void)cancel {
  @synchronized (self) {
    self.cancelled = YES;
    [_task cancel];
    [_delivery setString:@""];
  }
}
- (void)beginRequest:(NSURLRequest *)request {
  @synchronized (self) {
    if (self.cancelled) return;
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 90;
    config.timeoutIntervalForResource = 300;
    // nil creates a serial background delegate queue; never parse on main.
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    _task = [session dataTaskWithRequest:request];
    [_task resume];
  }
}
- (void)queueDelta:(NSString *)delta {
  if (!delta.length) return;
  @synchronized (self) {
    if (self.cancelled || _finished || _completionQueued) return;
    [_delivery appendString:delta];
    if (_flushScheduled) return;
    _flushScheduled = YES;
  }
  // At most one pending main-queue flush, even when main is busy. Token-sized
  // network packets must not cause token-sized UITextView layout/scroll bursts.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    NSString *chunk;
    @synchronized (self) {
      self->_flushScheduled = NO;
      if (self.cancelled || self->_finished) return;
      chunk = [self->_delivery copy];
      [self->_delivery setString:@""];
    }
    if (!self.cancelled && chunk.length && self.onDelta) self.onDelta(chunk);
  });
}
- (void)completeWithText:(NSString *)text error:(NSError *)error {
  @synchronized (self) {
    if (self.cancelled || _completionQueued || _finished) return;
    _completionQueued = YES;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString *tail;
    @synchronized (self) {
      if (self.cancelled || self->_finished) return;
      self->_finished = YES;
      tail = [self->_delivery copy];
      [self->_delivery setString:@""];
    }
    // The final buffered delta ALWAYS precedes done (including JSON fallback).
    if (!self.cancelled && tail.length && self.onDelta) self.onDelta(tail);
    if (!self.cancelled && self.done) self.done(text, error);
  });
}
- (void)failParsing:(NSString *)message {
  if (!_parseError) _parseError = LBAIError(-2, message);
  [self completeWithText:nil error:_parseError];
  @synchronized (self) { [_task cancel]; }
}
- (void)consumeEvent {
  if (!_eventBytes || _sawDone || _parseError) return;
  NSString *payload = [_event copy];
  [_event setString:@""]; _eventBytes = 0;
  if (![payload stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return;
  if ([[payload stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqualToString:@"[DONE]"]) {
    _sawDone = YES;
    [self completeWithText:[_full copy] error:nil];
    // Some providers keep the socket open after [DONE]. Do not wait 300s.
    @synchronized (self) { [_task cancel]; }
    return;
  }
  id json = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  if (![json isKindOfClass:NSDictionary.class]) {
    [self failParsing:@"无法识别的流式响应，请确认接口兼容 OpenAI Chat Completions"]; return;
  }
  if (json[@"error"] && json[@"error"] != NSNull.null) {
    NSString *message = LBAIServerMessage([payload dataUsingEncoding:NSUTF8StringEncoding]);
    [self failParsing:message ?: @"AI 服务返回错误，请稍后重试"]; return;
  }
  NSArray *choices = json[@"choices"];
  id first = [choices isKindOfClass:NSArray.class] && choices.count ? choices.firstObject : nil;
  id delta = [first isKindOfClass:NSDictionary.class] ? first[@"delta"] : nil;
  id content = [delta isKindOfClass:NSDictionary.class] ? delta[@"content"] : nil;
  if (![content isKindOfClass:NSString.class] || ![content length]) return;
  if ([content length] > LBAIMaxOutputCharacters - _full.length) {
    [self failParsing:@"AI 输出过长，请缩小生成范围后重试"]; return;
  }
  [_full appendString:content];
  [self queueDelta:content];
}
- (void)consumeLine {
  NSString *line = [[NSString alloc] initWithData:_pending encoding:NSUTF8StringEncoding];
  [_pending setLength:0];
  if (!line) { [self failParsing:@"流式响应包含无效的 UTF-8 数据"]; return; }
  if (!line.length) { [self consumeEvent]; return; }
  // Comments, event/id/retry fields are ignored. Do not trim SSE data values.
  if (![line hasPrefix:@"data:"]) return;
  NSString *value = [line substringFromIndex:5];
  if ([value hasPrefix:@" "]) value = [value substringFromIndex:1];
  NSUInteger bytes = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
  if (bytes > LBAIMaxEventBytes - _eventBytes) {
    [self failParsing:@"流式响应事件过长，请缩小生成范围后重试"]; return;
  }
  if (_eventBytes) [_event appendString:@"\n"];
  [_event appendString:value]; _eventBytes += bytes;
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
  NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
  _status = http.statusCode;
  _eventStream = [[http valueForHTTPHeaderField:@"Content-Type"].lowercaseString containsString:@"text/event-stream"];
  completionHandler(self.cancelled ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
  if (self.cancelled || _sawDone || _parseError) return;
  if (_status != 200 || !_eventStream) {
    if (data.length > LBAIMaxBodyBytes - _raw.length) {
      [self failParsing:@"响应内容过大，请确认接口地址或缩小生成范围"]; return;
    }
    [_raw appendData:data];
    return;
  }
  const uint8_t *bytes = data.bytes;
  size_t cursor = 0;
  while (cursor < data.length && !_sawDone && !_parseError && !self.cancelled) {
    if (_skipLF) { _skipLF = NO; if (bytes[cursor] == '\n') { cursor++; continue; } }
    size_t end = LBAINextLineBreak(bytes, data.length, cursor);
    if (end - cursor > LBAIMaxLineBytes - _pending.length) {
      [self failParsing:@"流式响应行过长，请确认接口兼容性"]; return;
    }
    [_pending appendBytes:bytes + cursor length:end - cursor];
    if (end == data.length) break;
    _skipLF = bytes[end] == '\r';
    [self consumeLine];
    cursor = end + 1;
  }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
  [session finishTasksAndInvalidate];
  @synchronized (self) { _task = nil; }
  if (self.cancelled || _sawDone || _parseError) return;
  NSString *full = nil;
  NSError *failure = nil;
  if (error) {
    failure = error.code == NSURLErrorTimedOut ? LBAIError(-1, @"请求超时，请检查网络或稍后重试")
                                               : LBAIError(-1, @"网络连接失败，请检查网络与接口地址");
  } else if (_status != 200) {
    NSString *server = LBAIServerMessage(_raw);
    NSString *reason = _status == 401 || _status == 403 ? @"密钥无效或没有权限" :
                       _status == 404 ? @"接口地址或模型不存在" :
                       _status == 429 ? @"请求过于频繁或额度已用完" : [NSString stringWithFormat:@"服务返回 HTTP %ld", (long)_status];
    failure = LBAIError(_status, server.length ? [NSString stringWithFormat:@"%@：%@", reason, server] : reason);
  } else if (_eventStream) {
    // Be lenient with compatible servers omitting the final blank line/newline.
    if (_pending.length) [self consumeLine];
    [self consumeEvent];
    if (_sawDone || _parseError) return;
    full = [_full copy];
  } else {
    id json = [NSJSONSerialization JSONObjectWithData:_raw options:0 error:nil];
    NSArray *choices = [json isKindOfClass:NSDictionary.class] ? json[@"choices"] : nil;
    id first = [choices isKindOfClass:NSArray.class] && choices.count ? choices.firstObject : nil;
    id message = [first isKindOfClass:NSDictionary.class] ? first[@"message"] : nil;
    id content = [message isKindOfClass:NSDictionary.class] ? message[@"content"] : nil;
    full = [content isKindOfClass:NSString.class] ? content : nil;
    if (!full) failure = LBAIError(-2, @"无法识别的响应格式，请确认接口兼容 OpenAI Chat Completions");
    else if (full.length > LBAIMaxOutputCharacters) { full = nil; failure = LBAIError(-2, @"AI 输出过长，请缩小生成范围后重试"); }
    else [self queueDelta:full];
  }
  [self completeWithText:full error:failure];
}
@end

#pragma mark - Client

@implementation LBAI
+ (instancetype)shared {
  static LBAI *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [LBAI new]; });
  return s;
}
- (NSString *)baseURL { return [NSUserDefaults.standardUserDefaults stringForKey:LBAIBaseKey] ?: @""; }
- (void)setBaseURL:(NSString *)value {
  NSString *v = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (v.length) [NSUserDefaults.standardUserDefaults setObject:v forKey:LBAIBaseKey];
  else [NSUserDefaults.standardUserDefaults removeObjectForKey:LBAIBaseKey];
}
- (NSString *)model { return [NSUserDefaults.standardUserDefaults stringForKey:LBAIModelKey] ?: @""; }
- (void)setModel:(NSString *)value {
  NSString *v = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (v.length) [NSUserDefaults.standardUserDefaults setObject:v forKey:LBAIModelKey];
  else [NSUserDefaults.standardUserDefaults removeObjectForKey:LBAIModelKey];
}
- (NSString *)apiKey { return [LBKeychain get:LBAIKeychainAccount]; }
- (void)setApiKey:(NSString *)apiKey { [LBKeychain set:apiKey.length ? apiKey : nil account:LBAIKeychainAccount]; }
- (BOOL)configured { return self.model.length && [LBAI endpointForBase:self.baseURL] && self.apiKey.length; }
- (void)checkConfigured:(void (^)(BOOL))completion {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    BOOL ready = self.configured;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(ready); });
  });
}

+ (NSURL *)endpointForBase:(NSString *)base {
  NSString *s = [base stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  while ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
  NSURLComponents *c = [NSURLComponents componentsWithString:s];
  if (![c.scheme.lowercaseString isEqualToString:@"https"] || !c.host.length || c.user || c.password || c.query || c.fragment) return nil;
  if (![s hasSuffix:@"/chat/completions"]) s = [s stringByAppendingString:@"/chat/completions"];
  return [NSURL URLWithString:s];
}

- (void (^)(void))streamSystem:(NSString *)system prompt:(NSString *)prompt maxTokens:(NSInteger)maxTokens
                       onDelta:(void (^)(NSString *))onDelta done:(void (^)(NSString *, NSError *))done {
  // Return a cancellation token before touching Keychain or serializing a
  // potentially large prompt. Even validation errors obey that same token.
  LBAIStream *stream = [LBAIStream new];
  stream.onDelta = onDelta;
  stream.done = done;
  NSString *base = self.baseURL, *model = self.model;
  NSString *systemSnapshot = [system copy], *promptSnapshot = [prompt copy];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    if (stream.cancelled) return;
    NSURL *url = [LBAI endpointForBase:base];
    NSString *key = url && model.length ? self.apiKey : nil;
    if (stream.cancelled) return;
    if (!url || !key.length || !model.length) {
      [stream completeWithText:nil error:LBAIError(-3, @"请先在「连接与设置 → AI 写作助手」中填写接口地址、模型和密钥")];
      return;
    }
    NSMutableDictionary *body = [@{@"model": model, @"stream": @YES,
      @"messages": @[@{@"role": @"system", @"content": systemSnapshot ?: @""}, @{@"role": @"user", @"content": promptSnapshot ?: @""}]} mutableCopy];
    if (maxTokens > 0) body[@"max_tokens"] = @(maxTokens);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 90;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"text/event-stream, application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    NSError *serializationError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&serializationError];
    if (serializationError || !request.HTTPBody) {
      [stream completeWithText:nil error:LBAIError(-2, @"无法编码请求内容，请检查输入文字")]; return;
    }
    [stream beginRequest:request];
  });
  return ^{ [stream cancel]; };
}
@end

#pragma mark - Result sheet

@implementation LBAIResultViewController {
  NSString *_system, *_prompt, *_applyTitle;
  void (^_apply)(NSString *);
  void (^_cancel)(void);
  UITextView *_text;
  UILabel *_status;
  UIButton *_applyButton, *_retryButton, *_copyButton;
  NSUInteger _generation;
  BOOL _hasStarted;
}

- (instancetype)initWithTitle:(NSString *)title applyTitle:(NSString *)applyTitle system:(NSString *)system
                       prompt:(NSString *)prompt apply:(void (^)(NSString *))apply {
  if ((self = [super init])) {
    self.title = title;
    _applyTitle = [applyTitle copy]; _system = [system copy]; _prompt = [prompt copy]; _apply = [apply copy];
  }
  return self;
}

- (UIButton *)pill:(NSString *)title symbol:(NSString *)symbol prominent:(BOOL)prominent action:(SEL)action {
  UIButtonConfiguration *c = prominent ? [UIButtonConfiguration prominentGlassButtonConfiguration] : [UIButtonConfiguration glassButtonConfiguration];
  c.title = title;
  c.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]];
  c.imagePadding = 6;
  c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
  c.contentInsets = NSDirectionalEdgeInsetsMake(12, 14, 12, 14);
  if (prominent) c.baseBackgroundColor = LBTheme.accent; else c.baseForegroundColor = LBTheme.ink;
  UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
  [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
  return b;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = LBTheme.paper;
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];

  _status = [UILabel new];
  _status.font = [LBTheme rounded:12 weight:UIFontWeightMedium];
  _status.textColor = LBTheme.muted;
  _status.numberOfLines = 0;

  _text = [UITextView new];
  _text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  _text.adjustsFontForContentSizeCategory = YES;
  _text.textColor = LBTheme.ink;
  _text.tintColor = LBTheme.accent;
  _text.backgroundColor = [LBTheme.surface colorWithAlphaComponent:0.6];
  _text.layer.cornerRadius = 16;
  _text.layer.cornerCurve = kCACornerCurveContinuous;
  _text.textContainerInset = UIEdgeInsetsMake(14, 10, 14, 10);
  _text.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  _text.smartDashesType = UITextSmartDashesTypeNo;
  _text.smartQuotesType = UITextSmartQuotesTypeNo;

  _retryButton = [self pill:@"重新生成" symbol:@"arrow.clockwise" prominent:NO action:@selector(start)];
  _copyButton = [self pill:@"复制" symbol:@"doc.on.doc" prominent:NO action:@selector(copyResult)];
  _applyButton = [self pill:_applyTitle symbol:@"checkmark" prominent:YES action:@selector(applyResult)];
  UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[_retryButton, _copyButton, _applyButton]];
  buttons.spacing = 8;
  buttons.distribution = UIStackViewDistributionFillProportionally;

  UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_status, _text, buttons]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 10;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:stack];
  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
    [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    [stack.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-12],
  ]];
  _status.text = @"正在准备…";
  [self setBusy:YES];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (!_hasStarted) [self start];
}

- (void)dealloc { if (_cancel) _cancel(); }

- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  if (self.isBeingDismissed || self.navigationController.isBeingDismissed) [self stop];
}

- (void)stop { _generation++; if (_cancel) _cancel(); _cancel = nil; }

- (void)setBusy:(BOOL)busy {
  _text.editable = !busy;
  _applyButton.enabled = !busy && _text.text.length > 0;
  _copyButton.enabled = !busy && _text.text.length > 0;
  _retryButton.enabled = !busy;
  UIButtonConfiguration *c = _retryButton.configuration;
  c.showsActivityIndicator = busy;
  _retryButton.configuration = c;
}

- (void)start {
  _hasStarted = YES;
  [self stop];
  NSUInteger generation = _generation;
  _text.text = @"";
  _status.text = [NSString stringWithFormat:@"正在生成 · %@", LBAI.shared.model];
  _status.textColor = LBTheme.muted;
  [self setBusy:YES];
  __weak typeof(self) weakSelf = self;
  _cancel = [LBAI.shared streamSystem:_system prompt:_prompt maxTokens:0 onDelta:^(NSString *delta) {
    typeof(self) me = weakSelf;
    if (!me || me->_generation != generation) return;
    // Append without resetting the scroll position of the whole text.
    [me->_text.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:delta
        attributes:@{NSFontAttributeName: me->_text.font, NSForegroundColorAttributeName: LBTheme.ink}]];
    if (!me->_text.isDragging && !me->_text.isDecelerating && !me->_text.isTracking)
      [me->_text scrollRangeToVisible:NSMakeRange(me->_text.textStorage.length, 0)];
  } done:^(NSString *full, NSError *error) {
    typeof(self) me = weakSelf;
    if (!me || me->_generation != generation) return;
    me->_cancel = nil;
    if (error) {
      me->_status.text = error.localizedDescription;
      me->_status.textColor = UIColor.systemRedColor;
      [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeError];
    } else {
      NSString *clean = [full ?: me->_text.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      me->_text.text = clean;
      me->_status.text = clean.length ? @"已完成，可直接修改后再应用" : @"模型没有返回内容，请重新生成";
      [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
    [me setBusy:NO];
  }];
}

- (void)copyResult {
  if (_text.text.length) UIPasteboard.generalPasteboard.string = _text.text;
  _status.text = @"已复制到剪贴板";
}

- (void)applyResult {
  NSString *text = [_text.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!text.length) return;
  void (^apply)(NSString *) = _apply;
  [self stop];
  [self dismissViewControllerAnimated:YES completion:^{ if (apply) apply(text); }];
}

- (void)close { [self stop]; [self dismissViewControllerAnimated:YES completion:nil]; }
@end

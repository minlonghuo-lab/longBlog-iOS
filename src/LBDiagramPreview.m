#import "LBDiagramPreview.h"
#import "LB.h"
#import "LBMemos.h"
#import <WebKit/WebKit.h>

// Recheck the trusted-world output before creating an inert image document.
// Bounded parser work, no DTD/entities, no network-bearing tags or attributes.
@interface LBDiagramSVGCheck : NSObject <NSXMLParserDelegate>
@property (nonatomic) BOOL valid;
@property (nonatomic) NSUInteger nodes, depth;
@property (nonatomic) CGSize size;
@property (nonatomic, strong) NSSet<NSString *> *tags;
@end
@implementation LBDiagramSVGCheck
- (instancetype)init {
  if ((self = [super init])) {
    _valid = YES;
    _tags = [NSSet setWithArray:[@"svg g defs marker path rect circle ellipse line polyline polygon text tspan title desc style clipPath linearGradient radialGradient stop pattern symbol use" componentsSeparatedByString:@" "]];
  } return self;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified attributes:(NSDictionary<NSString *, NSString *> *)attrs {
  (void)uri; (void)qualified;
  if (++_nodes > 12000 || ++_depth > 81 || ![_tags containsObject:name] || (_depth == 1 && ![name isEqual:@"svg"])) { _valid = NO; [parser abortParsing]; return; }
  for (NSString *key in attrs) {
    NSString *lower = key.lowercaseString, *value = attrs[key];
    if ([lower hasPrefix:@"on"] || [@[@"src", @"srcset", @"target", @"tabindex", @"xml:base"] containsObject:lower] ||
        ([lower hasSuffix:@"href"] && ![value hasPrefix:@"#"]) ||
        ([lower isEqual:@"xmlns"] && ![value isEqual:@"http://www.w3.org/2000/svg"]) ||
        ([lower hasPrefix:@"xmlns:"] && ![value isEqual:@"http://www.w3.org/2000/svg"])) { _valid = NO; [parser abortParsing]; return; }
  }
  if (_depth == 1) {
    NSScanner *scanner = [NSScanner scannerWithString:attrs[@"viewBox"] ?: @""];
    scanner.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@" ,\t\r\n"];
    double v[4];
    for (NSUInteger i = 0; i < 4; i++) if (![scanner scanDouble:&v[i]] || !isfinite(v[i])) { _valid = NO; [parser abortParsing]; return; }
    if (!scanner.isAtEnd || v[2] <= 0 || v[3] <= 0 || v[2] > 20000 || v[3] > 20000) { _valid = NO; [parser abortParsing]; return; }
    _size = CGSizeMake(v[2], v[3]);
  }
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified {
  (void)parser; (void)name; (void)uri; (void)qualified; if (_depth) --_depth;
}
- (void)parser:(NSXMLParser *)parser foundProcessingInstructionWithTarget:(NSString *)target data:(NSString *)data {
  (void)target; (void)data; _valid = NO; [parser abortParsing];
}
@end

static NSString *LBDiagramCheckedURL(NSString *url, CGSize *size) {
  NSString *prefix = @"data:image/svg+xml;charset=utf-8,";
  // encodeURIComponent can expand a 2M-code-unit SVG to 18M ASCII bytes in
  // the worst UTF-8 case. Intentionally cap the bridge at 8M, decoded at 2M.
  if (![url isKindOfClass:NSString.class] || url.length > 8000000 || ![url hasPrefix:prefix]) return nil;
  NSString *encoded = [url substringFromIndex:prefix.length];
  NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()%"];
  if ([encoded rangeOfCharacterFromSet:safe.invertedSet].location != NSNotFound) return nil;
  NSString *svg = encoded.stringByRemovingPercentEncoding;
  if (!svg.length || svg.length > 2000000 || [svg containsString:@"<!"] || [svg containsString:@"<?"]) return nil;
  // SVG is still an img, with script-src none and img-src data:. Reject
  // external CSS/attribute references as defence in depth (xmlns is constant).
  NSString *check = [svg stringByReplacingOccurrencesOfString:@"http://www.w3.org/2000/svg" withString:@""];
  if ([check rangeOfString:@"(?:https?:|file:|ftp:|data:|javascript:|@|expression|\\\\|url\\(\\s*[^#])" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) return nil;
  LBDiagramSVGCheck *validator = [LBDiagramSVGCheck new];
  NSXMLParser *parser = [[NSXMLParser alloc] initWithData:[svg dataUsingEncoding:NSUTF8StringEncoding]];
  parser.shouldResolveExternalEntities = NO; parser.delegate = validator;
  if (![parser parse] || !validator.valid || validator.size.width <= 0) return nil;
  *size = validator.size; return url;
}

@interface LBDiagramPreviewController () <WKNavigationDelegate, UIScrollViewDelegate>
@end
@implementation LBDiagramPreviewController {
  NSString *_dataURL;
  NSNumber *_memoGeneration;
  CGSize _diagramSize, _lastBounds;
  UIScrollView *_scroll;
  WKWebView *_image;
  UILabel *_status;
  BOOL _closed;
}
+ (instancetype)previewWithDataURL:(NSString *)dataURL memoGeneration:(NSNumber *)generation {
  CGSize size = CGSizeZero;
  NSString *checked = LBDiagramCheckedURL(dataURL, &size);
  if (!checked || (generation && generation.unsignedIntegerValue != LBMemosClient.shared.generation)) return nil;
  LBDiagramPreviewController *preview = [self new];
  preview->_dataURL = [checked copy]; preview->_diagramSize = size; preview->_memoGeneration = generation;
  preview.modalPresentationStyle = UIModalPresentationPageSheet;
  return preview;
}
- (void)viewDidLoad {
  [super viewDidLoad]; self.view.backgroundColor = LBTheme.paper;
  if (_memoGeneration) [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(accountChanged:) name:LBMemosDidChange object:nil];
  if (_memoGeneration && _memoGeneration.unsignedIntegerValue != LBMemosClient.shared.generation) { [self close]; return; }
  self.sheetPresentationController.detents = @[[UISheetPresentationControllerDetent largeDetent]];
  self.sheetPresentationController.prefersGrabberVisible = YES;
  self.view.accessibilityViewIsModal = YES;
  UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
  [close setTitle:@"关闭" forState:UIControlStateNormal]; [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
  close.accessibilityLabel = @"关闭图表预览"; close.tintColor = LBTheme.accent;
  close.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; close.titleLabel.adjustsFontForContentSizeCategory = YES;
  [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
  UILabel *title = [UILabel new]; title.text = @"图表预览"; title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
  title.adjustsFontForContentSizeCategory = YES; title.textColor = LBTheme.ink;
  UIButton *fit = [UIButton buttonWithType:UIButtonTypeSystem]; [fit setTitle:@"适合屏幕" forState:UIControlStateNormal];
  fit.tintColor = LBTheme.accent; fit.accessibilityLabel = @"还原图表，适合屏幕";
  [fit addTarget:self action:@selector(resetZoom) forControlEvents:UIControlEventTouchUpInside];
  UIStackView *bar = [[UIStackView alloc] initWithArrangedSubviews:@[title, fit, close]];
  bar.spacing = 8; bar.alignment = UIStackViewAlignmentCenter;
  _scroll = [UIScrollView new]; _scroll.delegate = self; _scroll.minimumZoomScale = 1; _scroll.maximumZoomScale = 5;
  _scroll.bouncesZoom = YES; _scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  _scroll.accessibilityLabel = @"图表，可双指缩放或双击放大";
  WKWebViewConfiguration *config = [WKWebViewConfiguration new];
  config.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
  config.defaultWebpagePreferences.allowsContentJavaScript = NO;
  config.preferences.javaScriptCanOpenWindowsAutomatically = NO;
  _image = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config]; _image.navigationDelegate = self;
  _image.opaque = NO; _image.backgroundColor = UIColor.clearColor; _image.scrollView.backgroundColor = UIColor.clearColor;
  _image.scrollView.scrollEnabled = NO; _image.userInteractionEnabled = NO;
  _image.accessibilityLabel = @"Mermaid 图表";
  [_scroll addSubview:_image];
  UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(doubleTap:)]; doubleTap.numberOfTapsRequired = 2; [_scroll addGestureRecognizer:doubleTap];
  _status = [UILabel new]; _status.text = @"双指缩放 · 双击放大 · 下滑关闭";
  _status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; _status.adjustsFontForContentSizeCategory = YES;
  _status.textColor = LBTheme.muted; _status.textAlignment = NSTextAlignmentCenter; _status.numberOfLines = 0;
  for (UIView *v in @[bar, _scroll, _status]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:v]; }
  UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [bar.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:8], [bar.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:16], [bar.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-16],
    [close.widthAnchor constraintGreaterThanOrEqualToConstant:64], [close.heightAnchor constraintGreaterThanOrEqualToConstant:44], [fit.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    [_scroll.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:8], [_scroll.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:12], [_scroll.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-12],
    [_status.topAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:8], [_status.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:16], [_status.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-16], [_status.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-8]]];
  // Constant document, only a checked percent-encoded image URL interpolated.
  // No bridge, scripts, files, frames or network loads in this WebKit instance.
  NSString *html = [NSString stringWithFormat:@"<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'\"><style>html,body{margin:0;width:100%%;height:100%%;overflow:hidden;background:transparent}img{display:block;width:100%%;height:100%%;object-fit:contain}</style></head><body><img alt='Mermaid 图表' src=\"%@\"></body></html>", _dataURL];
  [_image loadHTMLString:html baseURL:nil];
}
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGSize bounds = _scroll.bounds.size;
  if (bounds.width <= 0 || bounds.height <= 0 || CGSizeEqualToSize(bounds, _lastBounds)) return;
  _lastBounds = bounds; _scroll.zoomScale = 1;
  CGFloat scale = MIN(bounds.width / _diagramSize.width, bounds.height / _diagramSize.height);
  _image.frame = CGRectMake(0, 0, MAX(1, _diagramSize.width * scale), MAX(1, _diagramSize.height * scale));
  _scroll.contentSize = _image.bounds.size; [self centerImage];
}
- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView { (void)scrollView; return _image; }
- (void)scrollViewDidZoom:(UIScrollView *)scrollView { (void)scrollView; [self centerImage]; }
- (void)centerImage {
  CGSize bounds = _scroll.bounds.size, image = _image.frame.size;
  _scroll.contentInset = UIEdgeInsetsMake(MAX(0, (bounds.height-image.height)/2), MAX(0, (bounds.width-image.width)/2), 0, 0);
}
- (void)resetZoom { [_scroll setZoomScale:1 animated:YES]; }
- (void)doubleTap:(UITapGestureRecognizer *)gesture {
  if (_scroll.zoomScale > 1.05) { [self resetZoom]; return; }
  CGPoint point = [gesture locationInView:_image]; CGFloat scale = 2.5;
  CGSize size = CGSizeMake(_scroll.bounds.size.width/scale, _scroll.bounds.size.height/scale);
  [_scroll zoomToRect:CGRectMake(point.x-size.width/2, point.y-size.height/2, size.width, size.height) animated:YES];
}
- (BOOL)accessibilityPerformEscape { [self close]; return YES; }
- (void)accountChanged:(NSNotification *)note {
  (void)note; if (_memoGeneration && _memoGeneration.unsignedIntegerValue != LBMemosClient.shared.generation) [self close];
}
- (void)close {
  if (_closed) return; _closed = YES; _dataURL = nil;
  [_image stopLoading]; _image.navigationDelegate = nil; [_image removeFromSuperview]; _image = nil;
  [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; if (!self.presentingViewController) [self close]; }
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
  (void)webView;
  BOOL initial = action.navigationType == WKNavigationTypeOther && action.targetFrame.mainFrame && [action.request.URL.absoluteString isEqual:@"about:blank"];
  handler(initial ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  (void)webView; _status.text = @"图表显示已中断，请关闭后重新打开。";
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

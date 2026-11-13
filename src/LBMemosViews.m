#import "LBMemos.h"
#import "LBNavigationController.h"
#import "LBPostReader.h"
#import <QuickLook/QuickLook.h>

void LBMemosShowError(UIViewController *from, NSError *error) {
  if (!from.viewIfLoaded.window || from.presentedViewController) return;
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"操作未完成" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
  [from presentViewController:a animated:YES completion:nil];
}
NSString *LBMemoVisibility(NSString *value) {
  if ([value isEqual:@"PRIVATE"]) return @"仅自己";
  if ([value isEqual:@"PROTECTED"]) return @"登录可见";
  return @"公开";
}
NSString *LBMemoPlain(NSString *markdown) {
  NSString *s = markdown ?: @"";
  for (NSArray *pair in @[ @[ @"!\\[[^\\]]*\\]\\([^)]*\\)", @"[图片]" ], @[ @"\\[([^\\]]+)\\]\\([^)]*\\)", @"$1" ], @[ @"(?m)^#{1,6}\\s+", @"" ], @[ @"(\\*\\*|__|~~)", @"" ] ])
    s = [s stringByReplacingOccurrencesOfString:pair[0] withString:pair[1] options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)];
  return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
UIViewController *LBMemoMarkdownPreview(NSDictionary *memo) {
  NSString *content = [memo[@"content"] isKindOfClass:NSString.class] ? memo[@"content"] : @"";
  NSNumber *created = [memo[@"createdTs"] isKindOfClass:NSNumber.class] ? memo[@"createdTs"] : nil;
  double seconds = created.doubleValue;
  BOOL hasCreationDate = created && isfinite(seconds) && seconds > 0 && seconds < 253402300800.0;
  NSMutableDictionary *post = [@{ @"id":@"memo-preview", @"title":hasCreationDate ? @"说说预览" : @"草稿预览",
      @"html":@"", @"markdown":content, @"isPrivateMemoPreview":@YES,
      @"readerBaseURL":[LBMemosClient.shared.baseURL stringByAppendingString:@"/"],
      @"memosGeneration":@(LBMemosClient.shared.generation) } mutableCopy];
  // Missing/zero/invalid time is intentionally absent, never an epoch placeholder.
  if (hasCreationDate) post[@"publishedAt"] = @(seconds * 1000);
  return [[LBPostReaderViewController alloc] initWithPost:post];
}

@interface LBMemosConnection : UIViewController
@end
@implementation LBMemosConnection {
  UITextField *_base, *_token;
  UILabel *_status;
  UIButton *_connect;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"连接 Memos";
  self.view.backgroundColor = LBTheme.paper;
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
  _base = [UITextField new]; _base.text = LBMemosClient.shared.baseURL; _base.placeholder = @"https://shuoshuo.ssaw.top";
  _token = [UITextField new]; _token.text = LBMemosClient.shared.token; _token.placeholder = @"Memos 访问令牌";
  _token.secureTextEntry = YES; _token.textContentType = UITextContentTypePassword;
  for (UITextField *field in @[ _base, _token ]) {
    field.font = [LBTheme mono:14 weight:UIFontWeightRegular]; field.textColor = LBTheme.ink;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.borderStyle = UITextBorderStyleRoundedRect; field.clearButtonMode = UITextFieldViewModeWhileEditing;
    [field.heightAnchor constraintEqualToConstant:44].active = YES;
  }
  _base.keyboardType = UIKeyboardTypeURL;
  UILabel *info = [UILabel new]; info.numberOfLines = 0; info.font = [UIFont systemFontOfSize:14]; info.textColor = LBTheme.muted;
  info.text = @"直连你的 Cloudflare Workers Memos。令牌仅存本机钥匙串，不进入博客公开镜像。\n\n支持本人普通/归档说说、Markdown、可见性、置顶和附件。新建默认仅自己可见。\n附件单个最多32 MiB；正文私密不等于外链附件服务受控。";
  _status = [UILabel new]; _status.numberOfLines = 0; _status.font = [UIFont systemFontOfSize:14]; _status.textColor = LBTheme.accent;
  UIButtonConfiguration *c = [UIButtonConfiguration prominentGlassButtonConfiguration]; c.title = @"保存并验证身份"; c.baseBackgroundColor = LBTheme.accent;
  _connect = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [self connect]; }]];
  UIButtonConfiguration *clearConfig = [UIButtonConfiguration glassButtonConfiguration]; clearConfig.title = @"断开并清除本机令牌";
  UIButton *clear = [UIButton buttonWithConfiguration:clearConfig primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [self disconnect]; }]];
  UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ _base, _token, _connect, _status, info, clear ]];
  stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = NO;
  UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO; scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  [self.view addSubview:scroll]; [scroll addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20], [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-30],
    [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20], [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20] ]];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)connect {
  [self.view endEditing:YES];
  NSURLComponents *u = [NSURLComponents componentsWithString:[_base.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
  NSString *key = [_token.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (![u.scheme isEqual:@"https"] || !u.host.length || u.user.length || u.password.length || u.query.length || u.fragment.length || (u.path.length && ![u.path isEqual:@"/"])) { _status.text = @"请输入不带路径、参数和账户信息的 HTTPS 根地址"; return; }
  if (!key.length || [key rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) { _status.text = @"请填写有效的访问令牌"; return; }
  LBMemosClient *api = LBMemosClient.shared;
  if (![api configureBaseURL:_base.text token:key]) { _status.text = @"钥匙串保存失败，请检查签名权限"; return; }
  _connect.enabled = NO; _status.text = @"正在验证账户…";
  NSUInteger revision = api.generation;
  [api validate:^(NSDictionary *user, NSError *error) {
    self->_connect.enabled = YES;
    if (revision != api.generation) { self->_status.text = @"连接已改变，请重新验证"; return; }
    self->_status.text = error ? error.localizedDescription : @"✓ 已连接。普通说说和归档均使用本人身份读取。";
    if (user) [NSNotificationCenter.defaultCenter postNotificationName:LBMemosDidChange object:api];
  }];
}
- (void)disconnect {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"清除本机Memos令牌？" message:@"不会删除服务器上的说说。未发布草稿不会自动发布。" preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:@"清除令牌" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { LBMemosClient.shared.token = nil; [LBMemosClient.shared reset]; self->_token.text = @""; self->_status.text = @"已断开"; }]];
  [self presentViewController:a animated:YES completion:nil];
}
@end
void LBMemosPresentConnection(UIViewController *from) {
  UIViewController *top = from; while (top.presentedViewController) top = top.presentedViewController;
  LBNavigationController *nav = [[LBNavigationController alloc] initWithRootViewController:[LBMemosConnection new]];
  nav.modalPresentationStyle = UIModalPresentationPageSheet; nav.sheetPresentationController.prefersGrabberVisible = YES;
  [top presentViewController:nav animated:YES completion:nil];
}

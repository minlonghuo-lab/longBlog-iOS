#import "LB.h"
#import "LBMdStore.h"
#import "LBMemos.h"
#import "LBNavigationController.h"
#import "LBAI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface LBSettingsViewController () <UITextFieldDelegate, UIDocumentPickerDelegate>
@end

void LBPresentSettings(UIViewController *from) {
  UIViewController *top = from;
  while (top.presentedViewController) top = top.presentedViewController;
  UINavigationController *n = [[LBNavigationController alloc] initWithRootViewController:[LBSettingsViewController new]];
  n.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
  n.sheetPresentationController.prefersGrabberVisible = YES;
  [top presentViewController:n animated:YES completion:nil];
}

@implementation LBSettingsViewController {
  UITextField *_key, *_base, *_gh, *_repo, *_site, *_hosts, *_memosBase, *_memosToken, *_aiBase, *_aiModel, *_aiKey;
  UILabel *_folderLabel;
  UILabel *_result;
  UIView *_resultCard;
  UILabel *_githubStatus, *_workspaceStatus, *_memosStatus, *_chatStatus, *_aiStatus;
  UIButton *_test;
  NSUInteger _saveGeneration;
  BOOL _testing;
}
static UIVisualEffectView *card(UIView *content) {
  UIVisualEffectView *g = [LBTheme glassWithTint:[LBTheme.surface colorWithAlphaComponent:0.3] interactive:NO];
  g.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:24]];
  content.translatesAutoresizingMaskIntoConstraints = NO;
  [g.contentView addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.topAnchor constraintEqualToAnchor:g.contentView.topAnchor constant:16],
    [content.bottomAnchor constraintEqualToAnchor:g.contentView.bottomAnchor constant:-16],
    [content.leadingAnchor constraintEqualToAnchor:g.contentView.leadingAnchor constant:18],
    [content.trailingAnchor constraintEqualToAnchor:g.contentView.trailingAnchor constant:-18],
  ]];
  return g;
}
static UILabel *label(NSString *t, UIFont *f, UIColor *c) {
  UILabel *l = [UILabel new];
  l.text = t; l.font = f; l.textColor = c; l.numberOfLines = 0;
  return l;
}
// Field caption (small, muted) — the card header carries the section identity.
static UILabel *heading(NSString *t) { return label(t, [LBTheme rounded:12 weight:UIFontWeightSemibold], LBTheme.muted); }
static UILabel *help(NSString *t) { return label(t, [UIFont systemFontOfSize:12], LBTheme.muted); }
static UIStackView *vstack(NSArray *views) {
  UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
  s.axis = UILayoutConstraintAxisVertical;
  s.spacing = 6;
  for (UIView *v in views) if ([v isKindOfClass:UITextField.class]) [s setCustomSpacing:4 afterView:v];
  return s;
}
static UILabel *statusChip(void) {
  UILabel *l = [UILabel new];
  l.font = [LBTheme rounded:11 weight:UIFontWeightSemibold];
  l.textAlignment = NSTextAlignmentCenter;
  l.layer.cornerRadius = 10;
  l.layer.cornerCurve = kCACornerCurveContinuous;
  l.clipsToBounds = YES;
  [l.heightAnchor constraintEqualToConstant:20].active = YES;
  [l setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  [l setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  return l;
}
static void setChip(UILabel *chip, NSString *text, BOOL on) {
  UIColor *color = on ? UIColor.systemGreenColor : LBTheme.muted;
  chip.text = [NSString stringWithFormat:@"  %@  ", text];
  chip.textColor = color;
  chip.backgroundColor = [color colorWithAlphaComponent:0.14];
}
// Settings-app style section header: tinted icon tile, title, live status chip.
static UIView *sectionHeader(NSString *symbol, UIColor *tint, NSString *title, UILabel *_Nullable chip) {
  UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol
      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold]]];
  icon.tintColor = UIColor.whiteColor;
  icon.contentMode = UIViewContentModeCenter;
  icon.backgroundColor = tint;
  icon.layer.cornerRadius = 8;
  icon.layer.cornerCurve = kCACornerCurveContinuous;
  icon.translatesAutoresizingMaskIntoConstraints = NO;
  [NSLayoutConstraint activateConstraints:@[[icon.widthAnchor constraintEqualToConstant:30], [icon.heightAnchor constraintEqualToConstant:30]]];
  UILabel *name = label(title, [LBTheme rounded:16 weight:UIFontWeightBold], LBTheme.ink);
  name.numberOfLines = 1;
  NSMutableArray *views = [@[icon, name, [UIView new]] mutableCopy];
  if (chip) [views addObject:chip];
  UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
  row.spacing = 10;
  row.alignment = UIStackViewAlignmentCenter;
  UIStackView *wrap = [[UIStackView alloc] initWithArrangedSubviews:@[row]];
  wrap.layoutMargins = UIEdgeInsetsMake(0, 0, 6, 0);
  wrap.layoutMarginsRelativeArrangement = YES;
  return wrap;
}
- (UITextField *)field:(NSString *)placeholder secure:(BOOL)secure url:(BOOL)url {
  UITextField *f = [UITextField new];
  f.placeholder = placeholder;
  f.font = [LBTheme mono:url ? 13 : 14 weight:UIFontWeightRegular];
  f.textColor = LBTheme.ink;
  f.tintColor = LBTheme.accent;
  f.secureTextEntry = secure;
  f.autocapitalizationType = UITextAutocapitalizationTypeNone;
  f.autocorrectionType = UITextAutocorrectionTypeNo;
  f.spellCheckingType = UITextSpellCheckingTypeNo;
  f.returnKeyType = UIReturnKeyDone;
  // Filled, rounded input wells instead of bare lines inside glass.
  f.backgroundColor = UIColor.tertiarySystemFillColor;
  f.layer.cornerRadius = 11;
  f.layer.cornerCurve = kCACornerCurveContinuous;
  f.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
  f.leftViewMode = UITextFieldViewModeAlways;
  if (url) f.keyboardType = UIKeyboardTypeURL;
  if (secure) {
    f.textContentType = UITextContentTypePassword;
    // Reveal toggle replaces the clear button for secrets.
    UIButtonConfiguration *eye = [UIButtonConfiguration plainButtonConfiguration];
    eye.image = [UIImage systemImageNamed:@"eye" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightMedium]];
    eye.baseForegroundColor = LBTheme.muted;
    eye.contentInsets = NSDirectionalEdgeInsetsMake(0, 10, 0, 12);
    __weak UITextField *weakField = f;
    UIButton *toggle = [UIButton buttonWithConfiguration:eye primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
      UITextField *field = weakField; if (!field) return;
      field.secureTextEntry = !field.secureTextEntry;
      UIButtonConfiguration *c = ((UIButton *)a.sender).configuration;
      c.image = [UIImage systemImageNamed:field.secureTextEntry ? @"eye" : @"eye.slash"
          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightMedium]];
      ((UIButton *)a.sender).configuration = c;
    }]];
    toggle.accessibilityLabel = @"显示或隐藏";
    f.rightView = toggle;
    f.rightViewMode = UITextFieldViewModeAlways;
  } else {
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
  }
  f.delegate = self;
  [f addTarget:self action:@selector(settingsEdited:) forControlEvents:UIControlEventEditingChanged];
  [f.heightAnchor constraintEqualToConstant:42].active = YES;
  return f;
}
- (UIButton *)linkButton:(NSString *)title symbol:(NSString *)symbol color:(UIColor *)color action:(SEL)action {
  UIButtonConfiguration *c = [UIButtonConfiguration grayButtonConfiguration];
  c.title = title;
  c.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold]];
  c.imagePadding = 6;
  c.baseForegroundColor = color;
  c.cornerStyle = UIButtonConfigurationCornerStyleMedium;
  c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *in) {
    NSMutableDictionary *out = [in mutableCopy]; out[NSFontAttributeName] = [LBTheme rounded:13 weight:UIFontWeightSemibold]; return out;
  };
  UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
  [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
  return b;
}
- (void)refreshStatus {
  setChip(_githubStatus, LBGitHub.shared.configured ? @"已配置" : @"未配置", LBGitHub.shared.configured);
  setChip(_workspaceStatus, LBMdStore.shared.isCustomFolder ? @"自定义目录" : @"内置目录", YES);
  setChip(_memosStatus, LBMemosClient.shared.token.length ? @"已配置" : @"未连接", LBMemosClient.shared.token.length > 0);
  setChip(_chatStatus, LBAPI.shared.ownerKey.length ? @"已配置" : @"未配置", LBAPI.shared.ownerKey.length > 0);
  setChip(_aiStatus, LBAI.shared.configured ? @"已配置" : @"未配置", LBAI.shared.configured);
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"连接与设置";
  LBAuroraView *bg = [[LBAuroraView alloc] initWithFrame:self.view.bounds];
  bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:bg];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                         target:self action:@selector(close)];
  self.navigationItem.rightBarButtonItem.style = UIBarButtonItemStyleProminent;

  UIScrollView *scroll = [UIScrollView new];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  scroll.alwaysBounceVertical = YES;
  [self.view addSubview:scroll];
  scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
  [self setContentScrollView:scroll forEdge:NSDirectionalRectEdgeTop];
  scroll.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle;
  scroll.topEdgeEffect.hidden = NO;
  scroll.bottomEdgeEffect.hidden = YES;

  _key = [self field:@"粘贴 64 位站长密钥" secure:YES url:NO];
  _key.text = LBAPI.shared.ownerKey;
  _base = [self field:LBDefaultAPIBase secure:NO url:YES];
  _base.text = LBAPI.shared.baseURL;
  _gh = [self field:@"github_pat_… 或 ghp_…" secure:YES url:NO];
  _gh.text = LBGitHub.shared.token;
  _repo = [self field:@"owner/name" secure:NO url:YES];
  _repo.text = LBStore.repo;
  _site = [self field:@"https://huowenlong.com" secure:NO url:YES];
  _site.text = LBStore.siteURL;
  _hosts = [self field:@"huowenlong.com, …" secure:NO url:YES];
  _hosts.text = [LBStore.certHosts componentsJoinedByString:@", "];
  _memosBase = [self field:LBMemosClient.shared.baseURL secure:NO url:YES];
  _memosBase.text = LBMemosClient.shared.baseURL;
  _memosToken = [self field:@"Memos 访问令牌（留空断开连接）" secure:YES url:NO];
  _memosToken.text = LBMemosClient.shared.token; // Client reads the device Keychain, never preferences.
  _aiBase = [self field:@"https://api.openai.com/v1" secure:NO url:YES];
  _aiBase.text = LBAI.shared.baseURL;
  _aiModel = [self field:@"gpt-4o-mini / deepseek-chat …" secure:NO url:YES];
  _aiModel.text = LBAI.shared.model;
  _aiKey = [self field:@"sk-…（只存本机钥匙串）" secure:YES url:NO];
  _aiKey.text = LBAI.shared.apiKey;

  _githubStatus = statusChip(); _workspaceStatus = statusChip(); _memosStatus = statusChip();
  _chatStatus = statusChip(); _aiStatus = statusChip();

  _folderLabel = label([NSString stringWithFormat:@"当前目录：%@%@", LBMdStore.shared.folderDisplayName, LBMdStore.shared.isCustomFolder ? @" (自定义挂载)" : @" (内置沙盒)"],
                       [LBTheme rounded:13 weight:UIFontWeightMedium], LBTheme.ink);
  UIButton *chooseBtn = [self linkButton:@"选择目录" symbol:@"folder.badge.plus" color:LBTheme.accent action:@selector(chooseFolderPressed)];
  UIButton *resetBtn = [self linkButton:@"恢复默认" symbol:@"arrow.uturn.backward" color:LBTheme.muted action:@selector(resetFolderPressed)];
  resetBtn.accessibilityLabel = @"恢复为默认沙盒目录 (Documents/Posts)";
  UIStackView *folderButtons = [[UIStackView alloc] initWithArrangedSubviews:@[chooseBtn, resetBtn]];
  folderButtons.spacing = 8;
  folderButtons.distribution = UIStackViewDistributionFillEqually;

  UIView *github = card(vstack(@[ sectionHeader(@"chevron.left.forwardslash.chevron.right", UIColor.systemIndigoColor, @"GitHub 仓库", _githubStatus),
    heading(@"GitHub 令牌"), _gh,
    help(@"用于读取文章数据、部署状态，并提交站点配置（.env）和发布 Markdown 文章。建议使用只授权本仓库、仅 Contents 读写的细粒度令牌。只存本机钥匙串。"),
    heading(@"仓库"), _repo ]));
  UIView *workspace = card(vstack(@[ sectionHeader(@"folder.fill", UIColor.systemOrangeColor, @"文章工作区 · Markdown 本地目录", _workspaceStatus),
    _folderLabel, folderButtons,
    help(@"配置 GitHub 令牌并选择目录后，自动下载文章与附件。本地修改和草稿不会被覆盖；发布、下架通过 GitHub 原子提交，成功后触发站点构建。") ]));
  UIView *memos = card(vstack(@[ sectionHeader(@"text.bubble.fill", UIColor.systemTealColor, @"说说 · Memos", _memosStatus),
    heading(@"Memos 根地址"), _memosBase,
    help(@"填写 HTTPS 根地址，不带 /api 路径、查询参数或账号密码。与公开说说镜像、留言接口相互独立。"),
    heading(@"Memos 访问令牌"), _memosToken,
    help(@"仅存本机钥匙串，不同步 iCloud。保存时验证本人身份；清空令牌并保存即可断开，不会删除远端说说或本地草稿。") ]));
  UIView *chat = card(vstack(@[ sectionHeader(@"bubble.left.and.bubble.right.fill", UIColor.systemBlueColor, @"终端留言", _chatStatus),
    heading(@"站长密钥"), _key,
    help(@"只保存在本机钥匙串，不同步 iCloud。在部署目录运行 node scripts/terminal-chat-owner-key.mjs 生成。"),
    heading(@"留言接口地址"), _base ]));
  UIView *ai = card(vstack(@[ sectionHeader(@"sparkles", UIColor.systemPurpleColor, @"AI 写作助手", _aiStatus),
    heading(@"接口地址"), _aiBase, heading(@"模型"), _aiModel, heading(@"API 密钥"), _aiKey,
    help(@"兼容 OpenAI Chat Completions 的服务均可（OpenAI、DeepSeek、硅基流动、自建代理等），必须是 HTTPS。密钥只存本机钥匙串。用于在文章编辑器里生成/润色摘要与正文。") ]));
  UIView *site = card(vstack(@[ sectionHeader(@"globe", UIColor.systemGreenColor, @"站点与监控", nil),
    heading(@"站点地址"), _site, help(@"说说镜像与构建信息从这里读取（公开数据，无需凭据）。"),
    heading(@"证书监控域名"), _hosts, help(@"逗号分隔，仪表盘会检查这些域名的 HTTPS 证书到期时间。") ]));

  UIButtonConfiguration *bc = [UIButtonConfiguration prominentGlassButtonConfiguration];
  bc.title = @"保存并测试连接";
  bc.image = [UIImage systemImageNamed:@"bolt.horizontal.circle"];
  bc.imagePadding = 8;
  bc.baseBackgroundColor = LBTheme.accent;
  bc.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
  bc.contentInsets = NSDirectionalEdgeInsetsMake(15, 20, 15, 20);
  __weak typeof(self) weakSelf = self;
  _test = [UIButton buttonWithConfiguration:bc primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [weakSelf saveAndTest]; }]];
  _test.translatesAutoresizingMaskIntoConstraints = NO;
  _result = label(@"", [LBTheme rounded:13 weight:UIFontWeightMedium], LBTheme.muted);
  _resultCard = card(vstack(@[ sectionHeader(@"checkmark.seal.fill", LBTheme.accent, @"连接结果", nil), _result ]));
  _resultCard.hidden = YES;

  UIView *notes = card(vstack(@[ sectionHeader(@"bell.badge.fill", UIColor.systemRedColor, @"通知说明", nil),
    label(@"• App 在前台时每 12 秒同步留言，打开的会话每 5 秒刷新。\n"
          @"• 退到后台后，由 iOS 后台刷新唤醒检查新留言并推送本地通知；时机由系统决定，可能延迟数分钟到数小时。\n"
          @"• 请在 设置 → 通用 → 后台 App 刷新 中保持本 App 开启，并允许通知。\n"
          @"• 通知横幅可直接下拉输入回复。企业微信通知仍照常发送，作为兜底。",
          [UIFont systemFontOfSize:13], LBTheme.ink) ]));

  // The result sits at the top so it is visible right after tapping the pinned button.
  NSMutableArray *cards = [@[ _resultCard, github, workspace, memos, chat, ai, site, notes ] mutableCopy];
  UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:cards];
  st.axis = UILayoutConstraintAxisVertical;
  st.spacing = 14;
  st.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:st];
  [self.view addSubview:_test];
  UILayoutGuide *cg = scroll.contentLayoutGuide, *fg = scroll.frameLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [st.topAnchor constraintEqualToAnchor:cg.topAnchor constant:12],
    [st.bottomAnchor constraintEqualToAnchor:cg.bottomAnchor constant:-96],
    [st.leadingAnchor constraintEqualToAnchor:fg.leadingAnchor constant:16],
    [st.trailingAnchor constraintEqualToAnchor:fg.trailingAnchor constant:-16],
    // Primary action floats above content and keyboard, always reachable.
    [_test.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-10],
    [_test.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
    [_test.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
  ]];
  [self refreshStatus];
}
- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
    _saveGeneration++;
    [self setTesting:NO];
  }
}
- (BOOL)textFieldShouldReturn:(UITextField *)f { [f resignFirstResponder]; return YES; }
- (void)close { _saveGeneration++; [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)settingsEdited:(UITextField *)field {
  _saveGeneration++;
  [self setTesting:NO];
  [self show:@"配置已修改，请保存并重新测试" ok:YES];
}
- (void)setTesting:(BOOL)testing {
  _testing = testing;
  _test.enabled = !testing;
  UIButtonConfiguration *c = _test.configuration;
  c.showsActivityIndicator = testing;
  _test.configuration = c;
}
static NSString *trim(NSString *s) { return [s ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }
static BOOL https(NSString *s) { NSURL *u = [NSURL URLWithString:s]; return [u.scheme isEqualToString:@"https"] && u.host.length; }
// Mirror the client's root-origin normalization before comparing, so an
// unrelated global save does not reset Memos identity, transfers or drafts.
static NSString *memosRoot(NSString *value) {
  NSString *s = trim(value);
  if ([s rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
      [s rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
  NSURLComponents *c = [NSURLComponents componentsWithString:s];
  if (![c.scheme.lowercaseString isEqualToString:@"https"] || !c.host.length || c.user != nil || c.password != nil ||
      c.query != nil || c.fragment != nil || (c.path.length && ![c.path isEqualToString:@"/"])) return nil;
  if (c.port && (c.port.integerValue < 1 || c.port.integerValue > 65535)) return nil;
  c.scheme = @"https"; c.host = c.host.lowercaseString; c.path = @"";
  if ([c.port isEqual:@443]) c.port = nil;
  return c.URL.absoluteString;
}
// Never surface server bodies, identity names, request URLs or underlying
// NSError descriptions here, even if a future transport stops sanitizing them.
static NSString *memosFailure(NSError *error) {
  if (![error.domain isEqualToString:@"LBMemosError"]) return @"连接失败，请检查网络后重试";
  switch (error.code) {
    case 401: return @"令牌无效或过期，请检查后重新测试";
    case 403: return @"没有访问权限";
    case 1003: return @"正在写入，请稍后测试";
    case 1006: return @"身份数据格式无效";
    case 4091: return @"连接状态已改变，请重新测试";
    default: return @"身份验证失败，请检查地址、令牌和网络";
  }
}

- (void)saveAndTest {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self saveAndTest]; }); return; }
  if (_testing) return;
  [self.view endEditing:YES];
  NSUInteger revision = ++_saveGeneration;
  NSString *memosBase = memosRoot(_memosBase.text), *memosToken = trim(_memosToken.text);
  if (!memosBase) return [self show:@"Memos 地址必须是 HTTPS 根地址，不带路径、查询参数或账号密码" ok:NO];
  if ([memosToken rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound ||
      [memosToken rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
    return [self show:@"Memos 令牌不能包含空格或控制字符；留空可断开连接" ok:NO];
  NSString *key = trim(_key.text), *gh = trim(_gh.text), *repo = trim(_repo.text), *site = trim(_site.text);
  NSRegularExpression *hex = [NSRegularExpression regularExpressionWithPattern:@"^[a-f0-9]{64}$" options:0 error:nil];
  if (key.length && ![hex firstMatchInString:key options:0 range:NSMakeRange(0, key.length)]) return [self show:@"站长密钥应为 64 位小写十六进制" ok:NO];
  if (!https(trim(_base.text))) return [self show:@"留言接口地址必须是 HTTPS 链接" ok:NO];
  if (!https(site)) return [self show:@"站点地址必须是 HTTPS 链接" ok:NO];
  if ([repo rangeOfString:@"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$" options:NSRegularExpressionSearch].location == NSNotFound)
    return [self show:@"仓库格式应为 owner/name" ok:NO];
  if ([gh rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return [self show:@"GitHub 令牌不能包含空格" ok:NO];
  NSString *aiBase = trim(_aiBase.text), *aiModel = trim(_aiModel.text), *aiKey = trim(_aiKey.text);
  if (aiBase.length && ![LBAI endpointForBase:aiBase]) return [self show:@"AI 接口地址必须是 HTTPS 链接，例如 https://api.openai.com/v1" ok:NO];
  if ([aiKey rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return [self show:@"AI 密钥不能包含空格" ok:NO];
  for (NSString *part in [_hosts.text componentsSeparatedByString:@","]) {
    NSString *host = trim(part);
    if (!host.length) continue;
    if (host.length > 253 || [host rangeOfString:@"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$" options:NSRegularExpressionSearch].location == NSNotFound)
      return [self show:@"证书监控请只填域名，不带 https://、端口或路径" ok:NO];
  }

  BOOL siteChanged = ![gh isEqualToString:LBGitHub.shared.token ?: @""] || ![repo isEqualToString:LBStore.repo]
      || ![site isEqualToString:LBStore.siteURL] || ![trim(_hosts.text) isEqualToString:[LBStore.certHosts componentsJoinedByString:@", "]];
  BOOL chatChanged = ![key isEqualToString:LBAPI.shared.ownerKey ?: @""] || ![trim(_base.text) isEqualToString:LBAPI.shared.baseURL];
  LBMemosClient *memos = LBMemosClient.shared;
  BOOL memosChanged = ![memosBase isEqualToString:memosRoot(memos.baseURL)] ||
      ![memosToken isEqualToString:trim(memos.token)];
  if (memosChanged && ![memos configureBaseURL:memosBase token:memosToken]) {
    [self show:@"Memos 钥匙串保存失败，请检查应用签名和钥匙串权限" ok:NO];
    return;
  }
  NSUInteger memosGeneration = memos.generation;
  _memosBase.text = memosBase;
  _memosToken.text = memosToken;
  LBAPI.shared.ownerKey = key;
  LBAPI.shared.baseURL = trim(_base.text);
  if (chatChanged) [LBSync.shared resetBaseline];
  LBGitHub.shared.token = gh;
  LBAI.shared.baseURL = aiBase;
  LBAI.shared.model = aiModel;
  LBAI.shared.apiKey = aiKey;
  if (![LBAPI.shared.ownerKey ?: @"" isEqualToString:key] || ![LBGitHub.shared.token ?: @"" isEqualToString:gh] ||
      ![LBAI.shared.apiKey ?: @"" isEqualToString:aiKey]) {
    [self show:@"钥匙串保存失败，请检查应用签名和钥匙串权限；旧凭据未被覆盖时会保留" ok:NO];
    return;
  }
  LBStore.repo = repo;
  LBStore.siteURL = site;
  LBStore.certHosts = _hosts.text;
  if (siteChanged) [LBSiteData.shared resetConnection];

  [self setTesting:YES];
  [self show:@"连接中…" ok:YES];
  NSMutableArray *lines = [NSMutableArray array];
  [lines addObject:[NSString stringWithFormat:@"✓ 文章工作区：%@%@", LBMdStore.shared.folderDisplayName, LBMdStore.shared.isCustomFolder ? @" (自定义)" : @" (内置)"]];
  dispatch_group_t g = dispatch_group_create();
  if (key.length) {
    dispatch_group_enter(g);
    [LBSync.shared refresh:^(BOOL fresh) {
      dispatch_async(dispatch_get_main_queue(), ^{
        NSError *e = LBSync.shared.lastError;
        [lines addObject:e ? [@"✕ 留言：" stringByAppendingString:e.localizedDescription]
                           : [NSString stringWithFormat:@"✓ 留言：%lu 个进行中的会话", (unsigned long)LBSync.shared.sessions.count]];
        dispatch_group_leave(g);
      });
    }];
  } else [lines addObject:@"– 留言：未填写站长密钥"];
  if (gh.length) {
    dispatch_group_enter(g);
    [LBMdStore.shared syncFromGitHub:^(NSError *e) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [lines addObject:e ? [@"✕ 文章下载：" stringByAppendingString:e.localizedDescription] : @"✓ GitHub：文章与附件已同步到当前目录（保留本地修改）"];
        dispatch_group_leave(g);
      });
    }];
  } else [lines addObject:@"– GitHub：未填写令牌（文章与配置不可用）"];
  if (LBAI.shared.configured) {
    dispatch_group_enter(g);
    // A one-token probe: proves URL, model and key without spending real quota.
    [LBAI.shared streamSystem:@"Reply with OK." prompt:@"ping" maxTokens:1 onDelta:^(NSString *text) {} done:^(NSString *full, NSError *error) {
      [lines addObject:error ? [@"✕ AI：" stringByAppendingString:error.localizedDescription] : [@"✓ AI：模型可用 · " stringByAppendingString:aiModel]];
      dispatch_group_leave(g);
    }];
  } else [lines addObject:aiKey.length || aiBase.length || aiModel.length ? @"✕ AI：接口地址、模型和密钥需全部填写" : @"– AI：未配置（编辑器 AI 功能不可用）"];
  if (memosToken.length) {
    dispatch_group_enter(g);
    // Exactly one explicit identity check; no notification-driven auth retry.
    [memos validate:^(NSDictionary *user, NSError *error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (revision == self->_saveGeneration && memosGeneration == memos.generation) {
          [lines addObject:error ? [@"✕ Memos：" stringByAppendingString:memosFailure(error)] :
              (user ? @"✓ Memos：身份已验证" : @"✕ Memos：身份验证失败")];
        }
        // Balance even when editing, closing, reset or a 401 invalidates it.
        dispatch_group_leave(g);
      });
    }];
  } else [lines addObject:@"– Memos：未填写令牌（已断开连接）"];
  dispatch_group_notify(g, dispatch_get_main_queue(), ^{
    if (revision != self->_saveGeneration) return;
    [self setTesting:NO];
    if (memosGeneration != memos.generation) {
      for (NSString *line in [lines copy]) {
        if ([line hasPrefix:@"✓ Memos："] || [line hasPrefix:@"✕ Memos："] || [line hasPrefix:@"– Memos："])
          [lines removeObject:line];
      }
      [lines addObject:@"✕ Memos：连接状态已改变或令牌已过期，请检查后重新测试"];
    }
    BOOL ok = YES;
    for (NSString *l in lines) if ([l hasPrefix:@"✕"]) ok = NO;
    [self show:[lines componentsJoinedByString:@"\n"] ok:ok];
    [[UINotificationFeedbackGenerator feedbackGeneratorForView:self.view] notificationOccurred:ok ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
    [LBSiteData.shared refreshAll:nil];
  });
}
- (void)show:(NSString *)t ok:(BOOL)ok {
  _result.text = t;
  _result.textColor = ok ? LBTheme.ink : UIColor.systemRedColor;
  [self refreshStatus];
  if (_resultCard.hidden == (t.length > 0)) {
    [UIView animateWithDuration:0.25 animations:^{ self->_resultCard.hidden = t.length == 0; self->_resultCard.alpha = t.length ? 1 : 0; }];
  }
}

- (void)chooseFolderPressed {
  UIDocumentPickerViewController *doc = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
  doc.delegate = self;
  doc.allowsMultipleSelection = NO;
  [self presentViewController:doc animated:YES completion:nil];
}

- (void)resetFolderPressed {
  [LBMdStore.shared resetFolderToDefault];
  _folderLabel.text = [NSString stringWithFormat:@"当前目录：%@ (内置沙盒)", LBMdStore.shared.folderDisplayName];
  [self show:@"已恢复为默认沙盒目录" ok:YES];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  if (!urls.count) return;
  NSURL *url = urls.firstObject;
  NSError *err = nil;
  BOOL ok = [LBMdStore.shared setFolderURL:url error:&err];
  if (ok) {
    if (![LBMdStore.shared migrateToArticleFoldersWithError:&err]) {
      [self show:err.localizedDescription ?: @"目录整理未完成，旧文件已保留" ok:NO];
      return;
    }
    _folderLabel.text = [NSString stringWithFormat:@"当前目录：%@ (自定义挂载)", LBMdStore.shared.folderDisplayName];
    if (LBGitHub.shared.configured) {
      [self show:@"已绑定目录，正在下载文章与附件…" ok:YES];
      [LBMdStore.shared syncFromGitHub:^(NSError *error) {
        [self show:error ? error.localizedDescription : @"文章与附件已下载，保留本地草稿与修改" ok:error == nil];
      }];
    } else {
      [self show:@"目录已绑定；保存 GitHub 令牌后自动下载文章与附件" ok:YES];
    }
  } else {
    [self show:err.localizedDescription ?: @"绑定目录失败" ok:NO];
  }
}
@end

#import "LBLayout.h"
#import "LBNavigationController.h"

#pragma mark - Single value editor
@interface LBValueEditor : UIViewController <UITextViewDelegate>
- (instancetype)initWithFile:(LBEnvFile *)file key:(NSString *)key help:(NSString *)help done:(void (^)(void))done;
@end

@implementation LBValueEditor {
  LBEnvFile *_file;
  NSString *_key, *_help;
  void (^_done)(void);
  UITextView *_text;
  UILabel *_error;
}
- (instancetype)initWithFile:(LBEnvFile *)file key:(NSString *)key help:(NSString *)help done:(void (^)(void))done {
  if ((self = [super init])) { _file = file; _key = key; _help = help; _done = [done copy]; }
  return self;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = LBTheme.paper;
  self.title = [LBEnvFile labelFor:_key];
  self.navigationItem.subtitle = _key;
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
  UIBarButtonItem *ok = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(save)];
  ok.style = UIBarButtonItemStyleProminent;
  self.navigationItem.rightBarButtonItem = ok;
  UIVisualEffectView *g = [LBTheme glassWithTint:[LBTheme.surface colorWithAlphaComponent:0.5] interactive:NO];
  g.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:22]];
  _text = [UITextView new];
  _text.translatesAutoresizingMaskIntoConstraints = NO;
  _text.backgroundColor = UIColor.clearColor;
  _text.font = [UIFont systemFontOfSize:17];
  _text.textColor = LBTheme.ink;
  _text.text = [_file valueFor:_key] ?: @"";
  _text.delegate = self;
  _text.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
  BOOL urlish = [_key hasSuffix:@"_URL"] || [_key hasSuffix:@"_AVATAR"] || [_key hasSuffix:@"_GITHUB"];
  if (urlish) { _text.keyboardType = UIKeyboardTypeURL; _text.autocapitalizationType = UITextAutocapitalizationTypeNone; _text.autocorrectionType = UITextAutocorrectionTypeNo; }
  _text.returnKeyType = UIReturnKeyDone;
  [g.contentView addSubview:_text];
  UILabel *help = [UILabel new];
  help.text = _help.length ? _help : @"修改后点“完成”，回到配置页统一预览并提交。";
  help.font = [UIFont systemFontOfSize:13];
  help.textColor = LBTheme.muted;
  help.numberOfLines = 0;
  _error = [UILabel new];
  _error.font = [LBTheme rounded:13 weight:UIFontWeightSemibold];
  _error.textColor = UIColor.systemRedColor;
  _error.numberOfLines = 0;
  UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[ g, help, _error ]];
  st.axis = UILayoutConstraintAxisVertical;
  st.spacing = 10;
  st.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:st];
  [NSLayoutConstraint activateConstraints:@[
    [_text.topAnchor constraintEqualToAnchor:g.contentView.topAnchor], [_text.bottomAnchor constraintEqualToAnchor:g.contentView.bottomAnchor],
    [_text.leadingAnchor constraintEqualToAnchor:g.contentView.leadingAnchor], [_text.trailingAnchor constraintEqualToAnchor:g.contentView.trailingAnchor],
    [_text.heightAnchor constraintGreaterThanOrEqualToConstant:urlish ? 70 : 130],
    [st.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
    [st.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
    [st.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
  ]];
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [_text becomeFirstResponder]; }
- (BOOL)textView:(UITextView *)tv shouldChangeTextInRange:(NSRange)r replacementText:(NSString *)t {
  if ([t isEqualToString:@"\n"]) { [self save]; return NO; } // values are single-line
  return YES;
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)save {
  NSString *err = [_file updateValue:_text.text forKey:_key];
  if (err) {
    _error.text = err;
    [[UINotificationFeedbackGenerator feedbackGeneratorForView:self.view] notificationOccurred:UINotificationFeedbackTypeError];
    return;
  }
  if (_done) _done();
  [self dismissViewControllerAnimated:YES completion:nil];
}
@end

#pragma mark - Commit review
@interface LBReviewViewController : UIViewController
- (instancetype)initWithOriginal:(NSString *)orig edited:(NSString *)edited sha:(NSString *)sha done:(void (^)(NSString *commit))done;
@end

@implementation LBReviewViewController {
  NSString *_orig, *_edited, *_sha, *_repo;
  void (^_done)(NSString *);
  UITextField *_message;
  UIButton *_commit;
  UILabel *_status;
}
- (instancetype)initWithOriginal:(NSString *)o edited:(NSString *)e sha:(NSString *)sha done:(void (^)(NSString *))done {
  if ((self = [super init])) { _orig = o; _edited = e; _sha = sha; _repo = LBStore.repo; _done = [done copy]; }
  return self;
}
/// Line diff by key: the editor only replaces/inserts/removes whole lines.
- (NSAttributedString *)diff {
  NSArray *a = [_orig componentsSeparatedByString:@"\n"], *b = [_edited componentsSeparatedByString:@"\n"];
  NSInteger n = a.count, m = b.count;
  // LCS table is small (≈150 lines) so O(n·m) is fine.
  NSMutableData *buf = [NSMutableData dataWithLength:(n + 1) * (m + 1) * sizeof(int)];
  int *L = buf.mutableBytes;
  for (NSInteger i = n - 1; i >= 0; i--)
    for (NSInteger j = m - 1; j >= 0; j--)
      L[i * (m + 1) + j] = [a[i] isEqualToString:b[j]] ? L[(i + 1) * (m + 1) + j + 1] + 1 : MAX(L[(i + 1) * (m + 1) + j], L[i * (m + 1) + j + 1]);
  NSMutableAttributedString *out = [NSMutableAttributedString new];
  UIFont *f = [LBTheme mono:12 weight:UIFontWeightRegular];
  void (^add)(NSString *, UIColor *, UIColor *) = ^(NSString *s, UIColor *fg, UIColor *bg) {
    NSMutableDictionary *attrs = [@{ NSFontAttributeName : f, NSForegroundColorAttributeName : fg } mutableCopy];
    if (bg) attrs[NSBackgroundColorAttributeName] = bg;
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:[s stringByAppendingString:@"\n"] attributes:attrs]];
  };
  NSInteger i = 0, j = 0, lastShown = -10;
  while (i < n || j < m) {
    if (i < n && j < m && [a[i] isEqualToString:b[j]]) { i++; j++; continue; }
    if (lastShown < i - 1 && out.length) add(@"⋯", LBTheme.muted, nil);
    if (j < m && (i >= n || L[i * (m + 1) + j + 1] >= L[(i + 1) * (m + 1) + j])) { add([@"+ " stringByAppendingString:b[j]], UIColor.systemGreenColor, [UIColor.systemGreenColor colorWithAlphaComponent:0.10]); j++; }
    else { add([@"− " stringByAppendingString:a[i]], UIColor.systemRedColor, [UIColor.systemRedColor colorWithAlphaComponent:0.10]); i++; }
    lastShown = i;
  }
  return out;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = LBTheme.paper;
  self.title = @"确认提交";
  self.navigationItem.subtitle = [NSString stringWithFormat:@"%@ · main · .env", LBStore.repo];
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
  UITextView *diff = [UITextView new];
  diff.editable = NO;
  diff.backgroundColor = UIColor.clearColor;
  diff.attributedText = [self diff];
  diff.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
  diff.translatesAutoresizingMaskIntoConstraints = NO;
  UIVisualEffectView *g = [LBTheme glassWithTint:[LBTheme.surface colorWithAlphaComponent:0.4] interactive:NO];
  g.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:22]];
  [g.contentView addSubview:diff];
  _message = [UITextField new];
  _message.text = @"chore: 通过站长 App 更新站点配置";
  _message.font = [UIFont systemFontOfSize:15];
  _message.borderStyle = UITextBorderStyleRoundedRect;
  _message.clearButtonMode = UITextFieldViewModeWhileEditing;
  UILabel *note = [UILabel new];
  note.text = @"提交到 main 后 EdgeOne 会自动重新构建，通常 1～3 分钟上线，可在仪表盘查看进度。";
  note.font = [UIFont systemFontOfSize:12];
  note.textColor = LBTheme.muted;
  note.numberOfLines = 0;
  UIButtonConfiguration *bc = [UIButtonConfiguration prominentGlassButtonConfiguration];
  bc.title = @"提交并部署";
  bc.image = [UIImage systemImageNamed:@"arrow.up.circle.fill"];
  bc.imagePadding = 8;
  bc.baseBackgroundColor = LBTheme.accent;
  bc.contentInsets = NSDirectionalEdgeInsetsMake(14, 20, 14, 20);
  __weak typeof(self) weakSelf = self;
  _commit = [UIButton buttonWithConfiguration:bc primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [weakSelf commit]; }]];
  _status = [UILabel new];
  _status.font = [LBTheme rounded:13 weight:UIFontWeightSemibold];
  _status.numberOfLines = 0;
  _status.textAlignment = NSTextAlignmentCenter;
  UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[ g, _message, note, _commit, _status ]];
  st.axis = UILayoutConstraintAxisVertical;
  st.spacing = 12;
  st.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:st];
  [NSLayoutConstraint activateConstraints:@[
    [diff.topAnchor constraintEqualToAnchor:g.contentView.topAnchor], [diff.bottomAnchor constraintEqualToAnchor:g.contentView.bottomAnchor],
    [diff.leadingAnchor constraintEqualToAnchor:g.contentView.leadingAnchor], [diff.trailingAnchor constraintEqualToAnchor:g.contentView.trailingAnchor],
    [st.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
    [st.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-12],
    [st.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
    [st.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
  ]];
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)commit {
  if (![_repo isEqualToString:LBStore.repo]) {
    _status.text = @"仓库已切换，请返回并重新加载配置";
    _status.textColor = UIColor.systemRedColor;
    return;
  }
  self.modalInPresentation = YES;
  self.navigationItem.leftBarButtonItem.enabled = NO;
  NSString *msg = [_message.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!msg.length) msg = @"chore: 通过站长 App 更新站点配置";
  _commit.enabled = NO;
  UIButtonConfiguration *c = _commit.configuration;
  c.showsActivityIndicator = YES;
  _commit.configuration = c;
  _status.text = @"提交中…";
  _status.textColor = LBTheme.ink;
  [LBGitHub.shared putFile:@".env" text:_edited sha:_sha message:msg done:^(NSString *commit, NSError *e) {
    self.modalInPresentation = NO;
    self.navigationItem.leftBarButtonItem.enabled = YES;
    UIButtonConfiguration *c2 = self->_commit.configuration;
    c2.showsActivityIndicator = NO;
    self->_commit.configuration = c2;
    if (e) {
      self->_commit.enabled = YES;
      self->_status.text = [@"✕ " stringByAppendingString:e.localizedDescription];
      self->_status.textColor = UIColor.systemRedColor;
      [[UINotificationFeedbackGenerator feedbackGeneratorForView:self.view] notificationOccurred:UINotificationFeedbackTypeError];
      return;
    }
    [[UINotificationFeedbackGenerator feedbackGeneratorForView:self.view] notificationOccurred:UINotificationFeedbackTypeSuccess];
    if (self->_done) self->_done(commit);
    [self dismissViewControllerAnimated:YES completion:nil];
  }];
}
@end

#pragma mark - Config screen
@interface LBSiteConfigViewController () <UITableViewDataSource, UITableViewDelegate>
// Details are projections of the root draft, never independent editors/files.
- (instancetype)initWithOwner:(LBSiteConfigViewController *)owner selectedSection:(NSDictionary *)section;
- (LBEnvFile *)file;
- (void)rebuild;
@end

@implementation LBSiteConfigViewController {
  UITableView *_table;
  LBEnvFile *_file; // root only; details always resolve through -file
  __weak LBSiteConfigViewController *_owner;
  __weak LBSiteConfigViewController *_activeDetail;
  NSDictionary *_selectedSection;
  NSString *_baseText, *_baseSha, *_baseRepo;
  NSArray<NSDictionary *> *_sections;
  NSDictionary *_renderKey;
  UIBarButtonItem *_review, *_revert;
  UIView *_navHeaderView;
  UILabel *_navTitleLabel;
  UIStackView *_navSubtitleStack;
  UIImageView *_navSyncIcon;
  UILabel *_navSubtitleLabel;
}
- (instancetype)initWithOwner:(LBSiteConfigViewController *)owner selectedSection:(NSDictionary *)section {
  if ((self = [super init])) { _owner = owner; _selectedSection = section; }
  return self;
}
- (LBEnvFile *)file { return _selectedSection ? [_owner file] : _file; }
- (NSString *)baseline { return _selectedSection ? [_owner baseline] : _baseText; }
- (BOOL)hasActiveEditor {
  return self.presentedViewController != nil || _activeDetail.presentedViewController != nil;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = _selectedSection ? _selectedSection[@"title"] : @"站点配置";

  // Header Title View (Consistent typography with Posts, Memos, Dashboard, Inbox)
  _navHeaderView = [UIView new];
  _navTitleLabel = [UILabel new];
  _navTitleLabel.text = _selectedSection ? _selectedSection[@"title"] : @"站点配置";
  _navTitleLabel.font = [LBTheme rounded:18 weight:UIFontWeightBold];
  _navTitleLabel.textColor = LBTheme.ink;

  _navSyncIcon = [UIImageView new];
  _navSyncIcon.contentMode = UIViewContentModeScaleAspectFit;
  _navSyncIcon.tintColor = LBTheme.muted;
  _navSyncIcon.image = [UIImage systemImageNamed:_selectedSection ? @"folder" : @"slider.horizontal.3"];
  [_navSyncIcon.widthAnchor constraintEqualToConstant:12].active = YES;
  [_navSyncIcon.heightAnchor constraintEqualToConstant:12].active = YES;

  _navSubtitleLabel = [UILabel new];
  _navSubtitleLabel.font = [LBTheme rounded:12 weight:UIFontWeightMedium];
  _navSubtitleLabel.textColor = LBTheme.muted;
  _navSubtitleLabel.text = LBStore.repo ?: @"minlonghuo-lab/longBlog";

  _navSubtitleStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _navSyncIcon, _navSubtitleLabel ]];
  _navSubtitleStack.axis = UILayoutConstraintAxisHorizontal;
  _navSubtitleStack.spacing = 4;
  _navSubtitleStack.alignment = UIStackViewAlignmentCenter;

  UIStackView *navStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _navTitleLabel, _navSubtitleStack ]];
  navStack.axis = UILayoutConstraintAxisVertical;
  navStack.spacing = 2;
  navStack.alignment = UIStackViewAlignmentLeading;
  navStack.translatesAutoresizingMaskIntoConstraints = NO;
  [_navHeaderView addSubview:navStack];
  [NSLayoutConstraint activateConstraints:@[
    [navStack.topAnchor constraintEqualToAnchor:_navHeaderView.topAnchor],
    [navStack.bottomAnchor constraintEqualToAnchor:_navHeaderView.bottomAnchor],
    [navStack.leadingAnchor constraintEqualToAnchor:_navHeaderView.leadingAnchor],
    [navStack.trailingAnchor constraintEqualToAnchor:_navHeaderView.trailingAnchor]
  ]];
  self.navigationItem.titleView = _navHeaderView;

  _table = LBGlassTable(self, self);
  _table.showsVerticalScrollIndicator = NO;
  _table.showsHorizontalScrollIndicator = NO;
  _table.estimatedRowHeight = _selectedSection ? 90 : 100;
  // Titles live in the native inline navigation bar, not repeated table headers.
  _table.sectionHeaderHeight = 0;
  _table.sectionFooterHeight = 0;
  UIRefreshControl *rc = [UIRefreshControl new];
  [rc addTarget:self action:@selector(pull:) forControlEvents:UIControlEventValueChanged];
  _table.refreshControl = rc;
  if (_selectedSection) { [self rebuild]; return; } // root alone observes/syncs/reviews
  _review = [[UIBarButtonItem alloc] initWithTitle:@"保存预览" style:UIBarButtonItemStyleProminent target:self action:@selector(review)];
  _revert = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.uturn.backward"] style:UIBarButtonItemStylePlain
                                            target:self action:@selector(revert)];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(dataChanged) name:LBSiteDataDidChange object:nil];
  [self dataChanged];
  if (!LBSiteData.shared.envText && LBGitHub.shared.configured) [LBSiteData.shared refreshEnv:nil];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; [self dataChanged]; }
- (BOOL)dirty {
  if (_selectedSection) return _owner.dirty;
  return _file && _baseText && ![[_file serialize] isEqualToString:_baseText];
}
- (void)dataChanged {
  if (_selectedSection) { [_owner dataChanged]; [self rebuild]; return; }
  LBSiteData *d = LBSiteData.shared;
  if (_baseRepo && ![_baseRepo isEqualToString:LBStore.repo]) {
    // Configs belong to a repository. Never carry an old draft into a new repo.
    _file = nil; _baseText = nil; _baseSha = nil; _baseRepo = nil;
  }
  // Never replace local unsaved edits with a background refresh; after a commit,
  // adopt the new blob sha once the re-read text matches what we committed.
  if (d.envText && d.envSha && ![self hasActiveEditor] && (!self.dirty || !_file || (!_baseSha && [d.envText isEqualToString:_baseText]))) {
    if (![d.envText isEqualToString:_baseText] || ![d.envSha isEqualToString:_baseSha ?: @""] || !_file) {
      BOOL keepEdits = _file && !_baseSha && [d.envText isEqualToString:_baseText];
      _baseText = d.envText;
      _baseSha = d.envSha;
      _baseRepo = LBStore.repo;
      if (!keepEdits) _file = [LBEnvFile parse:_baseText];
    }
  }
  [self rebuild];
}
- (void)rebuild {
  if (_selectedSection) {
    // Re-resolve the section after every edit/refresh: friend insertion/removal
    // can change the parser's section objects. Never cache a child LBEnvFile.
    NSDictionary *current = nil;
    for (NSDictionary *section in [[self file] sections]) {
      BOOL match = [_selectedSection[@"friends"] boolValue] ? [section[@"friends"] boolValue]
          : [section[@"title"] isEqualToString:_selectedSection[@"title"]];
      if (match) { current = section; break; }
    }
    _sections = current ? @[ current ] : @[];
    BOOL dirty = self.dirty;
    self.navigationItem.subtitle = nil;
    _navSubtitleLabel.text = dirty ? @"有未提交修改" : (LBStore.repo ?: @"minlonghuo-lab/longBlog");
    _navSyncIcon.tintColor = dirty ? UIColor.systemOrangeColor : LBTheme.muted;
    if (dirty) {
      UIBarButtonItem *rev = [[UIBarButtonItem alloc] initWithTitle:@"保存预览" style:UIBarButtonItemStyleProminent target:self action:@selector(subReview)];
      UIBarButtonItem *undo = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.uturn.backward"] style:UIBarButtonItemStylePlain target:self action:@selector(subRevert)];
      self.navigationItem.rightBarButtonItems = @[ rev, undo ];
    } else {
      self.navigationItem.rightBarButtonItems = @[];
    }
    [_table reloadData];
    return;
  }
  LBSiteData *data = LBSiteData.shared;
  NSDictionary *key = @{ @"text": [_file serialize] ?: @"", @"base": _baseText ?: @"",
      @"loaded": @(_file != nil), @"configured": @(LBGitHub.shared.configured),
      @"repo": LBStore.repo ?: @"", @"error": data.errors[@"env"].localizedDescription ?: @"" };
  if ([_renderKey isEqual:key]) return; // other site datasets cannot shake header geometry
  _renderKey = key;
  _sections = _file ? [_file sections] : @[];
  BOOL dirty = self.dirty;
  self.navigationItem.rightBarButtonItems = dirty ? @[ _review, _revert ] : @[];
  NSUInteger changed = 0;
  if (dirty) {
    NSDictionary *a = [[LBEnvFile parse:_baseText] values], *b = [_file values];
    NSMutableSet *keys = [NSMutableSet setWithArray:a.allKeys];
    [keys addObjectsFromArray:b.allKeys];
    for (NSString *k in keys) if (![a[k] isEqual:b[k]]) changed++;
  }
  self.navigationItem.subtitle = nil;
  _navSubtitleLabel.text = dirty ? [NSString stringWithFormat:@"%lu 项未提交修改", (unsigned long)changed] : (LBStore.repo ?: @"minlonghuo-lab/longBlog");
  _navSyncIcon.tintColor = dirty ? UIColor.systemOrangeColor : LBTheme.muted;
  LBSiteData *d = LBSiteData.shared;
  __weak typeof(self) w = self;
  if (!LBGitHub.shared.configured)
    _table.backgroundView = LBNotice(@"key.horizontal", @"需要 GitHub 令牌", @"站点配置保存在仓库的 .env 中，需要具有 contents 写权限的令牌。", @"去设置", ^{ LBPresentSettings(w); });
  else if (!_file && d.errors[@"env"])
    _table.backgroundView = LBNotice(@"exclamationmark.triangle", @"加载失败", d.errors[@"env"].localizedDescription, nil, nil);
  else _table.backgroundView = nil;
  [_table reloadData];
  [_activeDetail rebuild];
}
- (void)subReview {
  if (_selectedSection && _owner) [_owner review];
  else [self review];
}
- (void)subRevert {
  if (_selectedSection && _owner) [_owner revert];
  else [self revert];
}
- (void)draftChanged {
  if (_selectedSection) { [_owner rebuild]; [self rebuild]; }
  else [self rebuild];
}
- (void)pull:(UIRefreshControl *)rc {
  if (_selectedSection) { [_owner pull:rc]; return; }
  if (self.dirty) { [rc endRefreshing]; return; } // keep edits; use revert first
  [LBSiteData.shared refreshEnv:^{ [rc endRefreshing]; }];
}
- (void)revert {
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"放弃所有未提交的修改？" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
  [a addAction:[UIAlertAction actionWithTitle:@"放弃修改" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
    self->_file = [LBEnvFile parse:self->_baseText];
    [self rebuild];
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  a.popoverPresentationController.barButtonItem = _revert;
  [self presentViewController:a animated:YES completion:nil];
}
- (void)review {
  if (![_baseRepo isEqualToString:LBStore.repo]) { [self dataChanged]; return; }
  if (!_baseSha) {
    [LBSiteData.shared refreshEnv:nil];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"正在同步最新版本" message:@"刚提交过的配置需要先从 GitHub 重新读取，请稍候再提交。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
    return;
  }
  NSArray *errs = [_file validate];
  if (errs.count) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"有配置项会导致构建失败"
        message:[errs componentsJoinedByString:@"\n"] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"返回修改" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
    return;
  }
  NSString *edited = [_file serialize];
  __weak typeof(self) w = self;
  LBReviewViewController *r = [[LBReviewViewController alloc] initWithOriginal:_baseText edited:edited sha:_baseSha done:^(NSString *commit) {
    typeof(self) s = w;
    if (!s) return;
    s->_baseText = edited;
    s->_baseSha = nil;
    [LBSiteData.shared didCommitEnv:edited commit:commit];
    [s rebuild];
  }];
  UINavigationController *n = [[LBNavigationController alloc] initWithRootViewController:r];
  [self presentViewController:n animated:YES completion:nil];
}

#pragma mark Table: root category cards; detail fields use the shared root file.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return _selectedSection ? _sections.count : 1; }
- (BOOL)isFriends:(NSInteger)s {
  return _selectedSection && s >= 0 && s < (NSInteger)_sections.count && [_sections[s][@"friends"] boolValue];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
  if (!_selectedSection) return _sections.count;
  NSInteger n = [_sections[s][@"keys"] count];
  if ([self isFriends:s]) n += [[self file] friendIndexes].count + 1; // + "add friend"
  return n;
}
- (NSString *)changedMark:(NSString *)key {
  NSString *before = [[LBEnvFile parse:[self baseline]] valueFor:key];
  NSString *after = [[self file] valueFor:key];
  return [before isEqualToString:after ?: @""] || (!before && !after.length) ? nil : @"已修改";
}
- (UITableViewCell *)categoryCell:(UITableView *)t atIndexPath:(NSIndexPath *)ip {
  NSDictionary *section = _sections[ip.row];
  NSArray *keys = section[@"keys"];
  BOOL friends = [section[@"friends"] boolValue];
  LBCardCell *c = [t dequeueReusableCellWithIdentifier:@"card" forIndexPath:ip];
  c.titleLabel.text = section[@"title"];
  c.titleLabel.font = [LBTheme rounded:16 weight:UIFontWeightSemibold];
  NSUInteger count = keys.count;
  NSMutableArray *labels = [NSMutableArray array];
  for (NSDictionary *item in keys) {
    if (labels.count == 3) break;
    [labels addObject:[LBEnvFile labelFor:item[@"key"]]];
  }
  if (friends) count += [[self file] friendIndexes].count;
  c.metaLabel.text = friends ? [NSString stringWithFormat:@"%lu 项设置 · %lu 位友链", (unsigned long)keys.count, (unsigned long)[[self file] friendIndexes].count]
      : [NSString stringWithFormat:@"%lu 项设置", (unsigned long)count];
  c.bodyLabel.text = labels.count ? [labels componentsJoinedByString:@" · "] : (friends ? @"友链展示与管理" : nil);
  c.bodyLabel.numberOfLines = 2;
  c.bodyLabel.font = [UIFont systemFontOfSize:13];
  c.bodyLabel.textColor = LBTheme.muted;
  UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
  arrow.tintColor = LBTheme.muted;
  arrow.contentMode = UIViewContentModeScaleAspectFit;
  [arrow.widthAnchor constraintEqualToConstant:14].active = YES;
  [arrow.heightAnchor constraintEqualToConstant:20].active = YES;
  [arrow setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
  [arrow setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
  arrow.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold];
  c.trailingView = arrow;
  c.accessibilityTraits |= UIAccessibilityTraitButton;
  [c finishConfiguration];
  return c;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  if (!_selectedSection) return [self categoryCell:t atIndexPath:ip];
  NSArray *keys = _sections[ip.section][@"keys"];
  LBCardCell *c = [t dequeueReusableCellWithIdentifier:@"card" forIndexPath:ip];
  c.bodyLabel.numberOfLines = 2;
  if (ip.row < (NSInteger)keys.count) {
    NSString *key = keys[ip.row][@"key"];
    NSString *v = [[self file] valueFor:key] ?: @"";
    c.titleLabel.text = [LBEnvFile labelFor:key];
    c.titleLabel.font = [LBTheme rounded:15 weight:UIFontWeightSemibold];
    c.metaLabel.text = key;
    c.metaLabel.font = [LBTheme mono:10 weight:UIFontWeightRegular];
    if ([LBEnvFile isBoolean:key]) {
      UISwitch *sw = [UISwitch new];
      sw.on = ![[v lowercaseString] isEqualToString:@"false"];
      sw.onTintColor = LBTheme.accent;
      __weak typeof(self) w = self;
      [sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
        UISwitch *sender = (UISwitch *)a.sender;
        [[w file] updateValue:sender.on ? @"true" : @"false" forKey:key];
        [w draftChanged];
      }] forControlEvents:UIControlEventValueChanged];
      c.trailingView = sw;
      c.bodyLabel.text = nil;
    } else {
      c.bodyLabel.text = v.length ? v : @"（空，不显示）";
      c.bodyLabel.textColor = v.length ? LBTheme.ink : LBTheme.muted;
    }
    NSString *mark = [self changedMark:key];
    if (mark) { [c setCardTint:LBTheme.accentSoft]; [c.extraStack addArrangedSubview:LBChip(mark, LBTheme.accent)]; [c.extraStack addArrangedSubview:[UIView new]]; }
    [c finishConfiguration];
    return c;
  }
  NSArray *friends = [[self file] friendIndexes];
  NSInteger fi = ip.row - keys.count;
  if (fi >= (NSInteger)friends.count) {
    c.titleLabel.text = @"＋ 添加友链";
    c.titleLabel.textColor = LBTheme.accent;
    c.metaLabel.text = @"新友链默认不展示，填好名称和链接后再打开“启用”";
    c.metaLabel.font = [UIFont systemFontOfSize:12];
    c.bodyLabel.text = nil;
    [c finishConfiguration];
    return c;
  }
  NSNumber *idx = friends[fi];
  NSString *p = [NSString stringWithFormat:@"PUBLIC_FRIEND_%@_", idx];
  NSString *name = [[self file] valueFor:[p stringByAppendingString:@"NAME"]];
  NSString *en = [[self file] valueFor:[p stringByAppendingString:@"ENABLED"]] ?: @"";
  BOOL enabled = ![[en lowercaseString] isEqualToString:@"false"];
  c.titleLabel.text = name.length ? name : [NSString stringWithFormat:@"友链 #%@（未命名）", idx];
  c.titleLabel.textColor = enabled ? LBTheme.ink : LBTheme.muted;
  c.metaLabel.text = [[self file] valueFor:[p stringByAppendingString:@"URL"]];
  c.metaLabel.font = [LBTheme mono:11 weight:UIFontWeightRegular];
  c.bodyLabel.text = [[self file] valueFor:[p stringByAppendingString:@"DESCRIPTION"]];
  c.bodyLabel.textColor = LBTheme.muted;
  [c.extraStack addArrangedSubview:LBChip([NSString stringWithFormat:@"#%@", idx], LBTheme.muted)];
  [c.extraStack addArrangedSubview:LBChip(enabled ? @"展示中" : @"已隐藏", enabled ? UIColor.systemGreenColor : LBTheme.muted)];
  BOOL changed = NO;
  for (NSString *f in @[ @"NAME", @"URL", @"DESCRIPTION", @"AVATAR", @"ENABLED" ]) if ([self changedMark:[p stringByAppendingString:f]]) changed = YES;
  if (changed) { [c setCardTint:LBTheme.accentSoft]; [c.extraStack addArrangedSubview:LBChip(@"已修改", LBTheme.accent)]; }
  [c.extraStack addArrangedSubview:[UIView new]];
  NSString *avatar = [[self file] valueFor:[p stringByAppendingString:@"AVATAR"]];
  NSString *friendURL = [[self file] valueFor:[p stringByAppendingString:@"URL"]];
  UIStackView *trailing = [UIStackView new];
  trailing.axis = UILayoutConstraintAxisHorizontal;
  trailing.spacing = 8;
  trailing.alignment = UIStackViewAlignmentCenter;

  UIImageView *iv = [UIImageView new];
  iv.contentMode = UIViewContentModeScaleAspectFill;
  iv.clipsToBounds = YES;
  iv.layer.cornerRadius = 14;
  iv.layer.cornerCurve = kCACornerCurveContinuous;
  iv.layer.borderWidth = 0.5;
  iv.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
  iv.backgroundColor = LBTheme.accentSoft;
  [iv.widthAnchor constraintEqualToConstant:28].active = YES;
  [iv.heightAnchor constraintEqualToConstant:28].active = YES;
  if (avatar.length) {
    NSURL *u = [avatar hasPrefix:@"/"] ? [NSURL URLWithString:[LBStore.siteURL stringByAppendingString:avatar]] : [NSURL URLWithString:avatar];
    if (![avatar hasSuffix:@".svg"]) [LBHTTP image:u done:^(UIImage *img) { iv.image = img; }];
  } else {
    UILabel *letter = [UILabel new];
    letter.text = name.length ? [name substringToIndex:1].uppercaseString : @"?";
    letter.font = [LBTheme rounded:13 weight:UIFontWeightBold];
    letter.textColor = LBTheme.accent;
    letter.textAlignment = NSTextAlignmentCenter;
    letter.frame = CGRectMake(0, 0, 28, 28);
    [iv addSubview:letter];
  }
  [trailing addArrangedSubview:iv];

  if (friendURL.length) {
    UIButtonConfiguration *vc = [UIButtonConfiguration glassButtonConfiguration];
    vc.image = [UIImage systemImageNamed:@"arrow.up.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold]];
    vc.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    __weak typeof(self) weakOwner = self;
    UIButton *visit = [UIButton buttonWithConfiguration:vc primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
      NSURL *link = [NSURL URLWithString:friendURL];
      if (link) LBOpenURL(weakOwner, link);
    }]];
    [visit.widthAnchor constraintEqualToConstant:28].active = YES;
    [visit.heightAnchor constraintEqualToConstant:28].active = YES;
    visit.accessibilityLabel = @"访问友链网站";
    [trailing addArrangedSubview:visit];
  }
  c.trailingView = trailing;
  [c finishConfiguration];
  return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
  [t deselectRowAtIndexPath:ip animated:YES];
  if (!_selectedSection) {
    LBSiteConfigViewController *detail = [[LBSiteConfigViewController alloc] initWithOwner:self selectedSection:_sections[ip.row]];
    _activeDetail = detail;
    [self.navigationController pushViewController:detail animated:YES];
    return;
  }
  NSArray *keys = _sections[ip.section][@"keys"];
  if (ip.row < (NSInteger)keys.count) {
    NSString *key = keys[ip.row][@"key"];
    if ([LBEnvFile isBoolean:key]) return;
    [self edit:key help:keys[ip.row][@"help"]];
    return;
  }
  if (![self isFriends:ip.section]) return;
  NSArray *friends = [[self file] friendIndexes];
  NSInteger fi = ip.row - keys.count;
  if (fi >= (NSInteger)friends.count) {
    NSInteger n = [[self file] addFriend];
    [self draftChanged];
    [self friendMenu:@(n) from:t];
    return;
  }
  [self friendMenu:friends[fi] from:[t cellForRowAtIndexPath:ip]];
}
- (void)edit:(NSString *)key help:(NSString *)help {
  if (!_selectedSection || ![self file]) return;
  __weak typeof(self) w = self;
  LBValueEditor *e = [[LBValueEditor alloc] initWithFile:[self file] key:key help:help done:^{ [w draftChanged]; }];
  UINavigationController *n = [[LBNavigationController alloc] initWithRootViewController:e];
  n.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent ];
  n.sheetPresentationController.prefersGrabberVisible = YES;
  [self presentViewController:n animated:YES completion:nil];
}
- (void)friendMenu:(NSNumber *)idx from:(UIView *)cell {
  if (!_selectedSection || ![self isFriends:0]) return;
  NSString *p = [NSString stringWithFormat:@"PUBLIC_FRIEND_%@_", idx];
  NSString *name = [[self file] valueFor:[p stringByAppendingString:@"NAME"]];
  UIAlertController *a = [UIAlertController alertControllerWithTitle:name.length ? name : [NSString stringWithFormat:@"友链 #%@", idx]
                                                             message:nil preferredStyle:UIAlertControllerStyleActionSheet];
  for (NSString *f in @[ @"NAME", @"URL", @"DESCRIPTION", @"AVATAR" ]) {
    NSString *key = [p stringByAppendingString:f];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"编辑%@", [LBEnvFile labelFor:key]] style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { [self edit:key help:nil]; }]];
  }
  NSString *enKey = [p stringByAppendingString:@"ENABLED"];
  BOOL enabled = ![[[[self file] valueFor:enKey] ?: @"" lowercaseString] isEqualToString:@"false"];
  [a addAction:[UIAlertAction actionWithTitle:enabled ? @"在友链页隐藏" : @"在友链页展示" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
    [[self file] updateValue:enabled ? @"false" : @"true" forKey:enKey];
    [self draftChanged];
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"删除这个友链" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
    [[self file] removeFriend:idx.integerValue];
    [self draftChanged];
  }]];
  [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  a.popoverPresentationController.sourceView = cell;
  [self presentViewController:a animated:YES completion:nil];
}
@end

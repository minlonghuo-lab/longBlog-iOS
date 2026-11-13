#import "LB.h"
#import "LBPostReader.h"
#import "LBMdStore.h"
#import "LBPostEditor.h"
#import "LBNavigationController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - Articles Review
@interface LBArticlesReviewViewController : UIViewController
- (instancetype)initWithStagedArticles:(NSArray<NSDictionary *> *)staged done:(void (^)(void))done;
@end

@implementation LBArticlesReviewViewController {
  NSArray<NSDictionary *> *_staged;
  void (^_done)(void);
  UITextField *_message;
  UIButton *_commit;
  UILabel *_status;
}
- (instancetype)initWithStagedArticles:(NSArray<NSDictionary *> *)staged done:(void (^)(void))done {
  if ((self = [super init])) {
    _staged = [staged copy] ?: @[];
    _done = [done copy];
  }
  return self;
}

- (NSAttributedString *)diff {
  NSMutableAttributedString *out = [NSMutableAttributedString new];
  UIFont *font = [LBTheme mono:13 weight:UIFontWeightRegular];
  UIFont *bold = [LBTheme rounded:13 weight:UIFontWeightBold];
  for (NSDictionary *item in _staged) {
    NSString *action = item[@"action"];
    NSString *title = item[@"title"] ?: item[@"id"];
    UIColor *fg = [action isEqualToString:@"unpublish"] ? UIColor.systemRedColor
        : ([action isEqualToString:@"publish"] ? UIColor.systemGreenColor : LBTheme.accent);
    NSString *tag = [action isEqualToString:@"unpublish"] ? @"[下架]"
        : ([action isEqualToString:@"publish"] ? @"[发布]" : @"[更新]");
    
    NSDictionary *tagAttr = @{ NSFontAttributeName: bold, NSForegroundColorAttributeName: fg };
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:[tag stringByAppendingString:@" "] attributes:tagAttr]];
    NSDictionary *titleAttr = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: LBTheme.ink };
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:[title stringByAppendingString:@"\n"] attributes:titleAttr]];
    
    NSString *summary = item[@"summary"];
    if (summary.length) {
      NSDictionary *sumAttr = @{ NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2], NSForegroundColorAttributeName: LBTheme.muted };
      [out appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"   %@\n", summary] attributes:sumAttr]];
    }
  }
  return out;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = LBTheme.paper;
  self.title = @"确认提交文章";
  self.navigationItem.subtitle = [NSString stringWithFormat:@"%@ · main · %lu 篇变更", LBStore.repo ?: @"longBlog", (unsigned long)_staged.count];
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
  _message.text = [NSString stringWithFormat:@"content: 更新 %lu 篇文章发布与下架状态", (unsigned long)_staged.count];
  _message.font = [UIFont systemFontOfSize:15];
  _message.borderStyle = UITextBorderStyleRoundedRect;
  _message.clearButtonMode = UITextFieldViewModeWhileEditing;

  UILabel *note = [UILabel new];
  note.text = @"提交到 main 后 EdgeOne 会自动重新构建并部署，通常 1～3 分钟上线全站。";
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
  self.modalInPresentation = YES;
  self.navigationItem.leftBarButtonItem.enabled = NO;
  NSString *msg = [_message.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!msg.length) msg = [NSString stringWithFormat:@"content: 更新 %lu 篇文章发布与下架状态", (unsigned long)_staged.count];
  _commit.enabled = NO;
  UIButtonConfiguration *c = _commit.configuration;
  c.showsActivityIndicator = YES;
  _commit.configuration = c;
  _status.text = @"提交中…";
  _status.textColor = LBTheme.ink;
  [LBMdStore.shared commitStagedArticles:_staged message:msg done:^(NSError *e) {
    self.modalInPresentation = NO;
    self.navigationItem.leftBarButtonItem.enabled = YES;
    UIButtonConfiguration *c2 = self->_commit.configuration;
    c2.showsActivityIndicator = NO;
    self->_commit.configuration = c2;
    if (e) {
      self->_commit.enabled = YES;
      self->_status.text = [@"✕ " stringByAppendingString:e.localizedDescription ?: @"提交失败"];
      self->_status.textColor = UIColor.systemRedColor;
      return;
    }
    if (self->_done) self->_done();
    [self dismissViewControllerAnimated:YES completion:nil];
  }];
}
@end

#pragma mark - Posts list
static NSString *LBArticleTimestamp(long long milliseconds) {
  if (milliseconds <= 0) return @"时间未知";
  static NSDateFormatter *formatter;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    formatter.dateFormat = @"yyyy-MM-dd";
  });
  formatter.timeZone = NSTimeZone.localTimeZone;
  return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:milliseconds / 1000.0]];
}
@interface LBPostsViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UISearchControllerDelegate, UIDocumentPickerDelegate>
@end

@implementation LBPostsViewController {
  UITableView *_table;
  UIView *_notice;
  NSString *_query;
  NSArray<NSDictionary *> *_items;
  NSArray<NSDictionary *> *_articles;
  NSString *_filterMode; // @"ALL", @"PUBLISHED", @"DRAFT"
  NSDictionary *_renderKey;
  BOOL _searchDismissing;
  BOOL _visible;
  BOOL _syncingArticles;
  NSUUID *_articleSyncOperation;
  NSString *_articleSyncMessage;
  NSMutableDictionary<NSString *, NSString *> *_transitioningArticles;
  BOOL _articlesDirty;
  BOOL _articleLoadScheduled;
  NSUInteger _articleLoadGeneration;
  NSUUID *_articleOperation;
  NSString *_articleOperationMessage;
  UIView *_navHeaderView;
  UILabel *_navTitleLabel;
  UIStackView *_navSubtitleStack;
  UIImageView *_navSyncIcon;
  NSString *_navSyncSymbol;
  UILabel *_navSubtitleLabel;
  NSArray<NSDictionary *> *_stagedArticles;
  NSMutableDictionary<NSString *, NSString *> *_stagedDict;
  UIBarButtonItem *_composeItem;
  UIBarButtonItem *_filterItem;
  UIBarButtonItem *_reviewItem;
  UIBarButtonItem *_revertItem;
  NSArray *_rowSignatures; // per visible row: item + badge state, for in-place updates
  BOOL _swipeActive;       // a row's swipe actions are open or closing
  BOOL _pendingReload;     // data arrived during a swipe; apply once it ends
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"文章";
  _filterMode = @"ALL";
  _table = LBGlassTable(self, self);
  UIRefreshControl *rc = [UIRefreshControl new];
  [rc addTarget:self action:@selector(pull:) forControlEvents:UIControlEventValueChanged];
  _table.refreshControl = rc;

  // Header Title View with Animated SF Symbol Micro-icon
  _navHeaderView = [UIView new];
  _navTitleLabel = [UILabel new];
  _navTitleLabel.text = @"文章";
  _navTitleLabel.font = [LBTheme rounded:18 weight:UIFontWeightBold];
  _navTitleLabel.textColor = LBTheme.ink;

  _navSyncIcon = [UIImageView new];
  _navSyncIcon.contentMode = UIViewContentModeScaleAspectFit;
  _navSyncIcon.tintColor = LBTheme.muted;
  _navSyncIcon.image = [UIImage systemImageNamed:@"folder"];
  [_navSyncIcon.widthAnchor constraintEqualToConstant:12].active = YES;
  [_navSyncIcon.heightAnchor constraintEqualToConstant:12].active = YES;

  _navSubtitleLabel = [UILabel new];
  _navSubtitleLabel.font = [LBTheme rounded:12 weight:UIFontWeightMedium];
  _navSubtitleLabel.textColor = LBTheme.muted;

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

  _composeItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.pencil"] style:UIBarButtonItemStyleProminent target:self action:@selector(composePost)];
  _composeItem.accessibilityLabel = @"新建文章";
  _filterItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease"] menu:[self filterMenu]];
  _reviewItem = [[UIBarButtonItem alloc] initWithTitle:@"保存预览" style:UIBarButtonItemStyleProminent target:self action:@selector(reviewStaged)];
  _revertItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.uturn.backward"] style:UIBarButtonItemStylePlain target:self action:@selector(promptRevertStaged)];
  _revertItem.accessibilityLabel = @"撤销所有未提交操作";
  [self updateRightBarButtons:NO];

  UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
  sc.searchResultsUpdater = self;
  sc.delegate = self;
  sc.hidesNavigationBarDuringPresentation = NO;
  sc.obscuresBackgroundDuringPresentation = NO;
  sc.searchBar.placeholder = @"搜索标题或摘要";
  self.navigationItem.searchController = sc;
  self.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
  self.navigationItem.hidesSearchBarWhenScrolling = NO;
  self.navigationItem.searchBarPlacementAllowsToolbarIntegration = NO;
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(articlesDidChange:) name:LBMdStoreDidChange object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editorDidFinish:) name:LBPostEditorDidFinish object:nil];
  // Site/memos notifications are unrelated to the local article metadata snapshot.
  _transitioningArticles = [NSMutableDictionary dictionary];
  [self loadArticles];
  if (LBGitHub.shared.configured) [self checkRemoteCommitAndSyncIfNeeded:nil];
}

- (UIMenu *)filterMenu {
  __weak typeof(self) weakSelf = self;
  UIAction *all = [UIAction actionWithTitle:@"全部文章" image:[UIImage systemImageNamed:@"doc.richtext"] identifier:nil handler:^(UIAction *a) {
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;
    strongSelf->_filterMode = @"ALL";
    [strongSelf reload];
  }];
  UIAction *pub = [UIAction actionWithTitle:@"仅已发布" image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(UIAction *a) {
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;
    strongSelf->_filterMode = @"PUBLISHED";
    [strongSelf reload];
  }];
  UIAction *draft = [UIAction actionWithTitle:@"草稿箱" image:[UIImage systemImageNamed:@"archivebox"] identifier:nil handler:^(UIAction *a) {
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;
    strongSelf->_filterMode = @"DRAFT";
    [strongSelf reload];
  }];
  UIAction *folder = [UIAction actionWithTitle:@"选择文章目录" image:[UIImage systemImageNamed:@"folder"] identifier:nil handler:^(UIAction *a) {
    [weakSelf chooseFolder];
  }];
  UIAction *forceSync = [UIAction actionWithTitle:@"云端强制覆盖" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath.circle"] identifier:nil handler:^(UIAction *a) {
    [weakSelf promptForceSyncArticles];
  }];
  UIAction *conn = [UIAction actionWithTitle:@"连接与设置" image:[UIImage systemImageNamed:@"gearshape"] identifier:nil handler:^(UIAction *a) {
    LBPresentSettings(weakSelf);
  }];

  return [UIMenu menuWithChildren:@[ all, pub, draft, folder, forceSync, conn ]];
}

- (BOOL)organizeArticleFolder {
  if (_syncingArticles || _articleOperation) { [self updateArticleFeedback]; return NO; }
  NSError *error = nil;
  if (![LBMdStore.shared migrateToArticleFoldersWithError:&error]) {
    [self showArticleError:error ?: [NSError errorWithDomain:@"LBMdStore" code:500 userInfo:@{NSLocalizedDescriptionKey:@"目录整理未完成，旧文件已保留"}]];
    return NO;
  }
  [self loadArticles];
  return YES;
}

- (void)chooseFolder {
  if (_syncingArticles || _articleOperation) { [self updateArticleFeedback]; return; }
  UIDocumentPickerViewController *doc = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
  doc.delegate = self;
  doc.allowsMultipleSelection = NO;
  [self presentViewController:doc animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  if (!urls.count) return;
  NSURL *url = urls.firstObject;
  NSError *err = nil;
  BOOL ok = [LBMdStore.shared setFolderURL:url error:&err];
  if (ok) {
    if (![self organizeArticleFolder]) return;
    [self syncArticles:nil];
  } else {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"绑定目录失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
  }
}

- (void)composePost {
  LBPostEditor *editor = [[LBPostEditor alloc] initWithPost:nil saved:^(NSDictionary *post) {
    [self loadArticles];
  }];
  LBNavigationController *nav = [[LBNavigationController alloc] initWithRootViewController:editor];
  nav.modalPresentationStyle = UIModalPresentationPageSheet;
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)articlesDidChange:(NSNotification *)notification {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self articlesDidChange:notification]; });
    return;
  }
  _articlesDirty = YES;
  if (_syncingArticles || _articleOperation || !_visible || _articleLoadScheduled) return;
  _articleLoadScheduled = YES;
  NSUInteger generation = ++_articleLoadGeneration;
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    typeof(self) self = weakSelf;
    if (!self || generation != self->_articleLoadGeneration) return;
    self->_articleLoadScheduled = NO;
    if (self->_articlesDirty) [self loadArticles];
  });
}

- (void)editorDidFinish:(NSNotification *)notification {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self editorDidFinish:notification]; });
    return;
  }
  _articleSyncMessage = notification.userInfo[@"message"];
  [self updateArticleFeedback];
}

- (void)loadArticles {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self loadArticles]; });
    return;
  }
  _articlesDirty = YES;
  if (_syncingArticles || _articleOperation || (!_visible && _articles)) return;
  NSUInteger generation = ++_articleLoadGeneration;
  _articleLoadScheduled = NO;
  _articlesDirty = NO;
  (void)LBMdStore.shared.articlesFolderURL;
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      NSArray *articles = [LBMdStore.shared listArticles];
      // Staged state needs every file read and hashed: keep it off the main
      // thread, where it used to block the bar-button animation.
      NSArray *staged = [LBMdStore.shared stagedArticlesForArticles:articles] ?: @[];
      dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || generation != self->_articleLoadGeneration) return;
        self->_articles = articles;
        self->_stagedArticles = staged;
        [self reload];
      });
    }
  });
}

- (void)updateArticleFeedback {
  BOOL busy = _syncingArticles || _articleOperation != nil;
  NSString *message = _syncingArticles ? @"正在同步文章与附件…" : (_articleOperationMessage ?: _articleSyncMessage);
  [self updateRightBarButtons:NO];
  // Sync feedback belongs to the navigation header, never a duplicate footer.
  NSString *subText = message.length ? message : (_stagedArticles.count
      ? [NSString stringWithFormat:@"共 %lu 篇 · %lu 篇待提交修改", (unsigned long)_articles.count, (unsigned long)_stagedArticles.count]
      : (_articles.count
         ? [NSString stringWithFormat:@"共 %lu 篇 · %@", (unsigned long)_articles.count, LBMdStore.shared.folderDisplayName]
         : LBMdStore.shared.folderDisplayName));
  self.navigationItem.subtitle = nil;
  if (![_navSubtitleLabel.text isEqualToString:subText]) {
    if (self.isViewLoaded && self.view.window != nil) {
      CATransition *transition = [CATransition animation];
      transition.duration = 0.22;
      transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      transition.type = kCATransitionFade;
      [_navSubtitleLabel.layer addAnimation:transition forKey:@"fadeSubtitle"];
    }
    _navSubtitleLabel.text = subText;
  }

  // Native SF Symbol effects: they survive backgrounding (a CA spin is dropped)
  // and only swap the glyph when the state actually changes.
  NSString *symbol = busy ? @"arrow.triangle.2.circlepath"
      : ([message containsString:@"失败"] ? @"exclamationmark.circle"
      : (message.length ? @"checkmark.circle" : @"folder"));
  _navSyncIcon.tintColor = busy ? LBTheme.accent
      : ([message containsString:@"失败"] ? UIColor.systemRedColor
      : (message.length ? UIColor.systemGreenColor : LBTheme.muted));
  if (![_navSyncSymbol isEqualToString:symbol]) {
    BOOL first = _navSyncSymbol == nil;
    _navSyncSymbol = symbol;
    [_navSyncIcon removeAllSymbolEffects];
    if (first) _navSyncIcon.image = [UIImage systemImageNamed:symbol];
    else [_navSyncIcon setSymbolImage:[UIImage systemImageNamed:symbol] withContentTransition:[NSSymbolReplaceContentTransition replaceDownUpTransition]];
    if (busy) {
      [_navSyncIcon addSymbolEffect:[NSSymbolRotateEffect rotateClockwiseEffect]
          options:[NSSymbolEffectOptions optionsWithRepeatBehavior:[NSSymbolEffectOptionsRepeatBehavior behaviorContinuous]]];
    } else if (!first && message.length) {
      [_navSyncIcon addSymbolEffect:[NSSymbolBounceEffect effect] options:[NSSymbolEffectOptions optionsWithNonRepeating]];
    }
  }
}

- (void)checkRemoteCommitAndSyncIfNeeded:(UIRefreshControl *)refresh {
  if (_syncingArticles || _articleOperation) { [refresh endRefreshing]; return; }
  if (!LBGitHub.shared.configured) {
    [refresh endRefreshing];
    [self updateArticleFeedback];
    return;
  }
  // Local-first: Check if remote main HEAD commit differs before touching disk or tree snapshot.
  // One lightweight GET /commits/main (~200B). If unchanged, skip heavy full sync completely!
  __weak typeof(self) weakSelf = self;
  [LBGitHub.shared headCommit:^(NSDictionary *head, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (!self) return;
      if (error) {
        // Network unavailable or offline: remain local-first gracefully.
        [refresh endRefreshing];
        return;
      }
      NSString *remoteSha = head[@"sha"];
      NSString *localHead = [LBMdStore.shared currentHeadCommit];
      if (remoteSha.length && [remoteSha isEqualToString:localHead]) {
        // Remote main has not changed at all; already up to date!
        [refresh endRefreshing];
        [self updateArticleFeedback];
        return;
      }
      // Remote commit differs (e.g. modified on GitHub directly): trigger genuine sync.
      [self syncArticles:refresh];
    });
  }];
}

- (void)syncArticles:(UIRefreshControl *)refresh {
  if (_syncingArticles) return; // Do not stop an already-running pull indicator.
  if (_articleOperation) { [refresh endRefreshing]; [self updateArticleFeedback]; return; }
  if (!LBGitHub.shared.configured) {
    _articleSyncMessage = @"尚未配置 GitHub，本地文章已保留";
    [refresh endRefreshing];
    [self updateArticleFeedback];
    return;
  }
  NSUUID *operation = NSUUID.UUID;
  _articleSyncOperation = operation;
  _syncingArticles = YES;
  _articleSyncMessage = nil;
  [self updateArticleFeedback];
  __weak typeof(self) weakSelf = self;
  [LBMdStore.shared syncFromGitHub:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (!self || self->_articleSyncOperation != operation) { [refresh endRefreshing]; return; }
      self->_articleSyncOperation = nil;
      self->_syncingArticles = NO;
      self->_articleSyncMessage = error ? [NSString stringWithFormat:@"同步失败：%@ · 本地内容已保留", error.localizedDescription] : @"文章与附件同步完成";
      [self loadArticles]; // One metadata scan for all notifications emitted by this sync.
      [self updateArticleFeedback];
      [refresh endRefreshing];
      [self->_table.refreshControl endRefreshing]; // Also stop a pull begun during auto-sync.
      if (error && self->_visible) [self showArticleError:error];
    });
  }];
}

- (void)promptForceSyncArticles {
  if (_syncingArticles || _articleOperation) { [self updateArticleFeedback]; return; }
  if (!LBGitHub.shared.configured) {
    [self showArticleError:[NSError errorWithDomain:@"LBContent" code:400 userInfo:@{NSLocalizedDescriptionKey:@"尚未配置 GitHub，无法从云端覆盖本地"}]];
    return;
  }
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确定从云端强制覆盖？"
                                                                 message:@"此操作将用 GitHub 远端仓库的 Markdown 正文和附件强制覆盖本地同名文章，本地未提交的修改将被覆盖。"
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  __weak typeof(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"强制覆盖" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
    [weakSelf forceSyncArticles];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)forceSyncArticles {
  if (_syncingArticles || _articleOperation) return;
  NSUUID *operation = NSUUID.UUID;
  _articleSyncOperation = operation;
  _syncingArticles = YES;
  _articleSyncMessage = @"正在云端强制覆盖本地文章…";
  [self updateArticleFeedback];
  __weak typeof(self) weakSelf = self;
  [LBMdStore.shared forceSyncFromGitHub:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (!self || self->_articleSyncOperation != operation) return;
      self->_articleSyncOperation = nil;
      self->_syncingArticles = NO;
      self->_articleSyncMessage = error ? [NSString stringWithFormat:@"覆盖失败：%@ · 本地内容已保留", error.localizedDescription] : @"云端文章覆盖完成";
      [self loadArticles];
      [self updateArticleFeedback];
      if (error && self->_visible) [self showArticleError:error];
    });
  }];
}

- (void)showArticleError:(NSError *)error {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"文章操作未完成" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"保留本地内容" style:UIAlertActionStyleCancel handler:nil]];
  if (LBGitHub.shared.configured && error.code != 401 && error.code != 403) {
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"核验并同步" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
      [weakSelf syncArticles:nil]; // Never blindly repeat a publication mutation.
    }]];
  }
  if (!self.presentedViewController) [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  _visible = YES;
  if (_articlesDirty || !_articles) [self loadArticles]; else [self reload];
  [self updateArticleFeedback];
}
- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  _visible = NO;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)pull:(UIRefreshControl *)rc {
  [self checkRemoteCommitAndSyncIfNeeded:rc];
}
// Inactive updates are UIKit clearing the field during dismissal, not user
// typing. Keep the visible snapshot unchanged until didDismiss, not a timer.
- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
  if (_searchDismissing || !sc.isActive) return;
  _query = [sc.searchBar.text copy] ?: @"";
  [self reload];
}
- (void)willPresentSearchController:(UISearchController *)sc { _searchDismissing = NO; }
- (void)willDismissSearchController:(UISearchController *)sc { _searchDismissing = YES; }
- (void)didDismissSearchController:(UISearchController *)sc {
  _query = @"";
  sc.searchBar.text = @"";
  _searchDismissing = NO;
  [self reload];
}
- (void)updateRightBarButtons:(BOOL)animated {
  BOOL hasStaged = _stagedArticles.count > 0 && LBGitHub.shared.configured;
  BOOL busy = _syncingArticles || _articleOperation != nil;
  _reviewItem.enabled = !busy;
  _revertItem.enabled = !busy;
  _composeItem.enabled = !busy;
  _filterItem.enabled = !busy;
  NSArray<UIBarButtonItem *> *targetItems = hasStaged
      ? @[ _reviewItem, _revertItem, _composeItem, _filterItem ]
      : @[ _composeItem, _filterItem ];
  if ([self.navigationItem.rightBarButtonItems isEqualToArray:targetItems]) return;
  BOOL shouldAnimate = animated && self.isViewLoaded && self.view.window != nil;
  [self.navigationItem setRightBarButtonItems:targetItems animated:shouldAnimate];
}

- (void)updateRightBarButtons {
  [self updateRightBarButtons:YES];
}

- (void)promptRevertStaged {
  if (!_stagedArticles.count || _syncingArticles || _articleOperation || self.presentedViewController) return;
  NSArray<NSDictionary *> *selection = [_stagedArticles copy];
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"撤销所有未提交操作？"
      message:[NSString stringWithFormat:@"将撤销 %lu 篇文章的待发布、待下架或内容修改，恢复到已确认的云端版本。尚未发布的新草稿及附件会保留，仅取消待发布状态。已提交到云端的操作不会撤回；撤销前会保留本地备份。", (unsigned long)selection.count]
      preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  __weak typeof(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"撤销所有操作" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
    (void)action;
    // Run after confirmation dismissal, so any failure alert is not lost behind it.
    typeof(self) self = weakSelf;
    if (!self) return;
    [self dismissViewControllerAnimated:YES completion:^{ [weakSelf revertStagedSelection:selection]; }];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)revertStagedSelection:(NSArray<NSDictionary *> *)selection {
  if (!selection.count || _syncingArticles || _articleOperation) return;
  NSUUID *operation = NSUUID.UUID;
  _articleOperation = operation;
  _articleOperationMessage = @"正在核验并撤销未提交操作…";
  _articleSyncMessage = nil;
  ++_articleLoadGeneration; // A pre-revert scan may not install stale badges.
  _articleLoadScheduled = NO;
  [self updateArticleFeedback];
  __weak typeof(self) weakSelf = self;
  [LBMdStore.shared revertStagedArticles:selection done:^(NSError *error) {
    typeof(self) self = weakSelf;
    if (!self || self->_articleOperation != operation) return;
    self->_articleOperation = nil;
    self->_articleOperationMessage = nil;
    self->_articleSyncMessage = error ? [NSString stringWithFormat:@"撤销失败：%@", error.localizedDescription]
                                    : @"已撤销未提交操作，新草稿与附件已保留";
    [self loadArticles];
    [self updateArticleFeedback];
    if (error && self->_visible) [self showArticleError:error];
    else if (!error) [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
  }];
}

- (void)reviewStaged {
  if (!_stagedArticles.count || _syncingArticles || _articleOperation) return;
  __weak typeof(self) weakSelf = self;
  LBArticlesReviewViewController *rev = [[LBArticlesReviewViewController alloc] initWithStagedArticles:_stagedArticles done:^{
    [weakSelf loadArticles];
  }];
  LBNavigationController *nav = [[LBNavigationController alloc] initWithRootViewController:rev];
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)reload {
  if (!_stagedArticles) _stagedArticles = @[]; // computed off-main by loadArticles
  _stagedDict = [NSMutableDictionary dictionary];
  for (NSDictionary *s in _stagedArticles) {
    if (s[@"id"]) _stagedDict[s[@"id"]] = s[@"action"];
  }
  [self updateRightBarButtons:YES];
  [self updateArticleFeedback];
  if (_searchDismissing || (!_visible && _renderKey)) return;
  // Reloading under an open/closing swipe tears the row apart (stale action
  // strip, half-height card). The bar buttons above already updated; rows
  // follow as soon as the swipe has ended.
  if (_swipeActive) {
    if (!_pendingReload) {
      // Safety net in case UIKit never reports the end of the swipe.
      __weak typeof(self) weakSelf = self;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (self && self->_pendingReload && ![self swipeStillShowing]) { self->_swipeActive = NO; [self reload]; }
      });
    }
    _pendingReload = YES;
    return;
  }
  _pendingReload = NO;
  NSArray *all = _articles ?: @[];
  if ([_filterMode isEqualToString:@"PUBLISHED"]) {
    all = [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"publish == YES OR publish == nil"]];
  } else if ([_filterMode isEqualToString:@"DRAFT"]) {
    all = [all filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"publish == NO"]];
  }

  NSDictionary *key = @{ @"rows": all, @"query": _query ?: @"",
      @"loaded": @(all.count > 0), @"configured": @(YES),
      @"filter": _filterMode ?: @"ALL",
      @"staged": _stagedArticles ?: @[],
      @"folder": LBMdStore.shared.folderDisplayName ?: @"" };
  if ([_renderKey isEqual:key]) return;
  _renderKey = key;
  NSArray *oldItems = _items;
  NSArray *oldSignatures = _rowSignatures;
  _items = _query.length ? [all filteredArrayUsingPredicate:
      [NSPredicate predicateWithFormat:@"title CONTAINS[cd] %@ OR summary CONTAINS[cd] %@", _query, _query]] : all;
  NSMutableArray *signatures = [NSMutableArray arrayWithCapacity:_items.count];
  for (NSDictionary *p in _items) {
    NSString *noteId = p[@"id"] ?: @"";
    [signatures addObject:@[ p, _transitioningArticles[noteId] ?: _stagedDict[noteId] ?: @"" ]];
  }
  _rowSignatures = signatures;
  // Same rows in the same order (e.g. a publish/unpublish badge change):
  // update only the changed cards in place. The glass views stay alive and
  // the list does not jump, instead of rebuilding every visible cell.
  if (_table.window && oldItems.count && oldItems.count == _items.count && oldSignatures.count == signatures.count &&
      [[oldItems valueForKey:@"id"] isEqual:[_items valueForKey:@"id"]]) {
    NSMutableArray<NSIndexPath *> *changed = [NSMutableArray array];
    for (NSUInteger i = 0; i < signatures.count; i++)
      if (![oldSignatures[i] isEqual:signatures[i]]) [changed addObject:[NSIndexPath indexPathForRow:(NSInteger)i inSection:0]];
    if (changed.count) {
      [_table performBatchUpdates:^{ [self->_table reconfigureRowsAtIndexPaths:changed]; } completion:nil];
    }
    return;
  }
  [_notice removeFromSuperview];
  _notice = nil;
  if (!all.count) {
    __weak typeof(self) w = self;
    _notice = LBNotice(@"folder", @"暂无文章",
                       [NSString stringWithFormat:@"当前目录「%@」暂无 .md 文章，可点右上角新建或选择已有文章目录。", LBMdStore.shared.folderDisplayName],
                       @"选择文章目录", ^{ [w chooseFolder]; });
  }
  _table.backgroundView = _notice;
  [_table reloadData];
  if (!_table.isTracking && !_table.isDragging && !_table.isDecelerating) {
    CGFloat targetTop = -_table.adjustedContentInset.top;
    if (_table.contentOffset.y > targetTop && _table.contentOffset.y < targetTop + 100) {
      [_table setContentOffset:CGPointMake(0, targetTop) animated:NO];
    }
  }
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _items.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  LBCardCell *c = [t dequeueReusableCellWithIdentifier:@"card" forIndexPath:ip];
  [c resetCardContent]; // reconfigure hands back the live cell without prepareForReuse
  if (ip.row >= (NSInteger)_items.count) { [c finishConfiguration]; return c; }
  NSDictionary *p = _items[ip.row];
  NSString *title = p[@"title"];
  if (![title isKindOfClass:NSString.class] || !title.length) {
    title = p[@"slug"] ?: @"未命名文章";
  }
  c.titleLabel.text = title;
  c.titleLabel.font = [LBTheme rounded:17 weight:UIFontWeightSemibold];
  c.titleLabel.textColor = LBTheme.ink;
  c.titleLabel.numberOfLines = 2;
  c.titleLabel.hidden = NO;
      
  BOOL pubState = [p[@"publish"] boolValue];
  NSString *noteId = p[@"id"];
  NSString *stagedOp = _stagedDict[noteId];
  NSString *activeOp = _transitioningArticles[noteId] ?: stagedOp;
  BOOL unpublishing = [activeOp isEqualToString:@"unpublish"] || [activeOp isEqualToString:@"unpublishing"];
  BOOL isStagedPublish = [activeOp isEqualToString:@"publish"];
  BOOL publishing = isStagedPublish || [activeOp isEqualToString:@"publishing"] || [p[@"sync"] boolValue] || [p[@"syncStatus"] isEqualToString:@"publishing"];

  long long created = [p[@"createdAt"] longLongValue];
  long long updated = [p[@"updatedAt"] longLongValue];
  long long published = [p[@"publishedAt"] longLongValue];
  BOOL publishedArticle = pubState && !isStagedPublish;
  if (publishedArticle) {
    long long pubTs = published > 0 ? published : created;
    long long updTs = updated > 0 ? updated : pubTs;
    c.metaLabel.text = [NSString stringWithFormat:@"发布：%@    更新：%@", LBArticleTimestamp(pubTs), LBArticleTimestamp(updTs)];
  } else {
    long long creTs = created > 0 ? created : published;
    long long updTs = updated > 0 ? updated : creTs;
    c.metaLabel.text = [NSString stringWithFormat:@"创建：%@    更新：%@", LBArticleTimestamp(creTs), LBArticleTimestamp(updTs)];
  }
  c.metaLabel.numberOfLines = 1;
  c.metaLabel.hidden = NO;

  NSString *summary = p[@"summary"];
  if (![summary isKindOfClass:NSString.class] || !summary.length) {
    summary = @"（暂无摘要）";
  }
  c.bodyLabel.text = summary;
  c.bodyLabel.textColor = LBTheme.muted;
  c.bodyLabel.hidden = NO;

  if (unpublishing) {
    [c.extraStack addArrangedSubview:LBChip(@"下架中…", UIColor.systemOrangeColor)];
  } else if (publishing) {
    [c.extraStack addArrangedSubview:LBChip(@"发布中…", UIColor.systemOrangeColor)];
  } else if (pubState) {
    [c.extraStack addArrangedSubview:LBChip(@"已发布", [UIColor colorWithRed:0.1 green:0.75 blue:0.4 alpha:1.0])];
    if ([activeOp isEqualToString:@"update"]) {
      [c.extraStack addArrangedSubview:LBChip(@"已修改", UIColor.systemTealColor)];
    }
  } else {
    [c.extraStack addArrangedSubview:LBChip(@"草稿", LBTheme.muted)];
  }

  for (NSString *tag in p[@"tags"] ?: @[]) [c.extraStack addArrangedSubview:LBChip([@"#" stringByAppendingString:tag], UIColor.systemTealColor)];
  if ([p[@"hasImage"] boolValue]) [c.extraStack addArrangedSubview:LBChip(@"图片", LBTheme.muted)];
  if (c.extraStack.arrangedSubviews.count) [c.extraStack addArrangedSubview:[UIView new]];
  [c finishConfiguration];
  return c;
}
- (void)deletePost:(NSString *)noteId done:(void (^)(BOOL))done {
  [LBMdStore.shared deleteArticle:noteId done:^(NSError *error) {
    if (error) [self showArticleError:error];
    if (done) done(error == nil);
  }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
  if (ip.row >= (NSInteger)_items.count) return nil;
  NSDictionary *p = _items[ip.row];
  NSString *noteId = p[@"id"];
  if (!noteId.length || _syncingArticles || _articleOperation) return nil;

  NSMutableArray *actions = [NSMutableArray array];

  UIContextualAction *edit = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"编辑" handler:^(UIContextualAction *act, UIView *sourceView, void (^done)(BOOL)) {
    if (self->_syncingArticles || self->_articleOperation) { done(NO); return; }
    NSDictionary *full = [LBMdStore.shared loadArticle:noteId] ?: p;
    LBPostEditor *editor = [[LBPostEditor alloc] initWithPost:full saved:^(NSDictionary *savedPost) {
      [self loadArticles];
    }];
    LBNavigationController *nav = [[LBNavigationController alloc] initWithRootViewController:editor];
    [self presentViewController:nav animated:YES completion:nil];
    done(YES);
  }];
  edit.backgroundColor = LBTheme.accent;
  [actions addObject:edit];

  BOOL published = [p[@"publish"] boolValue];
  NSString *stagedOp = _stagedDict[noteId];
  BOOL isStagedUnpublish = [stagedOp isEqualToString:@"unpublish"];
  BOOL isStagedPublish = [stagedOp isEqualToString:@"publish"];
  NSString *actionTitle = isStagedUnpublish ? @"撤回下架"
      : (isStagedPublish ? @"撤回发布"
      : (published ? @"下架文章" : @"发布"));
  UIColor *actionColor = (isStagedUnpublish || isStagedPublish) ? UIColor.systemTealColor
      : (published ? UIColor.systemOrangeColor : UIColor.systemGreenColor);

  UIContextualAction *transition = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:actionTitle handler:^(UIContextualAction *act, UIView *sourceView, void (^done)(BOOL)) {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    NSError *err = nil;
    BOOL ok;
    if (isStagedUnpublish) {
      ok = [LBMdStore.shared stagePublishArticle:noteId error:&err];
    } else if (isStagedPublish) {
      ok = [LBMdStore.shared stageUnpublishArticle:noteId error:&err];
    } else if (published) {
      ok = [LBMdStore.shared stageUnpublishArticle:noteId error:&err];
    } else {
      ok = [LBMdStore.shared stagePublishArticle:noteId error:&err];
    }
    done(ok);
    if (!ok) {
      // Previously ignored: the swipe closed as if it worked and nothing changed.
      [self showArticleError:err ?: [NSError errorWithDomain:@"LBContent" code:500 userInfo:@{NSLocalizedDescriptionKey:@"本地暂存失败，文章未改动"}]];
      return;
    }
    // Scan starts now in the background; the bar buttons animate as soon as it
    // returns and the row updates in place once the swipe has closed.
    [self loadArticles];
  }];
  transition.backgroundColor = actionColor;
  [actions addObject:transition];

  UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除" handler:^(UIContextualAction *act, UIView *sourceView, void (^done)(BOOL)) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"删除文章？"
                                                               message:published ? @"将从本地目录删除该文章，若已配置 GitHub 也会从仓库中移除。" : @"将从本地目录删除该草稿文件。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { done(NO); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
      [self deletePost:noteId done:^(BOOL ok) {
        [self loadArticles];
        done(ok);
      }];
    }]];
    [self presentViewController:a animated:YES completion:nil];
  }];
  if (!published) [actions addObject:del];

  UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:actions];
  cfg.performsFirstActionWithFullSwipe = NO;
  return cfg;
}

- (BOOL)swipeStillShowing {
  if (_table.isEditing) return YES;
  for (UITableViewCell *cell in _table.visibleCells) if (cell.isEditing || cell.showingDeleteConfirmation) return YES;
  return NO;
}
- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
  _swipeActive = YES;
  LBStyleSwipeActions(tableView);
}
- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
  _swipeActive = NO;
  if (!_pendingReload) return;
  // Let the close animation settle for one frame, then update in place.
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    typeof(self) self = weakSelf;
    if (self && !self->_swipeActive && self->_pendingReload) [self reload];
  });
}

- (void)directPublishPost:(NSString *)noteId published:(BOOL)published done:(void (^)(BOOL))done {
  void (^finished)(NSError *) = ^(NSError *error) {
    if (done) done(error == nil);
  };
  if (published) [LBMdStore.shared unpublishArticle:noteId done:finished];
  else [LBMdStore.shared publishArticle:noteId done:finished];
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
  if (ip.row >= (NSInteger)_items.count) return;
  NSDictionary *p = _items[ip.row];
  // Avoid synchronously loading the full article on the main thread; the reader's
  // initializer and background loader already do that cleanly.
  [self.navigationController pushViewController:[[LBPostReaderViewController alloc] initWithPost:p] animated:YES];
}
@end

#pragma mark - Shuoshuo
@interface LBMemosViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UISearchControllerDelegate>
@end

@implementation LBMemosViewController {
  UITableView *_table;
  NSString *_query;
  NSArray<NSDictionary *> *_items;
  NSDictionary *_renderKey;
  BOOL _searchDismissing;
  BOOL _visible;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"说说";
  _table = LBGlassTable(self, self);
  UIRefreshControl *rc = [UIRefreshControl new];
  [rc addTarget:self action:@selector(pull:) forControlEvents:UIControlEventValueChanged];
  _table.refreshControl = rc;
  UISearchController *sc = [[UISearchController alloc] initWithSearchResultsController:nil];
  sc.searchResultsUpdater = self;
  sc.delegate = self;
  sc.hidesNavigationBarDuringPresentation = NO;
  sc.obscuresBackgroundDuringPresentation = NO;
  sc.searchBar.placeholder = @"搜索说说";
  self.navigationItem.searchController = sc;
  self.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
  self.navigationItem.hidesSearchBarWhenScrolling = NO;
  self.navigationItem.searchBarPlacementAllowsToolbarIntegration = NO;
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:LBSiteDataDidChange object:nil];
  [self reload];
  if (!LBSiteData.shared.memos) [LBSiteData.shared refreshMemos:nil];
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  _visible = YES;
  [self reload];
}
- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  _visible = NO; // freeze the data source through push and interactive pop
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)pull:(UIRefreshControl *)rc { [LBSiteData.shared refreshMemos:^{ [rc endRefreshing]; }]; }
// Inactive updates are UIKit clearing the field during dismissal, not user
// typing. Keep the visible snapshot unchanged until didDismiss, not a timer.
- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
  // UIKit can also send an inactive initial update when attaching the search
  // controller. Ignore it without entering a dismissal that may never finish.
  if (_searchDismissing || !sc.isActive) return;
  _query = [sc.searchBar.text copy] ?: @"";
  [self reload];
}
- (void)willPresentSearchController:(UISearchController *)sc { _searchDismissing = NO; }
- (void)willDismissSearchController:(UISearchController *)sc { _searchDismissing = YES; }
- (void)didDismissSearchController:(UISearchController *)sc {
  _query = @"";
  sc.searchBar.text = @"";
  _searchDismissing = NO;
  [self reload];
}
- (void)reload {
  if (_searchDismissing || (!_visible && _renderKey)) return;
  LBSiteData *d = LBSiteData.shared;
  NSArray *all = [d.memos copy] ?: @[];
  NSDictionary *key = @{ @"rows": all, @"query": _query ?: @"",
      @"loaded": @(d.memos != nil), @"configured": @(LBGitHub.shared.configured),
      @"error": d.errors[@"memos"].localizedDescription ?: @"" };
  if ([_renderKey isEqual:key]) return; // unrelated data notifications do not relayout this list
  _renderKey = key;
  _items = _query.length ? [all filteredArrayUsingPredicate:
      [NSPredicate predicateWithFormat:@"content CONTAINS[cd] %@", _query]] : all;
  self.navigationItem.subtitle = d.memos ? [NSString stringWithFormat:@"共 %lu 条", (unsigned long)d.memos.count] : nil;
  _table.backgroundView = (!d.memos && d.errors[@"memos"])
      ? LBNotice(@"exclamationmark.triangle", @"加载失败", d.errors[@"memos"].localizedDescription, nil, nil) : nil;
  [_table reloadData];
}
static NSString *plain(NSString *md) {
  // Light Markdown cleanup for previews: images, links, emphasis, headings.
  NSString *s = [md isKindOfClass:NSString.class] ? md : @"";
  NSArray *rules = @[ @[ @"!\\[[^\\]]*\\]\\([^)]*\\)", @"" ], @[ @"\\[([^\\]]+)\\]\\([^)]*\\)", @"$1" ],
                      @[ @"(\\*\\*|__|~~|`)", @"" ], @[ @"(?m)^#{1,6}\\s*", @"" ], @[ @"\\\\([\\\\`*_{}\\[\\]()#+\\-.!|])", @"$1" ] ];
  for (NSArray *r in rules)
    s = [s stringByReplacingOccurrencesOfString:r[0] withString:r[1] options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)];
  return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _items.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  LBCardCell *c = [t dequeueReusableCellWithIdentifier:@"card" forIndexPath:ip];
  if (ip.row >= (NSInteger)_items.count) { [c finishConfiguration]; return c; }
  NSDictionary *m = _items[ip.row];
  long long ts = [m[@"displayTs"] longLongValue] ?: [m[@"createdTs"] longLongValue];
  c.titleLabel.text = LBRelativeTime(ts * 1000);
  c.titleLabel.font = [LBTheme rounded:14 weight:UIFontWeightSemibold];
  c.titleLabel.textColor = LBTheme.accent;
  c.metaLabel.text = nil;
  c.bodyLabel.text = plain(m[@"content"]);
  c.bodyLabel.textColor = LBTheme.ink;
  c.bodyLabel.numberOfLines = 6;
  if ([m[@"pinned"] boolValue]) {
    UIImageView *pin = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pin.fill"]];
    pin.tintColor = LBTheme.accent;
    c.trailingView = pin;
  }
  NSArray *res = [m[@"resourceList"] isKindOfClass:NSArray.class] ? m[@"resourceList"] : @[];
  // Keep attachment rows scrollable rather than forcing four fixed-size images
  // and chips into a narrow card.
  UIStackView *attachments = [UIStackView new];
  attachments.axis = UILayoutConstraintAxisHorizontal;
  attachments.alignment = UIStackViewAlignmentCenter;
  attachments.spacing = 6;
  attachments.translatesAutoresizingMaskIntoConstraints = NO;
  NSUInteger shown = 0, files = 0;
  for (NSDictionary *r in res) {
    NSString *type = [r[@"type"] isKindOfClass:NSString.class] ? r[@"type"] : @"";
    NSString *thumb = [r[@"thumbnailUrl"] isKindOfClass:NSString.class] ? r[@"thumbnailUrl"] : nil;
    if ([type hasPrefix:@"image/"] && thumb && shown < 4) {
      UIImageView *iv = [UIImageView new];
      iv.contentMode = UIViewContentModeScaleAspectFill;
      iv.clipsToBounds = YES;
      iv.layer.cornerRadius = 12;
      iv.layer.cornerCurve = kCACornerCurveContinuous;
      iv.backgroundColor = LBTheme.accentSoft;
      [iv.widthAnchor constraintEqualToConstant:64].active = YES;
      [iv.heightAnchor constraintEqualToConstant:64].active = YES;
      [attachments addArrangedSubview:iv];
      [LBHTTP image:[NSURL URLWithString:thumb] done:^(UIImage *img) { iv.image = img; }];
      shown++;
    } else if (![type hasPrefix:@"image/"]) files++;
  }
  NSUInteger moreImages = 0;
  for (NSDictionary *r in res) if ([r[@"type"] hasPrefix:@"image/"]) moreImages++;
  if (moreImages > shown) [attachments addArrangedSubview:LBChip([NSString stringWithFormat:@"+%lu", (unsigned long)(moreImages - shown)], LBTheme.muted)];
  if (files) [attachments addArrangedSubview:LBChip([NSString stringWithFormat:@"%lu 个附件", (unsigned long)files], UIColor.systemTealColor)];
  if (attachments.arrangedSubviews.count) {
    UIScrollView *strip = [UIScrollView new];
    strip.showsHorizontalScrollIndicator = NO;
    [strip addSubview:attachments];
    [c.extraStack addArrangedSubview:strip];
    [NSLayoutConstraint activateConstraints:@[
      [strip.widthAnchor constraintEqualToAnchor:c.extraStack.widthAnchor],
      [strip.heightAnchor constraintEqualToConstant:shown ? 64 : 20],
      [attachments.leadingAnchor constraintEqualToAnchor:strip.contentLayoutGuide.leadingAnchor],
      [attachments.trailingAnchor constraintEqualToAnchor:strip.contentLayoutGuide.trailingAnchor],
      [attachments.topAnchor constraintEqualToAnchor:strip.contentLayoutGuide.topAnchor],
      [attachments.bottomAnchor constraintEqualToAnchor:strip.contentLayoutGuide.bottomAnchor],
      [attachments.heightAnchor constraintEqualToAnchor:strip.frameLayoutGuide.heightAnchor],
    ]];
  }
  [c finishConfiguration];
  return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
  if (ip.row >= (NSInteger)_items.count) return;
  LBOpenURL(self, [NSURL URLWithString:[LBStore.siteURL stringByAppendingString:@"/shuoshuo/"]]);
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)t contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)p {
  if (ip.row >= (NSInteger)_items.count) return nil;
  NSString *text = _items[ip.row][@"content"];
  return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
    return [UIMenu menuWithChildren:@[ [UIAction actionWithTitle:@"拷贝文字" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                                                          handler:^(UIAction *a) { UIPasteboard.generalPasteboard.string = text; }] ]];
  }];
}
@end

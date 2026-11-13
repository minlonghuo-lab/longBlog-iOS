#import "LBLayout.h"
#import "LBArchive.h"

#pragma mark - Card cell
@interface LBSessionCell : UITableViewCell
- (void)apply:(LBSession *)s unread:(BOOL)unread;
@end

@implementation LBSessionCell {
  UIVisualEffectView *_glass;
  LBAvatarView *_avatar;
  UILabel *_title, *_time, *_preview, *_chip;
  UIView *_dot;
  UIImageView *_replied;
  BOOL _hasTint, _unreadTint;
}
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
  if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _glass = [LBTheme glassWithTint:[LBTheme.surface colorWithAlphaComponent:0.35] interactive:YES];
    _glass.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:26]];
    [self.contentView addSubview:_glass];
    UIView *c = _glass.contentView;

    _avatar = [LBAvatarView new];
    _title = [UILabel new];
    _title.font = [LBTheme mono:15 weight:UIFontWeightSemibold];
    _title.textColor = LBTheme.ink;
    _time = [UILabel new];
    _time.font = [LBTheme rounded:12 weight:UIFontWeightMedium];
    _time.textColor = LBTheme.muted;
    [_time setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _preview = [UILabel new];
    _preview.font = [UIFont systemFontOfSize:15];
    _preview.textColor = LBTheme.ink;
    _preview.numberOfLines = 2;
    _chip = [UILabel new];
    _chip.font = [LBTheme rounded:11 weight:UIFontWeightSemibold];
    _chip.textColor = LBTheme.accent;
    _dot = [UIView new];
    _dot.backgroundColor = LBTheme.accent;
    _dot.layer.cornerRadius = 5;
    _replied = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrowshape.turn.up.left.fill"]];
    _replied.tintColor = LBTheme.muted;
    _replied.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
    for (UIView *v in @[ _avatar, _title, _time, _preview, _chip, _dot, _replied ]) {
      v.translatesAutoresizingMaskIntoConstraints = NO;
      [c addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
      [_glass.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
      [_glass.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
      [_glass.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
      [_glass.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
      [_avatar.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:16],
      [_avatar.topAnchor constraintEqualToAnchor:c.topAnchor constant:16],
      [_avatar.widthAnchor constraintEqualToConstant:44],
      [_avatar.heightAnchor constraintEqualToConstant:44],
      [_title.leadingAnchor constraintEqualToAnchor:_avatar.trailingAnchor constant:12],
      [_title.topAnchor constraintEqualToAnchor:c.topAnchor constant:16],
      [_time.leadingAnchor constraintGreaterThanOrEqualToAnchor:_title.trailingAnchor constant:8],
      [_time.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
      [_dot.leadingAnchor constraintEqualToAnchor:_time.trailingAnchor constant:8],
      [_dot.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-16],
      [_dot.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
      [_dot.widthAnchor constraintEqualToConstant:10],
      [_dot.heightAnchor constraintEqualToConstant:10],
      [_replied.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
      [_replied.firstBaselineAnchor constraintEqualToAnchor:_preview.firstBaselineAnchor],
      [_preview.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor constant:0],
      [_preview.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-16],
      [_preview.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:5],
      [_chip.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
      [_chip.topAnchor constraintEqualToAnchor:_preview.bottomAnchor constant:8],
      [_chip.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-14],
    ]];
  }
  return self;
}
- (void)apply:(LBSession *)s unread:(BOOL)unread {
  [_avatar setSession:s.sessionId];
  _title.text = [@"#" stringByAppendingString:s.shortId];
  _time.text = LBRelativeTime(s.last.createdAt);
  BOOL mine = ![s.last fromVisitor];
  _replied.hidden = !mine;
  NSString *text = [s.last.text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
  _preview.text = mine ? [@"     " stringByAppendingString:text] : text;
  _preview.textColor = mine ? LBTheme.muted : LBTheme.ink;
  _preview.font = unread ? [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold] : [UIFont systemFontOfSize:15];
  _chip.text = [NSString stringWithFormat:@"%ld 条消息 · %@", (long)s.sequence, LBRemaining(s.expiresAt)];
  _dot.alpha = unread ? 1 : 0;
  if (unread && LBShouldAnimate(YES)) {
    if (![_dot.layer animationForKey:@"dotBreathe"]) {
      CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
      breathe.fromValue = @(0.85);
      breathe.toValue = @(1.25);
      breathe.duration = 1.6;
      breathe.autoreverses = YES;
      breathe.repeatCount = HUGE_VALF;
      breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      [_dot.layer addAnimation:breathe forKey:@"dotBreathe"];
    }
  } else {
    [_dot.layer removeAnimationForKey:@"dotBreathe"];
    _dot.transform = CGAffineTransformIdentity;
  }
  if (!_hasTint || _unreadTint != unread) {
    _hasTint = YES; _unreadTint = unread;
    UIGlassEffect *g = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    g.interactive = YES;
    g.tintColor = unread ? LBTheme.accentSoft : [LBTheme.surface colorWithAlphaComponent:0.35];
    _glass.effect = g;
  }
}
- (void)setHighlighted:(BOOL)h animated:(BOOL)a {
  // UIKit may repeat the same state while tracking; feedback belongs to edges.
  if (self.highlighted == h) return;
  [super setHighlighted:h animated:LBShouldAnimate(a)];
  if (!LBShouldAnimate(a)) { _glass.transform = CGAffineTransformIdentity; return; }
  if (h) {
    UIImpactFeedbackGenerator *f = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [f impactOccurredWithIntensity:0.65];
  }
  [UIView animateWithDuration:h ? 0.12 : 0.35 delay:0 usingSpringWithDamping:0.65 initialSpringVelocity:0
                      options:UIViewAnimationOptionAllowUserInteraction animations:^{
    self->_glass.transform = h ? CGAffineTransformMakeScale(0.975, 0.975) : CGAffineTransformIdentity;
  } completion:nil];
}
@end

#pragma mark - Inbox
@interface LBInboxViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation LBInboxViewController {
  UITableView *_table;
  NSTimer *_relativeTimer;
  UIView *_empty;
  UILabel *_emptyTitle, *_emptyBody;
  UIButton *_emptyButton;
  UIVisualEffectView *_statusPill;
  UILabel *_statusLabel;
  NSString *_pendingOpen;
  NSArray<LBSession *> *_displaySessions;
  NSString *_rowsSignature;
  BOOL _visible, _needsReload, _returnToInitialPage;
  UIView *_navHeaderView;
  UILabel *_navTitleLabel;
  UIStackView *_navSubtitleStack;
  UIImageView *_navSyncIcon;
  UILabel *_navSubtitleLabel;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  _displaySessions = @[];
  self.title = @"终端留言";

  // Header Title View (Consistent typography with Posts, Memos and Dashboard)
  _navHeaderView = [UIView new];
  _navTitleLabel = [UILabel new];
  _navTitleLabel.text = @"终端留言";
  _navTitleLabel.font = [LBTheme rounded:18 weight:UIFontWeightBold];
  _navTitleLabel.textColor = LBTheme.ink;

  _navSyncIcon = [UIImageView new];
  _navSyncIcon.contentMode = UIViewContentModeScaleAspectFit;
  _navSyncIcon.tintColor = LBTheme.muted;
  _navSyncIcon.image = [UIImage systemImageNamed:@"bubble.left.and.text.bubble.right"];
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

  _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
  _table.backgroundColor = UIColor.clearColor;
  _table.separatorStyle = UITableViewCellSeparatorStyleNone;
  _table.dataSource = self;
  _table.delegate = self;
  _table.rowHeight = UITableViewAutomaticDimension;
  _table.estimatedRowHeight = 120;
  _table.contentInset = UIEdgeInsetsMake(4, 0, 70, 0);
  [_table registerClass:LBSessionCell.class forCellReuseIdentifier:@"s"];
  UIRefreshControl *rc = [UIRefreshControl new];
  [rc addTarget:self action:@selector(pull:) forControlEvents:UIControlEventValueChanged];
  _table.refreshControl = rc;
  LBInstallContentScrollView(self, _table, nil);

  UIBarButtonItem *gear = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                                           style:UIBarButtonItemStylePlain target:self action:@selector(openSettings)];
  UIBarButtonItem *archive = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"archivebox"] style:UIBarButtonItemStylePlain target:self action:@selector(openArchive)];
  archive.accessibilityLabel = @"过期留言归档";
  self.navigationItem.rightBarButtonItems = @[ gear, archive ];

  [self buildEmptyState];
  [self buildStatusPill];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:LBSyncDidChange object:nil];
  [self reload];
}
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  UIViewController *from = [self.transitionCoordinator viewControllerForKey:UITransitionContextFromViewControllerKey];
  if ([from isKindOfClass:LBArchiveViewController.class] || [from isKindOfClass:LBChatViewController.class]) _returnToInitialPage = YES;
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  _visible = YES;
  [_relativeTimer invalidate];
  __weak typeof(self) weakSelf = self;
  _relativeTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *t) { [weakSelf reload]; }];
  [self reload];
  if (_returnToInitialPage) {
    _returnToInitialPage = NO;
    // Only after a completed pop. Never move the root underneath an interactive back gesture.
    [UIView performWithoutAnimation:^{
      [self.view layoutIfNeeded];
      [self->_table setContentOffset:CGPointMake(0, -self->_table.adjustedContentInset.top) animated:NO];
    }];
  }
  if (_pendingOpen) { NSString *s = _pendingOpen; _pendingOpen = nil; [self openSession:s animated:YES]; }
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  _visible = NO;
  _returnToInitialPage = NO; // A cancelled interactive pop must not leave a future reset queued.
  [_relativeTimer invalidate];
  _relativeTimer = nil;
}
- (void)dealloc {
  [_relativeTimer invalidate];
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)buildEmptyState {
  _empty = [UIView new];
  _empty.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:_empty];
  UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"apple.terminal"]];
  icon.tintColor = LBTheme.accent;
  icon.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:46 weight:UIImageSymbolWeightLight];
  _emptyTitle = [UILabel new];
  _emptyTitle.font = [LBTheme rounded:22 weight:UIFontWeightBold];
  _emptyTitle.textColor = LBTheme.ink;
  _emptyBody = [UILabel new];
  _emptyBody.font = [UIFont systemFontOfSize:15];
  _emptyBody.textColor = LBTheme.muted;
  _emptyBody.numberOfLines = 0;
  _emptyBody.textAlignment = NSTextAlignmentCenter;
  UIButtonConfiguration *bc = [UIButtonConfiguration prominentGlassButtonConfiguration];
  bc.title = @"连接博客";
  bc.image = [UIImage systemImageNamed:@"key.horizontal.fill"];
  bc.imagePadding = 8;
  bc.baseBackgroundColor = LBTheme.accent;
  bc.contentInsets = NSDirectionalEdgeInsetsMake(12, 22, 12, 22);
  _emptyButton = [UIButton buttonWithConfiguration:bc primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [self openSettings]; }]];
  UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, _emptyTitle, _emptyBody, _emptyButton ]];
  st.axis = UILayoutConstraintAxisVertical;
  st.alignment = UIStackViewAlignmentCenter;
  st.spacing = 12;
  [st setCustomSpacing:22 afterView:_emptyBody];
  st.translatesAutoresizingMaskIntoConstraints = NO;
  [_empty addSubview:st];
  [NSLayoutConstraint activateConstraints:@[
    [_empty.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
    [_empty.centerYAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerYAnchor constant:-30],
    [_empty.widthAnchor constraintLessThanOrEqualToConstant:300],
    [_empty.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
    [_empty.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
    [st.topAnchor constraintEqualToAnchor:_empty.topAnchor], [st.bottomAnchor constraintEqualToAnchor:_empty.bottomAnchor],
    [st.leadingAnchor constraintEqualToAnchor:_empty.leadingAnchor], [st.trailingAnchor constraintEqualToAnchor:_empty.trailingAnchor],
  ]];
}
- (void)buildStatusPill {
  _statusPill = [LBTheme glassWithTint:nil interactive:YES];
  _statusPill.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
  [self.view addSubview:_statusPill];
  _statusLabel = [UILabel new];
  _statusLabel.font = [LBTheme rounded:13 weight:UIFontWeightSemibold];
  _statusLabel.textColor = LBTheme.ink;
  _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
  _statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  [_statusPill.contentView addSubview:_statusLabel];
  UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pull:)];
  [_statusPill addGestureRecognizer:tap];
  [NSLayoutConstraint activateConstraints:@[
    [_statusPill.centerXAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.centerXAnchor],
    [_statusPill.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
    [_statusPill.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
    [_statusPill.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-10],
    [_statusPill.heightAnchor constraintEqualToConstant:40],
    [_statusLabel.leadingAnchor constraintEqualToAnchor:_statusPill.contentView.leadingAnchor constant:18],
    [_statusLabel.trailingAnchor constraintEqualToAnchor:_statusPill.contentView.trailingAnchor constant:-18],
    [_statusLabel.centerYAnchor constraintEqualToAnchor:_statusPill.contentView.centerYAnchor],
  ]];
}

- (void)pull:(id)sender {
  [LBSync.shared refresh:^(BOOL fresh) { [self->_table.refreshControl endRefreshing]; }];
}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
  if (!decelerate && _needsReload) [self reload];
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { if (_needsReload) [self reload]; }
- (void)reload {
  _needsReload = YES;
  // _visible becomes true only in didAppear, after a completed navigation transition.
  if (!_visible || _table.dragging || _table.decelerating) return;
  _needsReload = NO;
  LBSync *s = LBSync.shared;
  BOOL configured = [LBAPI.shared configured];
  NSInteger unread = [s unreadCount];
  NSString *subtitle = !configured ? @"未连接"
      : unread ? [NSString stringWithFormat:@"%ld 个会话有新消息", (long)unread]
      : [NSString stringWithFormat:@"%lu 个进行中的会话", (unsigned long)s.sessions.count];
  self.navigationItem.subtitle = nil;
  _navSubtitleLabel.text = subtitle;
  _navSyncIcon.tintColor = !configured ? LBTheme.muted : (unread ? UIColor.systemOrangeColor : [UIColor colorWithRed:0.1 green:0.75 blue:0.4 alpha:1.0]);
  _empty.hidden = configured && s.sessions.count > 0;
  _emptyButton.hidden = configured;
  if (!configured) {
    _emptyTitle.text = @"还没连上博客";
    _emptyBody.text = @"填入站长密钥后，访客在终端里发来的留言会出现在这里，并推送到你的锁屏。";
  } else if (s.lastError && !s.sessions.count) {
    _emptyTitle.text = @"暂时连不上";
    _emptyBody.text = s.lastError.localizedDescription;
  } else {
    _emptyTitle.text = @"终端很安静";
    _emptyBody.text = @"访客在 huowenlong.com 输入 chat 留言后，会第一时间出现在这里 ✨";
  }
  NSString *status;
  if (!configured) status = @"⌁ 未连接";
  else if (s.lastError) status = [@"⚠︎ " stringByAppendingString:s.lastError.localizedDescription];
  else if (s.lastSync) status = [NSString stringWithFormat:@"● 已同步 · %@", LBRelativeTime((long long)(s.lastSync.timeIntervalSince1970 * 1000))];
  else status = @"○ 同步中…";
  _statusLabel.text = status;
  _statusLabel.textColor = s.lastError ? UIColor.systemRedColor : LBTheme.ink;
  NSMutableArray *parts = [NSMutableArray array];
  for (LBSession *session in s.sessions) [parts addObject:[NSString stringWithFormat:@"%@:%ld:%d", session.sessionId, (long)session.sequence, [s isUnread:session]]];
  NSString *signature = [parts componentsJoinedByString:@"|"];
  if (![_rowsSignature isEqualToString:signature]) {
    _rowsSignature = signature;
    _displaySessions = [s.sessions copy];
    [UIView performWithoutAnimation:^{ [self->_table reloadData]; }];
  }
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)section { return _displaySessions.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  LBSessionCell *c = [t dequeueReusableCellWithIdentifier:@"s" forIndexPath:ip];
  LBSession *s = _displaySessions[ip.row];
  [c apply:s unread:[LBSync.shared isUnread:s]];
  return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
  LBSession *s = _displaySessions[ip.row];
  [self.navigationController pushViewController:[[LBChatViewController alloc] initWithSession:s] animated:YES];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
  LBSession *s = _displaySessions[ip.row];
  if (![LBSync.shared isUnread:s]) return nil;
  UIContextualAction *a = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"标为已读"
      handler:^(UIContextualAction *x, UIView *v, void (^done)(BOOL)) { [LBSync.shared markRead:s.sessionId upTo:s.lastUserSequence]; done(YES); }];
  a.image = [UIImage systemImageNamed:@"checkmark.message.fill"];
  a.backgroundColor = LBTheme.accent;
  return [UISwipeActionsConfiguration configurationWithActions:@[ a ]];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)t contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
  if (ip.row >= (NSInteger)_displaySessions.count) return nil;
  LBSession *s = _displaySessions[ip.row];
  __weak typeof(self) weakSelf = self;
  return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
    typeof(self) self = weakSelf;
    if (!self) return nil;
    NSMutableArray *actions = [NSMutableArray array];
    if ([LBSync.shared isUnread:s]) {
      [actions addObject:[UIAction actionWithTitle:@"标为已读" image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(UIAction *a) {
        [LBSync.shared markRead:s.sessionId upTo:s.lastUserSequence];
        [self reload];
      }]];
    }
    [actions addObject:[UIAction actionWithTitle:@"进入会话" image:[UIImage systemImageNamed:@"bubble.left.and.text.bubble.right"] identifier:nil handler:^(UIAction *a) {
      [self.navigationController pushViewController:[[LBChatViewController alloc] initWithSession:s] animated:YES];
    }]];
    [actions addObject:[UIAction actionWithTitle:@"拷贝会话编号" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a) {
      UIPasteboard.generalPasteboard.string = s.shortId;
    }]];
    return [UIMenu menuWithChildren:actions];
  }];
}

- (void)openSession:(NSString *)sid animated:(BOOL)animated {
  if (!self.viewIfLoaded.window) { _pendingOpen = sid; return; }
  UINavigationController *nav = self.navigationController;
  if (self.presentedViewController) [self dismissViewControllerAnimated:NO completion:nil];
  if ([nav.topViewController isKindOfClass:LBChatViewController.class]
      && [((LBChatViewController *)nav.topViewController).sessionId isEqualToString:sid]) return;
  LBSession *found = nil;
  for (LBSession *s in LBSync.shared.sessions) if ([s.sessionId isEqualToString:sid]) found = s;
  if (!found) { // opened from a cold launch: sync first
    [LBSync.shared refresh:^(BOOL fresh) {
      for (LBSession *s in LBSync.shared.sessions) if ([s.sessionId isEqualToString:sid]) {
        [nav popToRootViewControllerAnimated:NO];
        [nav pushViewController:[[LBChatViewController alloc] initWithSession:s] animated:animated];
      }
    }];
    return;
  }
  [nav popToRootViewControllerAnimated:NO];
  [nav pushViewController:[[LBChatViewController alloc] initWithSession:found] animated:animated];
}
- (void)openArchive {
  [self.navigationController pushViewController:[LBArchiveViewController new] animated:LBShouldAnimate(YES)];
}
- (void)openSettings { LBPresentSettings(self); }
@end

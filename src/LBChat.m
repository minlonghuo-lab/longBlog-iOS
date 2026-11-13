#import "LBLayout.h"

#pragma mark - Bubble cell
@interface LBBubbleCell : UITableViewCell
- (void)apply:(LBMessage *)m showTime:(BOOL)showTime;
- (void)apply:(LBMessage *)m showTime:(BOOL)showTime isFollowup:(BOOL)isFollowup;
@end

@implementation LBBubbleCell {
  UIView *_bubble;
  UIVisualEffectView *_glass;
  CAGradientLayer *_fill;
  UILabel *_text, *_meta;
  NSLayoutConstraint *_lead, *_trail, *_metaH, *_bubbleTop, *_bubbleBottom;
  BOOL _isVisitor;
}
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
  if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _meta = [UILabel new];
    _meta.font = [LBTheme rounded:11 weight:UIFontWeightMedium];
    _meta.textColor = LBTheme.muted;
    _meta.textAlignment = NSTextAlignmentCenter;
    _bubble = [UIView new];
    _bubble.layer.cornerRadius = 18;
    _bubble.layer.cornerCurve = kCACornerCurveContinuous;
    _bubble.clipsToBounds = YES;
    // Visitor bubbles: glass. Owner bubbles: terracotta gradient (like the blog accent).
    _glass = [LBTheme glassWithTint:[LBTheme.surface colorWithAlphaComponent:0.4] interactive:NO];
    _glass.translatesAutoresizingMaskIntoConstraints = YES;
    _glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_bubble addSubview:_glass];
    _fill = [CAGradientLayer layer];
    _fill.startPoint = CGPointMake(0, 0);
    _fill.endPoint = CGPointMake(1, 1);
    [_bubble.layer addSublayer:_fill];
    _text = [UILabel new];
    _text.numberOfLines = 0;
    _text.font = [UIFont systemFontOfSize:16];
    for (UIView *v in @[ _meta, _bubble ]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.contentView addSubview:v]; }
    _text.translatesAutoresizingMaskIntoConstraints = NO;
    [_bubble addSubview:_text];
    _lead = [_bubble.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14];
    _trail = [_bubble.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14];
    _metaH = [_meta.heightAnchor constraintEqualToConstant:0];
    _bubbleTop = [_bubble.topAnchor constraintEqualToAnchor:_meta.bottomAnchor constant:3];
    _bubbleBottom = [_bubble.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3];
    [NSLayoutConstraint activateConstraints:@[
      [_meta.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:2],
      [_meta.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
      [_meta.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor], _metaH,
      _bubbleTop, _bubbleBottom,
      [_bubble.widthAnchor constraintLessThanOrEqualToAnchor:self.contentView.widthAnchor multiplier:0.76],
      [_text.topAnchor constraintEqualToAnchor:_bubble.topAnchor constant:10],
      [_text.bottomAnchor constraintEqualToAnchor:_bubble.bottomAnchor constant:-10],
      [_text.leadingAnchor constraintEqualToAnchor:_bubble.leadingAnchor constant:14],
      [_text.trailingAnchor constraintEqualToAnchor:_bubble.trailingAnchor constant:-14],
    ]];
    UIContextMenuInteraction *menu = [[UIContextMenuInteraction alloc] initWithDelegate:(id)self];
    [_bubble addInteraction:menu];
  }
  return self;
}
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)i configurationForMenuAtLocation:(CGPoint)p {
  NSString *t = _text.text;
  return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *s) {
    return [UIMenu menuWithChildren:@[ [UIAction actionWithTitle:@"拷贝" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                                                          handler:^(UIAction *a) { UIPasteboard.generalPasteboard.string = t; }] ]];
  }];
}
- (void)updateBubbleShape {
  CGFloat w = _bubble.bounds.size.width, h = _bubble.bounds.size.height;
  if (w <= 0 || h <= 0) return;
  CGFloat r = 18.0;
  CGFloat tail = 5.0;
  CGFloat tl = r, tr = r;
  CGFloat bl = _isVisitor ? tail : r;
  CGFloat br = _isVisitor ? r : tail;
  UIBezierPath *path = [UIBezierPath bezierPath];
  [path moveToPoint:CGPointMake(tl, 0)];
  [path addLineToPoint:CGPointMake(w - tr, 0)];
  [path addArcWithCenter:CGPointMake(w - tr, tr) radius:tr startAngle:-M_PI_2 endAngle:0 clockwise:YES];
  [path addLineToPoint:CGPointMake(w, h - br)];
  [path addArcWithCenter:CGPointMake(w - br, h - br) radius:br startAngle:0 endAngle:M_PI_2 clockwise:YES];
  [path addLineToPoint:CGPointMake(bl, h)];
  [path addArcWithCenter:CGPointMake(bl, h - bl) radius:bl startAngle:M_PI_2 endAngle:M_PI clockwise:YES];
  [path addLineToPoint:CGPointMake(0, tl)];
  [path addArcWithCenter:CGPointMake(tl, tl) radius:tl startAngle:M_PI endAngle:-M_PI_2 clockwise:YES];
  [path closePath];
  CAShapeLayer *mask = [CAShapeLayer layer];
  mask.path = path.CGPath;
  _bubble.layer.mask = mask;
}
- (void)layoutSubviews {
  [super layoutSubviews];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _fill.frame = _bubble.bounds;
  [self updateBubbleShape];
  [CATransaction commit];
}
- (void)apply:(LBMessage *)m showTime:(BOOL)showTime {
  [self apply:m showTime:showTime isFollowup:NO];
}
- (void)apply:(LBMessage *)m showTime:(BOOL)showTime isFollowup:(BOOL)isFollowup {
  BOOL visitor = [m fromVisitor];
  _isVisitor = visitor;
  _text.text = m.text;
  _text.textColor = visitor ? LBTheme.ink : UIColor.whiteColor;
  _glass.hidden = !visitor;
  _fill.hidden = visitor;
  UIColor *a = LBTheme.accent;
  UIColor *resolved = [a resolvedColorWithTraitCollection:self.traitCollection];
  CGFloat h = 0, s = 0, b = 0, al = 1;
  [resolved getHue:&h saturation:&s brightness:&b alpha:&al];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _fill.colors = @[ (id)[UIColor colorWithHue:h saturation:s * 0.9 brightness:MIN(1, b * 1.18) alpha:1].CGColor, (id)resolved.CGColor ];
  [CATransaction commit];
  _bubble.alpha = m.pending ? 0.6 : 1;
  _lead.active = visitor;
  _trail.active = !visitor;
  NSString *meta = showTime ? LBRelativeTime(m.createdAt) : @"";
  if (m.failed) meta = @"发送失败 · 轻点气泡重试";
  else if (m.pending) meta = @"发送中…";
  _meta.text = meta;
  _meta.textColor = m.failed ? UIColor.systemRedColor : LBTheme.muted;
  _metaH.constant = meta.length ? 18 : 0;
  _bubbleTop.constant = isFollowup ? 1.0 : 3.0;
  _bubbleBottom.constant = isFollowup ? -1.0 : -3.0;
  [self updateBubbleShape];
}
@end

#pragma mark - Chat
@interface LBChatViewController () <UITableViewDataSource, UITableViewDelegate, UITextViewDelegate>
@end

@implementation LBChatViewController {
  LBSession *_session;
  NSUInteger _connectionRevision;
  NSMutableArray<LBMessage *> *_messages;
  NSInteger _cursor;
  BOOL _loading, _sending, _visible, _pendingTableUpdate;
  NSArray<LBMessage *> *_displayMessages;
  UITableView *_table;
  UIVisualEffectView *_composer;
  UITextView *_input;
  UILabel *_placeholder, *_counter;
  NSDictionary *_contact;
  UIView *_contactHeader;
  CGFloat _contactHeaderWidth;
  UIButton *_send;
  NSLayoutConstraint *_inputH;
  NSTimer *_poll;
  BOOL _followBottom, _needsBottomScroll;
  CGSize _lastTableSize;
  CGFloat _lastTopInset;
}
- (instancetype)initWithSession:(LBSession *)s {
  if ((self = [super init])) {
    _session = s;
    _messages = [NSMutableArray array];
    _displayMessages = @[];
    _followBottom = YES;
    _needsBottomScroll = YES;
    _connectionRevision = LBAPI.shared.connectionRevision;
    if (s.expiresAt <= (long long)(NSDate.date.timeIntervalSince1970 * 1000)) {
      s.archived = YES;
    }
  }
  return self;
}
- (NSString *)sessionId { return _session.sessionId; }

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
  self.title = [@"#" stringByAppendingString:_session.shortId];
  self.navigationItem.subtitle = _session.archived ? @"过期归档 · 只读，不可继续回复" : [NSString stringWithFormat:@"访客会话 · %@", LBRemaining(_session.expiresAt)];
  _table = [UITableView new];
  _table.translatesAutoresizingMaskIntoConstraints = NO;
  _table.backgroundColor = UIColor.clearColor;
  _table.separatorStyle = UITableViewCellSeparatorStyleNone;
  _table.dataSource = self;
  _table.delegate = self;
  _table.rowHeight = UITableViewAutomaticDimension;
  _table.estimatedRowHeight = 60;
  _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  _table.contentInset = UIEdgeInsetsMake(4, 0, 12, 0);
  [_table registerClass:LBBubbleCell.class forCellReuseIdentifier:@"b"];
  if (!_session.archived) [self buildComposer];
  // Resize the actual viewport above the composer. Safe-area insets belong to
  // UIKit; never subtract tab/keyboard heights from them a second time.
  LBInstallContentScrollView(self, _table, _composer.topAnchor);
  UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"number"] menu:
      [UIMenu menuWithChildren:@[ [UIAction actionWithTitle:@"拷贝会话编号" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil
                                                    handler:^(UIAction *a) { UIPasteboard.generalPasteboard.string = self->_session.shortId; }] ]]];
  self.navigationItem.rightBarButtonItem = copy;
  [self load:YES];
  [self loadContact];
}
- (void)loadContact {
  NSUInteger revision = _connectionRevision;
  [LBAPI.shared fetchSessionContact:_session.sessionId done:^(NSDictionary *contact, NSError *error) {
    if (revision != LBAPI.shared.connectionRevision) { [self clearContact]; return; }
    if (error) { [self clearContact]; return; } // Contact metadata never hides saved messages.
    self->_contact = contact;
    NSString *email = [contact[@"email"] isKindOfClass:NSString.class] ? contact[@"email"] : nil;
    if (!email.length) { [self clearContact]; return; }
    [self buildContactHeader:email];
  }];
}
- (void)clearContact {
  _contact = nil;
  _contactHeader = nil;
  if (_visible) _table.tableHeaderView = nil;
}
- (void)buildContactHeader:(NSString *)email {
  UIView *header = [UIView new];
  UIVisualEffectView *glass = [LBTheme glassWithTint:[LBTheme.surface colorWithAlphaComponent:0.20] interactive:NO];
  glass.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:18]];
  [header addSubview:glass];
  UILabel *title = [UILabel new];
  title.text = @"访客填写邮箱 · 仅站长可见";
  title.font = [LBTheme rounded:12 weight:UIFontWeightSemibold];
  title.textColor = LBTheme.muted;
  UILabel *address = [UILabel new];
  address.text = email;
  address.font = [LBTheme mono:14 weight:UIFontWeightMedium];
  address.textColor = LBTheme.ink;
  address.numberOfLines = 0;
  address.lineBreakMode = NSLineBreakByCharWrapping;
  UILabel *status = [UILabel new];
  BOOL enabled = [_contact[@"status"] isEqual:@"enabled"];
  NSString *state = enabled ? @"回复邮件通知已启用" : @"已填写邮箱 · 回复邮件通知已关闭";
  NSString *delivery = _contact[@"delivery"];
  if ([delivery isEqual:@"failed"] || [delivery isEqual:@"bounced"]) state = [state stringByAppendingString:@" · 最近投递失败"];
  status.text = state;
  status.font = [UIFont systemFontOfSize:12]; status.textColor = LBTheme.muted; status.numberOfLines = 0;
  UIButtonConfiguration *config = [UIButtonConfiguration glassButtonConfiguration];
  config.image = [UIImage systemImageNamed:@"doc.on.doc"];
  __weak typeof(self) weakSelf = self;
  UIButton *copy = [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
    typeof(self) self = weakSelf;
    if (self && self->_connectionRevision == LBAPI.shared.connectionRevision) UIPasteboard.generalPasteboard.string = email;
  }]];
  copy.accessibilityLabel = @"复制访客邮箱";
  UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ title, address, status ]];
  text.axis = UILayoutConstraintAxisVertical; text.spacing = 4;
  UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ text, copy ]];
  row.axis = UILayoutConstraintAxisHorizontal; row.alignment = UIStackViewAlignmentCenter; row.spacing = 10;
  row.translatesAutoresizingMaskIntoConstraints = NO;
  [copy.widthAnchor constraintEqualToConstant:36].active = YES;
  [copy.heightAnchor constraintEqualToConstant:36].active = YES;
  [glass.contentView addSubview:row];
  [NSLayoutConstraint activateConstraints:@[
    [glass.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:14],
    [glass.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-14],
    [glass.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],
    [glass.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],
    [row.leadingAnchor constraintEqualToAnchor:glass.contentView.leadingAnchor constant:14],
    [row.trailingAnchor constraintEqualToAnchor:glass.contentView.trailingAnchor constant:-12],
    [row.topAnchor constraintEqualToAnchor:glass.contentView.topAnchor constant:12],
    [row.bottomAnchor constraintEqualToAnchor:glass.contentView.bottomAnchor constant:-12],
  ]];
  _contactHeader = header; _contactHeaderWidth = 0;
  if (_visible) [self sizeContactHeader];
}
- (void)sizeContactHeader {
  if (!_visible || !_contactHeader || _table.bounds.size.width <= 0) return;
  CGFloat width = _table.bounds.size.width;
  if (fabs(_contactHeaderWidth - width) < 0.5) return;
  _contactHeaderWidth = width;
  CGFloat height = [_contactHeader systemLayoutSizeFittingSize:CGSizeMake(width, 0)
      withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
  _contactHeader.frame = CGRectMake(0, 0, width, MAX(80, height));
  _table.tableHeaderView = _contactHeader;
}
- (void)buildComposer {
  _composer = [LBTheme glassWithTint:[LBTheme.surface colorWithAlphaComponent:0.25] interactive:NO];
  _composer.cornerConfiguration = [UICornerConfiguration capsuleConfigurationWithMaximumRadius:26];
  [self.view addSubview:_composer];
  UIView *c = _composer.contentView;
  _input = [UITextView new];
  _input.backgroundColor = UIColor.clearColor;
  _input.font = [UIFont systemFontOfSize:16];
  _input.textColor = LBTheme.ink;
  _input.delegate = self;
  _input.textContainerInset = UIEdgeInsetsMake(10, 4, 10, 4);
  _placeholder = [UILabel new];
  _placeholder.text = @"回复访客…";
  _placeholder.font = _input.font;
  _placeholder.textColor = LBTheme.muted;
  _counter = [UILabel new];
  _counter.font = [LBTheme mono:10 weight:UIFontWeightMedium];
  _counter.textColor = LBTheme.muted;
  UIButtonConfiguration *bc = [UIButtonConfiguration prominentGlassButtonConfiguration];
  bc.image = [UIImage systemImageNamed:@"arrow.up" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightBold]];
  bc.baseBackgroundColor = LBTheme.accent;
  bc.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
  _send = [UIButton buttonWithConfiguration:bc primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [self sendTapped]; }]];
  _send.enabled = NO;

  UIButtonConfiguration *qc = [UIButtonConfiguration glassButtonConfiguration];
  qc.image = [UIImage systemImageNamed:@"sparkles" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold]];
  qc.baseForegroundColor = LBTheme.accent;
  qc.baseBackgroundColor = [LBTheme.accent colorWithAlphaComponent:0.12];
  qc.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
  UIButton *quick = [UIButton buttonWithConfiguration:qc primaryAction:nil];
  quick.showsMenuAsPrimaryAction = YES;
  quick.accessibilityLabel = @"常用短语";
  NSArray *phrases = @[
    @"收到，感谢你的留言！🙌",
    @"已确认该问题，稍后修复上线 🛠️",
    @"欢迎常来交流！☕",
    @"收到，祝你生活愉快 ✨",
    @"好的，没问题～"
  ];
  NSMutableArray *actions = [NSMutableArray array];
  __weak typeof(self) weakOwner = self;
  for (NSString *p in phrases) {
    [actions addObject:[UIAction actionWithTitle:p image:nil identifier:nil handler:^(UIAction *a) {
      typeof(self) owner = weakOwner;
      if (!owner) return;
      owner->_input.text = owner->_input.text.length ? [owner->_input.text stringByAppendingFormat:@" %@", p] : p;
      [owner textViewDidChange:owner->_input];
      [[UIImpactFeedbackGenerator feedbackGeneratorWithStyle:UIImpactFeedbackStyleLight forView:owner->_input] impactOccurred];
    }]];
  }
  quick.menu = [UIMenu menuWithTitle:@"常用快捷回复" children:actions];

  for (UIView *v in @[ quick, _input, _placeholder, _counter, _send ]) { v.translatesAutoresizingMaskIntoConstraints = NO; [c addSubview:v]; }
  _inputH = [_input.heightAnchor constraintEqualToConstant:40];
  [NSLayoutConstraint activateConstraints:@[
    [_composer.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
    [_composer.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
    [_composer.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-8],
    [quick.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:7],
    [quick.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-7],
    [quick.widthAnchor constraintEqualToConstant:38],
    [quick.heightAnchor constraintEqualToConstant:38],
    [_input.leadingAnchor constraintEqualToAnchor:quick.trailingAnchor constant:6],
    [_input.topAnchor constraintEqualToAnchor:c.topAnchor constant:6],
    [_input.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-6], _inputH,
    [_placeholder.leadingAnchor constraintEqualToAnchor:_input.leadingAnchor constant:9],
    [_placeholder.centerYAnchor constraintEqualToAnchor:_input.topAnchor constant:20],
    [_send.leadingAnchor constraintEqualToAnchor:_input.trailingAnchor constant:6],
    [_send.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-7],
    [_send.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-7],
    [_send.widthAnchor constraintEqualToConstant:38],
    [_send.heightAnchor constraintEqualToConstant:38],
    [_counter.centerXAnchor constraintEqualToAnchor:_send.centerXAnchor],
    [_counter.bottomAnchor constraintEqualToAnchor:_send.topAnchor constant:-4],
  ]];
}
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  [self sizeContactHeader];
  BOOL resized = !CGSizeEqualToSize(_lastTableSize, _table.bounds.size)
      || fabs(_lastTopInset - _table.adjustedContentInset.top) > 0.5;
  _lastTableSize = _table.bounds.size;
  _lastTopInset = _table.adjustedContentInset.top;
  if (_visible && !self.transitionCoordinator && (_needsBottomScroll || (resized && _followBottom))) [self scrollToBottom:NO];
}
- (void)scrollToBottom:(BOOL)animated {
  if (!_visible) { _needsBottomScroll = YES; return; }
  if (!_displayMessages.count) return;
  if (!self.viewIfLoaded.window || _table.bounds.size.height <= 0) {
    _needsBottomScroll = YES;
    return;
  }
  _needsBottomScroll = NO;
  [_table layoutIfNeeded];
  [_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:_displayMessages.count - 1 inSection:0]
                atScrollPosition:UITableViewScrollPositionBottom animated:LBShouldAnimate(animated)];
}
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
  if (scrollView != _table || (!_table.dragging && !_table.decelerating)) return;
  CGFloat bottom = MAX(-_table.adjustedContentInset.top,
      _table.contentSize.height - _table.bounds.size.height + _table.adjustedContentInset.bottom);
  _followBottom = bottom - _table.contentOffset.y <= 44;
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  _visible = YES;
  if (_pendingTableUpdate) [self reloadScrolling:NO];
  if (!_contactHeader) _table.tableHeaderView = nil;
  [self sizeContactHeader];
  if (!_session.archived) LBSync.shared.activeSession = _session.sessionId;
  [_poll invalidate];
  if (_connectionRevision != LBAPI.shared.connectionRevision) { [self load:NO]; return; }
  if (_session.archived) { if (_followBottom) [self scrollToBottom:NO]; return; }
  __weak typeof(self) weakSelf = self;
  _poll = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *t) { [weakSelf load:NO]; }];
  if (_followBottom) [self scrollToBottom:NO];
}
- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  _visible = NO;
  if ([LBSync.shared.activeSession isEqualToString:_session.sessionId]) LBSync.shared.activeSession = nil;
  [_poll invalidate];
  _poll = nil;
}

- (void)dealloc { [_poll invalidate]; }

- (void)load:(BOOL)first {
  if (_loading || (UIApplication.sharedApplication.applicationState != UIApplicationStateActive && !first)) return;
  if (_connectionRevision != LBAPI.shared.connectionRevision) {
    [self clearContact];
    [_messages removeAllObjects]; [self reloadScrolling:NO]; [_poll invalidate];
    self.navigationItem.subtitle = @"连接已变更，请返回会话列表";
    _input.editable = NO; _send.enabled = NO;
    return;
  }
  if (!_session.archived && _session.expiresAt <= (long long)(NSDate.date.timeIntervalSince1970 * 1000)) {
    _session.archived = YES;
    self.navigationItem.subtitle = @"过期归档 · 只读，不可继续回复";
    _input.editable = NO; _send.enabled = NO; _placeholder.text = @"归档会话只读";
    [_poll invalidate];
    if ([LBSync.shared.activeSession isEqualToString:_session.sessionId]) LBSync.shared.activeSession = nil;
  }
  _loading = YES;
  void (^completion)(NSArray<LBMessage *> *, NSInteger, NSError *) = ^(NSArray<LBMessage *> *list, NSInteger cursor, NSError *e) {
    self->_loading = NO;
    if (self->_connectionRevision != LBAPI.shared.connectionRevision) { [self load:NO]; return; }
    if (e) {
      self.navigationItem.prompt = e.code == 410 && self->_session.archived ? @"归档不存在或已被删除" : e.localizedDescription;
      if (e.code == 410) { self.navigationItem.subtitle = @"会话已过期，只读"; [self->_poll invalidate]; self->_input.editable = NO; self->_send.enabled = NO; }
      if (!self->_messages.count) {
        __weak typeof(self) weakSelf = self;
        self->_table.backgroundView = LBNotice(@"exclamationmark.bubble", @"读取失败", self.navigationItem.prompt, @"重试", ^{ [weakSelf load:YES]; });
      }
      return;
    }
    if (self->_connectionRevision != LBAPI.shared.connectionRevision) { [self load:NO]; return; }
    self.navigationItem.prompt = nil;
    self->_table.backgroundView = nil;
    if (!list.count) return;
    NSSet *have = [NSSet setWithArray:[self->_messages valueForKey:@"mid"]];
    NSInteger maxUser = 0;
    for (LBMessage *m in list) {
      if (m.fromVisitor) maxUser = MAX(maxUser, m.sequence);
      if (![have containsObject:m.mid]) [self->_messages addObject:m];
      else for (LBMessage *old in self->_messages) if ([old.mid isEqualToString:m.mid]) { old.sequence = m.sequence; old.createdAt = m.createdAt; old.pending = NO; old.failed = NO; }
    }
    [self->_messages sortUsingComparator:^NSComparisonResult(LBMessage *a, LBMessage *b) {
      NSInteger x = a.sequence ?: NSIntegerMax, y = b.sequence ?: NSIntegerMax;
      return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame;
    }];
    self->_cursor = cursor;
    if (self->_session.archived) {
      NSInteger expected = 1;
      for (LBMessage *message in self->_messages) {
        if (message.sequence != expected) { self.navigationItem.prompt = @"部分旧消息在升级前已清理，仅展示仍可恢复的历史"; break; }
        expected = message.sequence + 1;
      }
    }
    if (!self->_session.archived) [LBSync.shared markRead:self->_session.sessionId upTo:maxUser];
    [self reloadScrolling:!first];
  };
  if (_session.archived) [LBAPI.shared fetchArchivedMessages:_session.sessionId after:_cursor done:completion];
  else [LBAPI.shared fetchMessages:_session.sessionId after:_cursor done:completion];
}
- (void)reloadScrolling:(BOOL)animated {
  _pendingTableUpdate = YES;
  if (!_visible || _table.dragging || _table.decelerating) return;
  _pendingTableUpdate = NO;
  _displayMessages = [_messages copy];
  [UIView performWithoutAnimation:^{ [self->_table reloadData]; }];
  if (_followBottom) [self scrollToBottom:animated];
}

#pragma mark Table
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
  if (!decelerate && _pendingTableUpdate) [self reloadScrolling:NO];
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { if (_pendingTableUpdate) [self reloadScrolling:NO]; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return _displayMessages.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
  LBBubbleCell *c = [t dequeueReusableCellWithIdentifier:@"b" forIndexPath:ip];
  LBMessage *m = _displayMessages[ip.row];
  BOOL isVisitor = [m fromVisitor];
  BOOL isFollowup = NO;
  if (ip.row > 0) {
    LBMessage *prev = _displayMessages[ip.row - 1];
    if ([prev fromVisitor] == isVisitor && (m.createdAt - prev.createdAt < 2 * 60 * 1000)) {
      isFollowup = YES;
    }
  }
  // Show a timestamp at the start and after a five-minute gap.
  BOOL show = ip.row == 0 || m.createdAt - _displayMessages[ip.row - 1].createdAt > 5 * 60 * 1000;
  [c apply:m showTime:show isFollowup:isFollowup];
  return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
  LBMessage *m = _displayMessages[ip.row];
  if (m.failed && !_sending) [self deliver:m];
}

#pragma mark Compose
- (void)textViewDidChange:(UITextView *)tv {
  NSString *t = [tv.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  _placeholder.hidden = tv.text.length > 0;
  _send.enabled = !_session.archived && _connectionRevision == LBAPI.shared.connectionRevision && _session.expiresAt > (long long)(NSDate.date.timeIntervalSince1970 * 1000) && t.length > 0 && tv.text.length <= 500 && !_sending;
  NSInteger left = 500 - (NSInteger)tv.text.length;
  _counter.text = left < 60 ? [NSString stringWithFormat:@"%ld", (long)left] : @"";
  _counter.textColor = left < 0 ? UIColor.systemRedColor : LBTheme.muted;
  CGFloat h = MIN(140, MAX(40, [tv sizeThatFits:CGSizeMake(tv.bounds.size.width, CGFLOAT_MAX)].height));
  if (h != _inputH.constant) {
    _inputH.constant = h;
    tv.scrollEnabled = h >= 140;
    if (UIAccessibilityIsReduceMotionEnabled()) { [self.view layoutIfNeeded]; }
    else [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:0
                          animations:^{ [self.view layoutIfNeeded]; } completion:nil];
  }
}
- (void)sendTapped {
  NSString *t = [_input.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (_session.archived || _connectionRevision != LBAPI.shared.connectionRevision || _session.expiresAt <= (long long)(NSDate.date.timeIntervalSince1970 * 1000)) { [self load:NO]; return; }
  if (!t.length || t.length > 500 || _sending) return;
  LBMessage *m = [LBMessage new];
  m.mid = [LBAPI randomHex:16];
  m.sender = @"author";
  m.text = t;
  m.createdAt = (long long)(NSDate.date.timeIntervalSince1970 * 1000);
  [_messages addObject:m];
  _input.text = @"";
  [self textViewDidChange:_input];
  [[UIImpactFeedbackGenerator feedbackGeneratorWithStyle:UIImpactFeedbackStyleSoft forView:_send] impactOccurred];
  [self deliver:m];
}
/// Retries reuse the same message ID, so the server deduplicates them.
- (void)deliver:(LBMessage *)m {
  if (_session.archived || _connectionRevision != LBAPI.shared.connectionRevision || _session.expiresAt <= (long long)(NSDate.date.timeIntervalSince1970 * 1000)) { [self load:NO]; return; }
  _followBottom = YES;
  _sending = YES;
  m.pending = YES;
  m.failed = NO;
  [self reloadScrolling:YES];
  [LBAPI.shared reply:_session.sessionId messageId:m.mid text:m.text done:^(LBMessage *saved, NSError *e) {
    self->_sending = NO;
    m.pending = NO;
    if (e) {
      m.failed = YES;
      self.navigationItem.prompt = e.localizedDescription;
      [[UINotificationFeedbackGenerator feedbackGeneratorForView:self.view] notificationOccurred:UINotificationFeedbackTypeError];
    } else {
      self.navigationItem.prompt = nil;
      m.sequence = saved.sequence;
      m.createdAt = saved.createdAt;
      [self load:NO];
      [LBSync.shared refresh:nil];
    }
    [self textViewDidChange:self->_input];
    [self reloadScrolling:NO];
  }];
}
@end

#import "LBLayout.h"
#import <objc/runtime.h>

// Monitor-only selectors stay private; LB.h remains the public data contract.
@interface LBSiteData (DashboardMonitor)
- (void)monitorDeploy;
- (void)refreshDeployOnActivation;
- (BOOL)wantsFastDeployChecks;
- (NSDate *)certificateCheckedAt:(NSString *)host;
- (NSDate *)deployCheckedAt;
@end

@interface LBDashboardViewController () <UIScrollViewDelegate>
@end

@implementation LBDashboardViewController {
  UIScrollView *_scroll;
  UIStackView *_stack;
  NSTimer *_tick, *_pendingTick;
  UILabel *_prompt, *_name, *_subtitle, *_deployChip, *_commitMessage;
  NSMutableArray<UILabel *> *_statValues, *_statDetails;
  NSMutableArray<UIImageView *> *_statIcons;
  NSMutableArray<UIVisualEffectView *> *_statCards;
  UIStackView *_commitRow, *_headErrorRow, *_buildRow, *_heartbeatRow, *_certStack;
  UIVisualEffectView *_deployCard, *_setupNotice;
  NSMutableDictionary<NSString *, UIStackView *> *_certRows;
  NSArray<NSString *> *_certHosts;
  NSString *_envText, *_buildDateText;
  NSDate *_buildDate;
  NSDictionary *_env;
  NSArray<NSNumber *> *_friendIndexes;
  NSInteger _enabledFriends;
  NSDate *_launchDate;
  BOOL _visible, _transitioning, _needsUpdate, _updateScheduled;
  BOOL _refreshInFlight, _refreshNeedsEnding, _refreshSettling;
  CFTimeInterval _settleNotBefore;
  CGPoint _settleOffset;
  UIEdgeInsets _settleInset;
  UIView *_navHeaderView;
  UILabel *_navTitleLabel;
  UIStackView *_navSubtitleStack;
  UIImageView *_navSyncIcon;
  UILabel *_navSubtitleLabel;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"仪表盘";

  // Header Title View (Consistent typography with Posts and Memos tabs)
  _navHeaderView = [UIView new];
  _navTitleLabel = [UILabel new];
  _navTitleLabel.text = @"仪表盘";
  _navTitleLabel.font = [LBTheme rounded:18 weight:UIFontWeightBold];
  _navTitleLabel.textColor = LBTheme.ink;

  _navSyncIcon = [UIImageView new];
  _navSyncIcon.contentMode = UIViewContentModeScaleAspectFit;
  _navSyncIcon.tintColor = [UIColor colorWithRed:0.1 green:0.75 blue:0.4 alpha:1.0];
  _navSyncIcon.image = [UIImage systemImageNamed:@"gauge.with.dots.needle.67percent"];
  [_navSyncIcon.widthAnchor constraintEqualToConstant:12].active = YES;
  [_navSyncIcon.heightAnchor constraintEqualToConstant:12].active = YES;

  _navSubtitleLabel = [UILabel new];
  _navSubtitleLabel.font = [LBTheme rounded:12 weight:UIFontWeightMedium];
  _navSubtitleLabel.textColor = LBTheme.muted;
  NSString *siteHost = [NSURL URLWithString:LBStore.siteURL].host ?: @"huowenlong.com";
  _navSubtitleLabel.text = [NSString stringWithFormat:@"站点运行中 · %@", siteHost];

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

  _scroll = [UIScrollView new];
  _scroll.delegate = self;
  _scroll.showsVerticalScrollIndicator = NO;
  _scroll.showsHorizontalScrollIndicator = NO;
  LBInstallContentScrollView(self, _scroll, nil);
  UIRefreshControl *rc = [UIRefreshControl new];
  [rc addTarget:self action:@selector(pull:) forControlEvents:UIControlEventValueChanged];
  _scroll.refreshControl = rc;
  _stack = [UIStackView new];
  _stack.axis = UILayoutConstraintAxisVertical;
  _stack.spacing = 14;
  _stack.translatesAutoresizingMaskIntoConstraints = NO;
  [_scroll addSubview:_stack];
  [NSLayoutConstraint activateConstraints:@[
    [_stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:8],
    [_stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-28],
    [_stack.leadingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.leadingAnchor constant:16],
    [_stack.trailingAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.trailingAnchor constant:-16],
  ]];
  UIBarButtonItem *open = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"safari"] style:UIBarButtonItemStylePlain
                                                          target:self action:@selector(openSite)];
  UIBarButtonItem *gear = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"] style:UIBarButtonItemStylePlain
                                                          target:self action:@selector(openSettings)];
  self.navigationItem.rightBarButtonItems = @[ gear, open ];
  [self buildDashboard];
  for (NSString *n in @[ LBSiteDataDidChange, LBSyncDidChange ])
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(requestUpdate) name:n object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(requestUpdate) name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
  for (NSString *n in @[ UIApplicationDidBecomeActiveNotification, UISceneDidActivateNotification ])
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive) name:n object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resignedActive:) name:UIApplicationWillResignActiveNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resignedActive:) name:UISceneWillDeactivateNotification object:nil];
  [self requestUpdate];
  [LBSiteData.shared refreshAll:nil];
}
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  _transitioning = YES;
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  _visible = YES;
  _transitioning = NO;
  [self becameActive];
}
- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  _visible = NO;
  _transitioning = YES;
  [self suspendUpdates];
}
- (BOOL)isActiveDashboard {
  return _visible && !_transitioning && self.viewIfLoaded.window &&
    UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
    self.viewIfLoaded.window.windowScene.activationState == UISceneActivationStateForegroundActive;
}
- (void)suspendUpdates {
  [_deployChip.layer removeAnimationForKey:@"deployBreathe"];
  _deployChip.layer.transform = CATransform3DIdentity;
  [_tick invalidate]; _tick = nil;
  [_pendingTick invalidate]; _pendingTick = nil;
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushPendingUpdates) object:nil];
  _updateScheduled = NO;
}
- (void)becameActive {
  if (![self isActiveDashboard]) return;
  if (!_tick) {
    __weak typeof(self) w = self;
    _tick = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
      (void)timer;
      LBDashboardViewController *s = w;
      if (!s || ![s isActiveDashboard]) return;
      [s requestUpdate];
      if (s->_scroll.dragging || s->_scroll.decelerating || s->_refreshInFlight || s->_refreshSettling) return;
      BOOL pending = NO;
      [LBSiteData.shared deployState:nil pending:&pending];
      if (pending) [LBSiteData.shared refreshDeploy:nil];
      else [LBSiteData.shared monitorDeploy];
    }];
  }
  if (!_pendingTick) {
    __weak typeof(self) w = self;
    // Default run-loop mode deliberately pauses during touch tracking.
    _pendingTick = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) {
      (void)timer;
      LBDashboardViewController *s = w;
      if (!s || ![s isActiveDashboard] || s->_scroll.tracking || s->_scroll.dragging ||
          s->_scroll.decelerating || s->_refreshInFlight || s->_refreshSettling) return;
      if ([LBSiteData.shared wantsFastDeployChecks]) [LBSiteData.shared monitorDeploy];
    }];
  }
  [LBSiteData.shared refreshDeployOnActivation];
  [self requestUpdate];
}
- (void)resignedActive:(NSNotification *)note {
  if ([note.object isKindOfClass:UIScene.class] && note.object != self.viewIfLoaded.window.windowScene) return;
  [self suspendUpdates];
}
- (void)dealloc {
  [_tick invalidate];
  [_pendingTick invalidate];
  [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)pull:(UIRefreshControl *)rc {
  (void)rc;
  if (_refreshInFlight) return;
  _refreshInFlight = YES;
  [LBSync.shared refresh:nil];
  __weak typeof(self) w = self;
  [LBSiteData.shared refreshAll:^{
    LBDashboardViewController *s = w;
    if (!s) return;
    s->_refreshInFlight = NO;
    s->_refreshNeedsEnding = YES;
    [s requestUpdate];
  }];
}
// One default-mode job absorbs notification bursts. Blocked jobs stay dirty;
// lifecycle/scroll callbacks resume them, rather than polling a hidden page.
- (void)requestUpdate {
  if (!NSThread.isMainThread) {
    __weak typeof(self) w = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [w requestUpdate]; });
    return;
  }
  _needsUpdate = YES;
  [self scheduleUpdate];
}
- (void)scheduleUpdate {
  if (_updateScheduled || ![self isActiveDashboard]) return;
  _updateScheduled = YES;
  [self performSelector:@selector(flushPendingUpdates) withObject:nil afterDelay:0.1
               inModes:@[ NSDefaultRunLoopMode ]];
}
- (void)flushPendingUpdates {
  _updateScheduled = NO;
  if (!_needsUpdate || ![self isActiveDashboard] || _scroll.tracking || _scroll.dragging ||
      _scroll.decelerating || _refreshInFlight) return;
  id<UIViewControllerTransitionCoordinator> transition = self.transitionCoordinator ?: self.navigationController.transitionCoordinator;
  if (transition) {
    __weak typeof(self) w = self;
    BOOL registered = [transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
      (void)context;
      [w scheduleUpdate];
    }];
    if (!registered) [self scheduleUpdate];
    return;
  }
  if (_refreshNeedsEnding) {
    _refreshNeedsEnding = NO;
    _refreshSettling = YES;
    _settleNotBefore = CACurrentMediaTime() + (UIAccessibilityIsReduceMotionEnabled() ? 0.1 : 0.5);
    _settleOffset = _scroll.contentOffset;
    _settleInset = _scroll.adjustedContentInset;
    [_scroll.refreshControl endRefreshing];
  }
  if (_refreshSettling) {
    // endRefreshing has no completion API. Wait for its inset/offset animation
    // to settle, including the presentation layer, before touching stack values.
    CALayer *presentation = _scroll.layer.presentationLayer;
    BOOL stable = CGPointEqualToPoint(_settleOffset, _scroll.contentOffset) &&
      UIEdgeInsetsEqualToEdgeInsets(_settleInset, _scroll.adjustedContentInset) &&
      (!presentation || CGPointEqualToPoint(presentation.bounds.origin, _scroll.layer.bounds.origin));
    _settleOffset = _scroll.contentOffset;
    _settleInset = _scroll.adjustedContentInset;
    if (!stable || CACurrentMediaTime() < _settleNotBefore) { [self scheduleUpdate]; return; }
    _refreshSettling = NO;
  }
  if (_scroll.refreshControl.refreshing) return;
  _needsUpdate = NO;
  [UIView performWithoutAnimation:^{ [self updateValues]; }];
}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
  (void)scrollView;
  if (!decelerate) [self scheduleUpdate];
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
  (void)scrollView;
  [self scheduleUpdate];
}
- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
  (void)scrollView;
  [self scheduleUpdate];
}
- (void)openSite { LBOpenURL(self, [NSURL URLWithString:LBStore.siteURL]); }
- (void)openSettings { LBPresentSettings(self); }

#pragma mark Building blocks
- (UIVisualEffectView *)card:(UIView *)content tint:(UIColor *)tint radius:(CGFloat)r {
  UIVisualEffectView *g = [LBTheme glassWithTint:tint ?: [LBTheme.surface colorWithAlphaComponent:0.3] interactive:NO];
  g.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:r]];
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
- (UILabel *)label:(NSString *)t font:(UIFont *)f color:(UIColor *)c {
  UILabel *l = [UILabel new];
  l.text = t; l.font = f; l.textColor = c; l.numberOfLines = 0;
  return l;
}
- (UIView *)sectionTitle:(NSString *)t {
  UILabel *l = [self label:t font:[LBTheme rounded:13 weight:UIFontWeightSemibold] color:LBTheme.muted];
  UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[ l ]];
  s.layoutMargins = UIEdgeInsetsMake(8, 6, 0, 6);
  s.layoutMarginsRelativeArrangement = YES;
  return s;
}
- (UIView *)stat:(NSString *)icon value:(NSString *)value title:(NSString *)title detail:(NSString *)detail
           color:(UIColor *)color action:(void (^)(void))action {
  UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icon]];
  iv.tintColor = color;
  iv.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
  UILabel *v = [self label:value font:[LBTheme rounded:30 weight:UIFontWeightBold] color:LBTheme.ink];
  v.adjustsFontSizeToFitWidth = YES;
  v.minimumScaleFactor = 0.5;
  v.numberOfLines = 1;
  UILabel *t = [self label:title font:[LBTheme rounded:13 weight:UIFontWeightSemibold] color:LBTheme.ink];
  UILabel *d = [self label:detail font:[UIFont systemFontOfSize:11] color:LBTheme.muted];
  d.numberOfLines = 2;
  UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[ iv, v, t, d ]];
  s.axis = UILayoutConstraintAxisVertical;
  s.alignment = UIStackViewAlignmentLeading;
  s.spacing = 2;
  [s setCustomSpacing:8 afterView:iv];
  UIVisualEffectView *g = [self card:s tint:[color colorWithAlphaComponent:0.10] radius:24];
  if (action) {
    UIGlassEffect *e = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    e.interactive = YES;
    e.tintColor = [color colorWithAlphaComponent:0.10];
    g.effect = e;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(statTapped:)];
    [g addGestureRecognizer:tap];
    objc_setAssociatedObject(g, "action", action, OBJC_ASSOCIATION_COPY_NONATOMIC);
  }
  [_statValues addObject:v];
  [_statDetails addObject:d];
  [_statIcons addObject:iv];
  [_statCards addObject:g];
  return g;
}
- (void)statTapped:(UITapGestureRecognizer *)t {
  UIView *v = t.view;
  if (!v) return;
  if (LBShouldAnimate(YES)) {
    UIImpactFeedbackGenerator *f = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [f impactOccurredWithIntensity:0.75];
    [UIView animateWithDuration:0.10 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
      v.transform = CGAffineTransformMakeScale(0.95, 0.95);
    } completion:^(BOOL finished) {
      [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.65 initialSpringVelocity:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        v.transform = CGAffineTransformIdentity;
      } completion:^(BOOL fin) {
        void (^a)(void) = objc_getAssociatedObject(v, "action");
        if (a) a();
      }];
    }];
  } else {
    void (^a)(void) = objc_getAssociatedObject(v, "action");
    if (a) a();
  }
}
- (void)updateDeployPulse:(UIColor *)color {
  CALayer *l = _deployChip.layer;
  if (!LBShouldAnimate(YES) || [color isEqual:LBTheme.muted]) {
    [l removeAnimationForKey:@"deployBreathe"];
    l.transform = CATransform3DIdentity;
    return;
  }
  if (![l animationForKey:@"deployBreathe"]) {
    CABasicAnimation *breathe = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    breathe.fromValue = @(0.98);
    breathe.toValue = @(1.035);
    breathe.duration = 2.4;
    breathe.autoreverses = YES;
    breathe.repeatCount = HUGE_VALF;
    breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [l addAnimation:breathe forKey:@"deployBreathe"];
  }
}
- (void)selectTab:(NSString *)identifier {
  UITabBarController *tbc = self.tabBarController;
  for (UITab *tab in tbc.tabs) if ([tab.identifier isEqualToString:identifier]) tbc.selectedTab = tab;
}
- (UIView *)row:(NSArray<UIView *> *)views {
  UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
  s.axis = UILayoutConstraintAxisHorizontal;
  s.distribution = UIStackViewDistributionFillEqually;
  s.alignment = UIStackViewAlignmentFill;
  s.spacing = 12;
  return s;
}
- (UIView *)line:(NSString *)icon color:(UIColor *)color title:(NSString *)title detail:(NSString *)detail {
  UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icon]];
  iv.tintColor = color;
  objc_setAssociatedObject(iv, "symbol", icon, OBJC_ASSOCIATION_COPY_NONATOMIC);
  iv.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
  [iv setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  [iv.widthAnchor constraintEqualToConstant:22].active = YES;
  UILabel *t = [self label:title font:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium] color:LBTheme.ink];
  UILabel *d = [self label:detail font:[LBTheme rounded:13 weight:UIFontWeightMedium] color:color];
  d.textAlignment = NSTextAlignmentRight;
  [d setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
  [t setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[ iv, t, d ]];
  s.spacing = 10;
  s.alignment = UIStackViewAlignmentFirstBaseline;
  return s;
}


// Certificates do not compete for one baseline: domain gets full text width,
// and status / verification time are separate, readable secondary lines.
- (UIStackView *)certificateRow:(NSString *)host {
  UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"lock"]];
  icon.contentMode = UIViewContentModeScaleAspectFit; icon.tintColor = LBTheme.muted;
  [icon.widthAnchor constraintEqualToConstant:22].active = YES;
  [icon.heightAnchor constraintEqualToConstant:24].active = YES;
  UILabel *domain = [self label:host font:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold] color:LBTheme.ink];
  domain.lineBreakMode = NSLineBreakByCharWrapping;
  UILabel *status = [self label:@"  检查中…  " font:[LBTheme rounded:11 weight:UIFontWeightSemibold] color:LBTheme.muted];
  status.textAlignment = NSTextAlignmentCenter;
  status.layer.cornerRadius = 9;
  status.layer.cornerCurve = kCACornerCurveContinuous;
  status.layer.borderWidth = 0.5;
  status.clipsToBounds = YES;
  [status.heightAnchor constraintEqualToConstant:20].active = YES;
  [status setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  [status setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  UILabel *checked = [self label:@"尚未核验" font:[UIFont systemFontOfSize:11] color:LBTheme.muted];
  UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[domain, status, checked]];
  text.axis = UILayoutConstraintAxisVertical; text.spacing = 4; // Compatible text reference
  (void)text;

  UIStackView *leftText = [[UIStackView alloc] initWithArrangedSubviews:@[domain, checked]];
  leftText.axis = UILayoutConstraintAxisVertical; leftText.spacing = 3;
  UIStackView *contentRow = [[UIStackView alloc] initWithArrangedSubviews:@[leftText, status]];
  contentRow.axis = UILayoutConstraintAxisHorizontal;
  contentRow.alignment = UIStackViewAlignmentCenter;
  contentRow.spacing = 8;

  UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, contentRow]];
  row.alignment = UIStackViewAlignmentTop; row.spacing = 12;
  objc_setAssociatedObject(row, "certIcon", icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(row, "certStatus", status, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(row, "certChecked", checked, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return row;
}
- (void)updateCertificateRow:(UIStackView *)row icon:(NSString *)symbol color:(UIColor *)color detail:(NSString *)detail {
  UIImageView *icon = objc_getAssociatedObject(row, "certIcon");
  UILabel *status = objc_getAssociatedObject(row, "certStatus");
  UILabel *checked = objc_getAssociatedObject(row, "certChecked");
  NSRange separator = [detail rangeOfString:@" · "];
  NSString *rawPrimary = separator.location == NSNotFound ? detail : [detail substringToIndex:separator.location];
  NSString *primary = [NSString stringWithFormat:@"  %@  ", rawPrimary];
  NSString *secondary = separator.location == NSNotFound ? @"" : [detail substringFromIndex:NSMaxRange(separator)];
  [self setText:primary label:status]; [self setText:secondary label:checked];
  checked.hidden = !secondary.length;
  if (![icon.tintColor isEqual:color]) { icon.tintColor = color; }
  status.textColor = color;
  status.backgroundColor = [color colorWithAlphaComponent:0.14];
  status.layer.borderColor = [color colorWithAlphaComponent:0.32].CGColor;
  if (![objc_getAssociatedObject(icon, "symbol") isEqual:symbol]) {
    icon.image = [UIImage systemImageNamed:symbol]; objc_setAssociatedObject(icon, "symbol", symbol, OBJC_ASSOCIATION_COPY_NONATOMIC);
  }
}

#pragma mark Stable hierarchy
- (void)buildDashboard {
  _statValues = [NSMutableArray array]; _statDetails = [NSMutableArray array];
  _statIcons = [NSMutableArray array]; _statCards = [NSMutableArray array];
  _certRows = [NSMutableDictionary dictionary];
  _prompt = [self label:@"" font:[LBTheme mono:12 weight:UIFontWeightMedium] color:LBTheme.accent];
  _name = [self label:@"longBlog" font:[LBTheme rounded:30 weight:UIFontWeightHeavy] color:LBTheme.ink];
  _subtitle = [self label:@"" font:[LBTheme mono:13 weight:UIFontWeightRegular] color:LBTheme.muted];
  _deployChip = LBChip(@"", LBTheme.muted);
  UIStackView *chipRow = [[UIStackView alloc] initWithArrangedSubviews:@[ _deployChip, [UIView new] ]];
  UIStackView *hero = [[UIStackView alloc] initWithArrangedSubviews:@[ _prompt, _name, _subtitle, chipRow ]];
  hero.axis = UILayoutConstraintAxisVertical; hero.spacing = 4;
  [hero setCustomSpacing:12 afterView:_subtitle];
  [_stack addArrangedSubview:[self card:hero tint:LBTheme.accentSoft radius:30]];
  __weak typeof(self) w = self;
  [_stack addArrangedSubview:[self row:@[
    [self stat:@"doc.richtext" value:@"…" title:@"文章" detail:@"" color:LBTheme.accent action:^{ [w selectTab:@"posts"]; }],
    [self stat:@"text.bubble" value:@"…" title:@"公开说说" detail:@"" color:UIColor.systemTealColor action:^{ [w selectTab:@"memos"]; }],
  ]]];
  [_stack addArrangedSubview:[self row:@[
    [self stat:@"apple.terminal" value:@"—" title:@"终端留言" detail:@"" color:UIColor.systemIndigoColor action:^{ [w selectTab:@"inbox"]; }],
    [self stat:@"link" value:@"—" title:@"友链" detail:@"" color:UIColor.systemPinkColor action:^{ [w selectTab:@"config"]; }],
  ]]];
  [_stack addArrangedSubview:[self sectionTitle:@"部署"]];
  _commitRow = (UIStackView *)[self line:@"arrow.triangle.branch" color:LBTheme.ink title:@"最新提交" detail:@""];
  _commitMessage = [self label:@"" font:[UIFont systemFontOfSize:13] color:LBTheme.muted];
  _commitMessage.numberOfLines = 2;
  _headErrorRow = (UIStackView *)[self line:@"exclamationmark.triangle" color:UIColor.systemRedColor title:@"GitHub" detail:@""];
  _buildRow = (UIStackView *)[self line:@"shippingbox" color:LBTheme.muted title:@"线上构建" detail:@"未知"];
  _heartbeatRow = (UIStackView *)[self line:@"arrow.triangle.2.circlepath" color:LBTheme.muted title:@"说说镜像心跳" detail:@""];
  _commitRow.hidden = YES; _commitMessage.hidden = YES;
  _headErrorRow.hidden = YES; _heartbeatRow.hidden = YES;
  UIStackView *deployStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _commitRow, _commitMessage, _headErrorRow, _buildRow, _heartbeatRow ]];
  deployStack.axis = UILayoutConstraintAxisVertical; deployStack.spacing = 10;
  _deployCard = [self card:deployStack tint:nil radius:24];
  [_deployCard addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openCommit)]];
  [_stack addArrangedSubview:_deployCard];
  [_stack addArrangedSubview:[self sectionTitle:@"HTTPS 证书"]];
  _certStack = [UIStackView new];
  _certStack.axis = UILayoutConstraintAxisVertical; _certStack.spacing = 20;
  [_stack addArrangedSubview:[self card:_certStack tint:nil radius:24]];
  UIView *notice = LBNotice(@"key.horizontal", @"连接 GitHub 解锁更多", @"填入 GitHub 令牌后可查看文章、部署状态，并在 App 里修改站点配置。",
                           @"去设置", ^{ [w openSettings]; });
  _setupNotice = [self card:notice tint:LBTheme.accentSoft radius:28];
  _setupNotice.hidden = LBGitHub.shared.configured;
  [_stack addArrangedSubview:_setupNotice];
}
// Certificate configuration is the only variable-length section. Reconcile it
// only when hosts change; ordinary expiry/error notifications reuse every row.
- (void)reconcileCertificateHosts {
  NSArray<NSString *> *hosts = LBStore.certHosts;
  if ([_certHosts isEqualToArray:hosts]) return;
  for (NSString *host in _certHosts) {
    if ([hosts containsObject:host]) continue;
    [_certRows[host] removeFromSuperview];
    [_certRows removeObjectForKey:host];
  }
  for (NSUInteger i = 0; i < hosts.count; i++) {
    NSString *host = hosts[i];
    UIStackView *row = _certRows[host];
    if (!row) {
      row = [self certificateRow:host];
      _certRows[host] = row;
    }
    if (i >= _certStack.arrangedSubviews.count || _certStack.arrangedSubviews[i] != row) {
      [_certStack removeArrangedSubview:row];
      [_certStack insertArrangedSubview:row atIndex:i];
    }
  }
  _certHosts = [hosts copy];
}
#pragma mark Value updates
- (void)setText:(NSString *)text label:(UILabel *)label {
  if (![label.text isEqualToString:text]) label.text = text;
}
- (void)updateLine:(UIStackView *)row icon:(NSString *)icon color:(UIColor *)color detail:(NSString *)detail {
  UIImageView *iv = (UIImageView *)row.arrangedSubviews[0];
  UILabel *label = (UILabel *)row.arrangedSubviews[2];
  [self setText:detail label:label];
  if (![iv.tintColor isEqual:color]) { iv.tintColor = color; label.textColor = color; }
  if (![objc_getAssociatedObject(iv, "symbol") isEqualToString:icon]) {
    iv.image = [UIImage systemImageNamed:icon];
    objc_setAssociatedObject(iv, "symbol", icon, OBJC_ASSOCIATION_COPY_NONATOMIC);
  }
}
- (void)updateStat:(NSUInteger)index value:(NSString *)value detail:(NSString *)detail {
  [self setText:value label:_statValues[index]];
  [self setText:detail label:_statDetails[index]];
}
- (void)updateEnvCache:(LBSiteData *)data {
  // Content, not just SHA: didCommitEnv deliberately clears envSha, and reset
  // clears envText. Retain only parsed values/indexes, not the editable parser.
  NSString *text = data.envText;
  if (_envText == text || [_envText isEqualToString:text]) return;
  _envText = [text copy];
  LBEnvFile *file = text ? [LBEnvFile parse:text] : nil;
  _env = [file values];
  _friendIndexes = [file friendIndexes];
  _enabledFriends = 0;
  for (NSNumber *i in _friendIndexes) {
    NSString *v = _env[[NSString stringWithFormat:@"PUBLIC_FRIEND_%@_ENABLED", i]] ?: @"";
    if (![[v lowercaseString] isEqualToString:@"false"]) _enabledFriends++;
  }
  NSString *launch = _env[@"PUBLIC_SITE_LAUNCH_DATE"];
  _launchDate = launch.length ? [[NSISO8601DateFormatter new] dateFromString:launch] : nil;
}
- (void)updateValues {
  LBSiteData *d = LBSiteData.shared;
  [self updateEnvCache:d];
  NSString *host = [NSURL URLWithString:LBStore.siteURL].host ?: @"huowenlong.com";
  NSString *days = _launchDate ? [NSString stringWithFormat:@"已运行 %ld 天", (long)([NSDate.date timeIntervalSinceDate:_launchDate] / 86400)] : @"";
  [self setText:[NSString stringWithFormat:@"~/%@ $ status", host] label:_prompt];
  [self setText:_env[@"PUBLIC_SITE_TITLE"] ?: @"longBlog" label:_name];
  [self setText:days.length ? [NSString stringWithFormat:@"%@ · %@", host, days] : host label:_subtitle];
  UIColor *deployColor = LBTheme.muted;
  NSString *deploy = [d deployState:&deployColor pending:NULL];
  [self setText:[NSString stringWithFormat:@"  ● %@  ", deploy] label:_deployChip];
  if (![_deployChip.textColor isEqual:deployColor]) {
    _deployChip.textColor = deployColor;
    _deployChip.backgroundColor = [deployColor colorWithAlphaComponent:0.14];
    _deployChip.layer.borderColor = [deployColor colorWithAlphaComponent:0.35].CGColor;
    [self updateDeployPulse:deployColor];
  }
  // Stats
  NSArray *posts = d.posts, *memos = d.memos;
  NSString *postsValue = posts ? [NSString stringWithFormat:@"%lu", (unsigned long)posts.count] : (LBGitHub.shared.configured ? @"…" : @"—");
  NSString *postsDetail = @"需 GitHub 令牌";
  if (posts.count) postsDetail = [NSString stringWithFormat:@"最近：%@", LBRelativeTime([[posts valueForKeyPath:@"@max.publishedAt"] longLongValue])];
  else if (d.errors[@"posts"]) postsDetail = d.errors[@"posts"].localizedDescription;
  else if (LBGitHub.shared.configured) postsDetail = @"加载中";
  NSString *memosValue = memos ? [NSString stringWithFormat:@"%lu", (unsigned long)memos.count] : @"…";
  NSString *memosDetail = d.errors[@"memos"] ? d.errors[@"memos"].localizedDescription : @"公开说说";
  if (memos.count) {
    long long ts = 0;
    for (NSDictionary *memo in memos) ts = MAX(ts, [memo[@"displayTs"] longLongValue] ?: [memo[@"createdTs"] longLongValue]);
    memosDetail = [NSString stringWithFormat:@"最近：%@", LBRelativeTime(ts * 1000)];
  }
  [self updateStat:0 value:postsValue detail:postsDetail];
  [self updateStat:1 value:memosValue detail:memosDetail];
  NSInteger unread = [LBSync.shared unreadCount];
  NSUInteger live = LBSync.shared.sessions.count;
  [self updateStat:2 value:LBAPI.shared.configured ? [NSString stringWithFormat:@"%lu", (unsigned long)live] : @"—"
             detail:!LBAPI.shared.configured ? @"未连接" : unread ? [NSString stringWithFormat:@"%ld 个未读", (long)unread] : @"进行中的会话"];
  UIColor *inboxColor = unread ? UIColor.systemRedColor : UIColor.systemIndigoColor;
  if (![_statIcons[2].tintColor isEqual:inboxColor]) {
    _statIcons[2].tintColor = inboxColor;
    UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
    effect.interactive = YES; effect.tintColor = [inboxColor colorWithAlphaComponent:0.10];
    _statCards[2].effect = effect;
  }
  [self updateStat:3 value:_friendIndexes ? [NSString stringWithFormat:@"%ld", (long)_enabledFriends] : @"—"
             detail:_friendIndexes ? [NSString stringWithFormat:@"共 %lu 个，%ld 个展示", (unsigned long)_friendIndexes.count, (long)_enabledFriends] : @"需 GitHub 令牌"];

  // Optional deployment rows remain installed, even while hidden.
  _commitRow.hidden = !d.head;
  _commitMessage.hidden = !d.head;
  _headErrorRow.hidden = !d.errors[@"head"];
  if (d.head) {
    [self updateLine:_commitRow icon:@"arrow.triangle.branch" color:LBTheme.ink
              detail:[d.head[@"sha"] substringToIndex:MIN(7, [d.head[@"sha"] length])] ?: @""];
    [self setText:[d.head[@"message"] componentsSeparatedByString:@"\n"].firstObject ?: @"" label:_commitMessage];
  }
  if (d.errors[@"head"]) {
    [self updateLine:_headErrorRow icon:@"exclamationmark.triangle" color:UIColor.systemRedColor detail:d.errors[@"head"].localizedDescription];
  }
  _deployCard.userInteractionEnabled = d.head[@"url"] != nil;
  NSString *builtAt = [d.build[@"builtAt"] isKindOfClass:NSString.class] ? d.build[@"builtAt"] : nil;
  if (_buildDateText != builtAt && ![_buildDateText isEqualToString:builtAt]) {
    _buildDateText = [builtAt copy];
    _buildDate = builtAt ? [[NSISO8601DateFormatter new] dateFromString:[builtAt stringByReplacingOccurrencesOfString:@"\\.\\d+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, builtAt.length)]] : nil;
  }
  NSDate *bd = _buildDate;
  NSString *buildDetail = bd ? LBRelativeTime((long long)(bd.timeIntervalSince1970 * 1000)) : @"未知";
  NSDate *deployChecked = [d deployCheckedAt];
  if (deployChecked) buildDetail = [buildDetail stringByAppendingFormat:@" · 核验%@", LBRelativeTime((long long)(deployChecked.timeIntervalSince1970 * 1000))];
  [self updateLine:_buildRow icon:@"shippingbox" color:deployColor detail:buildDetail];
  _heartbeatRow.hidden = !d.memosVersion[@"checkedAt"];
  if (d.memosVersion[@"checkedAt"]) {
    long long ck = [d.memosVersion[@"checkedAt"] longLongValue];
    BOOL stale = NSDate.date.timeIntervalSince1970 * 1000 - ck > 10 * 60 * 1000;
    [self updateLine:_heartbeatRow icon:@"arrow.triangle.2.circlepath" color:stale ? UIColor.systemOrangeColor : UIColor.systemGreenColor
              detail:stale ? [@"已停滞 · " stringByAppendingString:LBRelativeTime(ck)] : LBRelativeTime(ck)];
  }

  // Certificates
  [self reconcileCertificateHosts];
  NSDictionary *certs = d.certs, *errors = d.errors;
  for (NSString *h in _certHosts) {
    id v = certs[h];
    NSError *certError = errors[[@"cert:" stringByAppendingString:h]];
    if ([v isKindOfClass:NSDate.class]) {
      NSInteger left = (NSInteger)floor([(NSDate *)v timeIntervalSinceNow] / 86400);
      UIColor *c = left < 0 ? UIColor.systemRedColor : left < 14 ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
      NSString *detail = left < 0 ? @"已过期" : [NSString stringWithFormat:@"剩 %ld 天", (long)left];
      NSDate *checked = [d certificateCheckedAt:h];
      if (certError) {
        detail = [NSString stringWithFormat:@"上次%@ · 复核失败", detail];
        c = UIColor.systemOrangeColor;
      } else if (checked) {
        detail = [detail stringByAppendingFormat:@" · 核验%@", LBRelativeTime((long long)(checked.timeIntervalSince1970 * 1000))];
      }
      [self updateCertificateRow:_certRows[h] icon:certError ? @"exclamationmark.lock.fill" : left < 0 ? @"lock.slash.fill" : @"lock.fill" color:c detail:detail];
    } else if ([v isKindOfClass:NSError.class]) {
      [self updateCertificateRow:_certRows[h] icon:@"exclamationmark.lock.fill" color:UIColor.systemRedColor detail:[(NSError *)v localizedDescription]];
    } else {
      [self updateCertificateRow:_certRows[h] icon:@"lock" color:LBTheme.muted detail:@"检查中…"];
    }
  }
  _setupNotice.hidden = LBGitHub.shared.configured;
}
- (void)openCommit { LBOpenURL(self, [NSURL URLWithString:LBSiteData.shared.head[@"url"]]); }
@end

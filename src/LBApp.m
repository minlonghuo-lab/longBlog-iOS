#import "LBLayout.h"
#import "LBNavigationController.h"
#import "LBPostReader.h"
#import "LBMemos.h"
#import <WebKit/WebKit.h>
#import <BackgroundTasks/BackgroundTasks.h>

// One owner for chrome policy, including programmatic tab selections. Never
// inspect UIKit's private bar hierarchy or change a scroll view's delegate.
@interface LBTabBarController : UITabBarController <UINavigationControllerDelegate, UITabBarControllerDelegate>
- (void)updateMinimizePolicy;
@end

@implementation LBTabBarController {
  __weak UIViewController *_registeredReader;
  __weak UINavigationController *_transitionNavigationController;
  BOOL _policyUpdateScheduled;
  BOOL _applyingPolicy;
  NSUInteger _navigationRevision;
}
- (UITabBarMinimizeBehavior)desiredMinimizePolicyForViewController:(UIViewController *)vc {
  BOOL isReader = [vc isKindOfClass:LBPostReaderViewController.class];
  BOOL reader = isReader;
  if (reader && [(LBPostReaderViewController *)vc memoPreview]) reader = NO;
  return reader && !UIAccessibilityIsReduceMotionEnabled()
      ? UITabBarMinimizeBehaviorOnScrollDown : UITabBarMinimizeBehaviorNever;
}
- (void)applyPolicyForViewController:(UIViewController *)vc {
  UITabBarMinimizeBehavior desired = [self desiredMinimizePolicyForViewController:vc];
  if (self.tabBarMinimizeBehavior != desired) self.tabBarMinimizeBehavior = desired;
  if ([vc.navigationController isKindOfClass:LBNavigationController.class])
    [(LBNavigationController *)vc.navigationController reconcileChrome];
  BOOL isReader = [vc isKindOfClass:LBPostReaderViewController.class];
  if (!isReader || _registeredReader == vc) return;
  // The reader owns this direct WKWebView child. Use only its public scrollView,
  // not WKContentView/internal subviews. Explicit registration is necessary
  // because its decorative background precedes the web view.
  [vc loadViewIfNeeded];
  for (UIView *content in vc.view.subviews) {
    if (![content isKindOfClass:WKWebView.class]) continue;
    UIScrollView *scroll = ((WKWebView *)content).scrollView;
    [vc setContentScrollView:scroll forEdge:NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom];
    scroll.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle;
    scroll.topEdgeEffect.hidden = YES;
    scroll.bottomEdgeEffect.hidden = YES;
    _registeredReader = vc;
    if ([vc.navigationController isKindOfClass:LBNavigationController.class])
      [(LBNavigationController *)vc.navigationController reconcileChrome];
    break;
  }
}
- (UIViewController *)activeTabViewController {
  // Prefer the modern UITab API; retain a fallback for legacy selections.
  return self.selectedTab.viewController ?: self.selectedViewController;
}
- (void)updateMinimizePolicy {
  if (!NSThread.isMainThread) {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateMinimizePolicy]; });
    return;
  }
  // Defer chrome mutation until UIKit has finished the navigation callback.
  // Coalesce requests and resolve the CURRENT selected stack when it executes.
  if (_policyUpdateScheduled) return;
  _policyUpdateScheduled = YES;
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    typeof(self) owner = weakSelf;
    if (!owner) return;
    owner->_policyUpdateScheduled = NO;
    UIViewController *active = [owner activeTabViewController];
    if (![active isKindOfClass:UINavigationController.class]) return;
    UINavigationController *nav = (UINavigationController *)active;
    if (owner->_transitionNavigationController == nav || owner->_applyingPolicy) return;
    UIViewController *visible = nav.topViewController;
    if (!visible) return;
    owner->_applyingPolicy = YES;
    [owner applyPolicyForViewController:visible];
    owner->_applyingPolicy = NO;
  });
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.delegate = self;
  self.tabBarMinimizeBehavior = UITabBarMinimizeBehaviorNever;
  UITabBarAppearance *appearance = [UITabBarAppearance new];
  [appearance configureWithTransparentBackground];
  appearance.backgroundEffect = nil;
  appearance.backgroundColor = UIColor.clearColor;
  appearance.shadowColor = UIColor.clearColor;
  self.tabBar.standardAppearance = appearance;
  self.tabBar.scrollEdgeAppearance = appearance;
  self.tabBar.backgroundColor = UIColor.clearColor;
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateMinimizePolicy)
      name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)setSelectedTab:(UITab *)selectedTab {
  if (self.selectedTab != selectedTab && LBShouldAnimate(YES)) {
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
  }
  [super setSelectedTab:selectedTab];
  [self updateMinimizePolicy];
}
- (void)setSelectedViewController:(UIViewController *)viewController {
  [super setSelectedViewController:viewController];
  [self updateMinimizePolicy];
}
- (void)tabBarController:(UITabBarController *)tabs didSelectTab:(UITab *)selectedTab previousTab:(UITab *)previousTab {
  if (selectedTab != previousTab && LBShouldAnimate(YES)) {
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
  }
  [self updateMinimizePolicy];
}
- (void)navigationController:(UINavigationController *)nav willShowViewController:(UIViewController *)vc animated:(BOOL)animated {
  if (nav != [self activeTabViewController]) return;
  nav.navigationBar.prefersLargeTitles = NO;
  vc.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
  vc.navigationItem.style = UINavigationItemStyleBrowser;
  NSUInteger revision = ++_navigationRevision;
  id<UIViewControllerTransitionCoordinator> coordinator = nav.transitionCoordinator;
  if (coordinator) {
    _transitionNavigationController = nav;
    __weak typeof(self) weakSelf = self;
    __weak UINavigationController *weakNav = nav;
    // No live minimize-policy changes or forced layout in a transition's
    // animation block: UIKit owns its tab/scroll geometry until it settles.
    BOOL registered = [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
      (void)context;
      typeof(self) owner = weakSelf;
      if (!owner || revision != owner->_navigationRevision) return;
      if (owner->_transitionNavigationController == weakNav) owner->_transitionNavigationController = nil;
      [owner updateMinimizePolicy]; // completed OR cancelled: read actual stack
    }];
    if (!registered) {
      _transitionNavigationController = nil;
      [self updateMinimizePolicy];
    }
  } else {
    _transitionNavigationController = nil;
    [self updateMinimizePolicy];
  }
}
- (void)navigationController:(UINavigationController *)nav didShowViewController:(UIViewController *)vc animated:(BOOL)animated {
  if (_transitionNavigationController == nav) _transitionNavigationController = nil;
  if (nav == [self activeTabViewController]) [self updateMinimizePolicy];
}

@end

@implementation LBAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
  UNUserNotificationCenter *nc = UNUserNotificationCenter.currentNotificationCenter;
  nc.delegate = self;
  // Reply straight from the banner / lock screen.
  UNTextInputNotificationAction *reply =
      [UNTextInputNotificationAction actionWithIdentifier:@"LB_REPLY" title:@"回复"
                                                  options:UNNotificationActionOptionNone
                                                     icon:[UNNotificationActionIcon iconWithSystemImageName:@"arrowshape.turn.up.left.fill"]
                                     textInputButtonTitle:@"发送" textInputPlaceholder:@"回复访客…"];
  UNNotificationCategory *cat = [UNNotificationCategory categoryWithIdentifier:@"LB_MESSAGE" actions:@[ reply ]
                                                             intentIdentifiers:@[] options:UNNotificationCategoryOptionNone];
  [nc setNotificationCategories:[NSSet setWithObject:cat]];

  [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:LBRefreshTaskID usingQueue:nil
                                                   launchHandler:^(BGTask *task) { [self handleRefresh:(BGAppRefreshTask *)task]; }];
  return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s
                              options:(UISceneConnectionOptions *)o {
  UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:s.role];
  c.delegateClass = [LBSceneDelegate class]; // compile-time reference: survives dead-strip
  return c;
}
- (void)handleRefresh:(BGAppRefreshTask *)task {
  [LBSync.shared scheduleBackgroundRefresh]; // chain the next one first
  __block BOOL finished = NO;
  __weak BGAppRefreshTask *weakTask = task;
  task.expirationHandler = ^{ if (!finished) { finished = YES; [weakTask setTaskCompletedWithSuccess:NO]; } };
  dispatch_async(dispatch_get_main_queue(), ^{
    [LBSync.shared refresh:^(BOOL fresh) {
      if (!finished) { finished = YES; [task setTaskCompletedWithSuccess:LBSync.shared.lastError == nil]; }
    }];
  });
}

#pragma mark Notifications
- (void)userNotificationCenter:(UNUserNotificationCenter *)c willPresentNotification:(UNNotification *)n
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))done {
  done(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound | UNNotificationPresentationOptionList);
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)c didReceiveNotificationResponse:(UNNotificationResponse *)r
         withCompletionHandler:(void (^)(void))done {
  NSString *sid = r.notification.request.content.userInfo[@"sessionId"];
  if (![sid isKindOfClass:NSString.class]) { done(); return; }
  if ([r isKindOfClass:UNTextInputNotificationResponse.class]) {
    NSString *text = [((UNTextInputNotificationResponse *)r).userText
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) { done(); return; }
    if (text.length > 500) text = [text substringToIndex:500];
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier bg = [app beginBackgroundTaskWithExpirationHandler:^{ [app endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }];
    [LBAPI.shared reply:sid messageId:[LBAPI randomHex:16] text:text done:^(LBMessage *m, NSError *e) {
      UNMutableNotificationContent *c2 = [UNMutableNotificationContent new];
      c2.title = e ? @"回复未送达" : @"已回复";
      c2.body = e ? [NSString stringWithFormat:@"%@ · 打开 App 重试", e.localizedDescription] : text;
      c2.threadIdentifier = sid;
      c2.userInfo = @{ @"sessionId" : sid };
      [c addNotificationRequest:[UNNotificationRequest requestWithIdentifier:sid content:c2 trigger:nil] withCompletionHandler:nil];
      [LBSync.shared refresh:nil];
      done();
      if (bg != UIBackgroundTaskInvalid) { [app endBackgroundTask:bg]; bg = UIBackgroundTaskInvalid; }
    }];
    return;
  }
  [NSNotificationCenter.defaultCenter postNotificationName:LBOpenSessionRequest object:nil userInfo:@{ @"sessionId" : sid }];
  done();
}
@end

// The launch surface has no services, Keychain or document-provider work. Start
// connection discovery only after UIKit has presented this lightweight window.
@interface LBLaunchViewController : UIViewController
@property (nonatomic, copy) void (^ready)(void);
@end
@implementation LBLaunchViewController
- (void)loadView {
  self.view = [UIView new];
  self.view.backgroundColor = LBTheme.paper;
  UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  indicator.color = LBTheme.muted;
  indicator.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:indicator];
  [NSLayoutConstraint activateConstraints:@[
    [indicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [indicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
  ]];
  [indicator startAnimating];
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  void (^ready)(void) = self.ready;
  self.ready = nil;
  if (ready) ready();
}
@end

@implementation LBSceneDelegate {
  UITabBarController *_tabs;
  UITab *_inboxTab;
  NSString *_pendingSessionID;
  id _openObserver, _syncObserver;
}
static UINavigationController *navFor(UIViewController *vc) {
  // LBNavigationController configures its bar in viewDidLoad, not before the
  // selected tab actually needs a view.
  return [[LBNavigationController alloc] initWithRootViewController:vc];
}
- (void)openSession:(NSString *)sid {
  if (![sid isKindOfClass:NSString.class] || !sid.length) return;
  if (!_tabs) { _pendingSessionID = [sid copy]; return; }
  _tabs.selectedTab = _inboxTab;
  UINavigationController *nav = (UINavigationController *)_inboxTab.viewController;
  LBInboxViewController *inbox = (LBInboxViewController *)nav.viewControllers.firstObject;
  [inbox openSession:sid animated:LBShouldAnimate(YES)];
}
- (void)installTabsWithInboxOnly:(BOOL)inboxOnly {
  LBTabBarController *chrome = [LBTabBarController new];
  _tabs = chrome;
  __weak LBTabBarController *weakChrome = chrome;
  // Each provider caches one stack. Unvisited tabs do not allocate controllers,
  // navigation bars or services; returning to a visited tab preserves its state.
  NSArray *specs = @[
    @[ @"dashboard", @"仪表盘", @"gauge.with.dots.needle.67percent", ^UIViewController *{ return [LBDashboardViewController new]; } ],
    @[ @"inbox", @"留言", @"bubble.left.and.text.bubble.right", ^UIViewController *{ return [LBInboxViewController new]; } ],
    @[ @"posts", @"文章", @"doc.richtext", ^UIViewController *{ return [LBPostsViewController new]; } ],
    @[ @"memos", @"说说", @"text.bubble", ^UIViewController *{ return [[LBMemosTimelineController alloc] initWithArchived:NO]; } ],
    @[ @"config", @"配置", @"slider.horizontal.3", ^UIViewController *{ return [LBSiteConfigViewController new]; } ],
  ];
  NSMutableArray *tabs = [NSMutableArray array];
  for (NSArray *s in specs) {
    UIViewController *(^makeRoot)(void) = s[3];
    __block UINavigationController *navigation;
    UITab *t = [[UITab alloc] initWithTitle:s[1] image:[UIImage systemImageNamed:s[2]] identifier:s[0]
                     viewControllerProvider:^UIViewController *(UITab *tab) {
      if (!navigation) {
        navigation = navFor(makeRoot());
        navigation.delegate = weakChrome;
      }
      return navigation;
    }];
    if ([s[0] isEqualToString:@"inbox"]) _inboxTab = t;
    [tabs addObject:t];
  }
  _tabs.tabs = tabs;
  _tabs.tabBarMinimizeBehavior = UITabBarMinimizeBehaviorNever;
  _tabs.selectedTab = inboxOnly || _pendingSessionID.length ? _inboxTab : tabs.firstObject;
  self.window.rootViewController = _tabs;
  NSString *sid = _pendingSessionID; _pendingSessionID = nil;
  if (sid) [self openSession:sid];
  if (self.window.windowScene.activationState == UISceneActivationStateForegroundActive)
    [LBSync.shared startForegroundPolling];
  [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:
      UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge completionHandler:^(BOOL ok, NSError *e) {}];
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
  if (![scene isKindOfClass:UIWindowScene.class]) return;
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
  self.window.backgroundColor = LBTheme.paper;
  self.window.tintColor = LBTheme.accent;
  LBLaunchViewController *launch = [LBLaunchViewController new];
  __weak typeof(self) weakSelf = self;
  __weak LBLaunchViewController *weakLaunch = launch;
  launch.ready = ^{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      BOOL inboxOnly = [LBAPI.shared configured] && !LBGitHub.shared.configured;
      dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) owner = weakSelf;
        if (!owner || !weakLaunch || owner.window.rootViewController != weakLaunch) return;
        [owner installTabsWithInboxOnly:inboxOnly];
      });
    });
  };
  _openObserver = [NSNotificationCenter.defaultCenter addObserverForName:LBOpenSessionRequest object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
    [weakSelf openSession:n.userInfo[@"sessionId"]];
  }];
  _syncObserver = [NSNotificationCenter.defaultCenter addObserverForName:LBSyncDidChange object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
    typeof(self) owner = weakSelf; if (!owner) return;
    NSInteger u = [LBSync.shared unreadCount];
    owner->_inboxTab.badgeValue = u ? [NSString stringWithFormat:@"%ld", (long)u] : nil;
  }];
  // A notification tap may precede the launch surface or scene observers.
  if (![opts.notificationResponse isKindOfClass:UNTextInputNotificationResponse.class])
    [self openSession:opts.notificationResponse.notification.request.content.userInfo[@"sessionId"]];
  self.window.rootViewController = launch;
  [self.window makeKeyAndVisible];
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
  [(LBTabBarController *)_tabs updateMinimizePolicy];
  if (_tabs) [LBSync.shared startForegroundPolling];
}
- (void)sceneWillResignActive:(UIScene *)scene { [LBSync.shared stopForegroundPolling]; }
- (void)sceneDidEnterBackground:(UIScene *)scene { [LBSync.shared scheduleBackgroundRefresh]; }
- (void)sceneDidDisconnect:(UIScene *)scene {
  [LBSync.shared stopForegroundPolling];
  self.window = nil; // Discard a late launch-discovery result for this scene.
  _tabs = nil; _inboxTab = nil;
  if (_openObserver) [NSNotificationCenter.defaultCenter removeObserver:_openObserver];
  if (_syncObserver) [NSNotificationCenter.defaultCenter removeObserver:_syncObserver];
  _openObserver = nil; _syncObserver = nil;
}
- (void)dealloc {
  if (_openObserver) [NSNotificationCenter.defaultCenter removeObserver:_openObserver];
  if (_syncObserver) [NSNotificationCenter.defaultCenter removeObserver:_syncObserver];
}
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([LBAppDelegate class]));
  }
}

#import "LBNavigationController.h"

// UIKit owns the title, native bar background, scroll-edge transition and
// overlap blur. No additional visual-effect view, mask, offset observer or tint.
@implementation LBNavigationController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationBar.prefersLargeTitles = NO;
  self.navigationBar.translucent = YES;
  UINavigationBarAppearance *standard = [UINavigationBarAppearance new];
  [standard configureWithDefaultBackground];
  standard.shadowColor = UIColor.clearColor;
  self.navigationBar.standardAppearance = standard;
  self.navigationBar.compactAppearance = standard;
  // Leave scroll-edge selection to UIKit rather than installing a second
  // transparent/opaque appearance or a custom overlap state machine.
  self.navigationBar.scrollEdgeAppearance = nil;
  self.navigationBar.compactScrollEdgeAppearance = nil;
  [self reconcileChrome];
}
- (void)reconcileChrome {
  // Title is leading-aligned (style = Browser) to counterbalance trailing action buttons.
  for (UIViewController *page in self.viewControllers) {
    UINavigationItem *item = page.navigationItem;
    if (!item.titleView) item.titleView = nil;
    item.subtitleView = nil;
    item.style = UINavigationItemStyleBrowser;
    item.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
  }
}
@end

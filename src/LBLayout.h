#import "LB.h"

// UIKit alone owns scroll content insets. The scroll frame starts at view.top,
// NEVER the changing navigation/search safe-area top. Content scrolls underneath
// native navigation/search controls. UIKit supplies the native soft scroll-edge
// treatment; no custom effect layer or mask. No frame/inset feedback loop.
// Register explicitly because the decorative aurora precedes the scroll view.
static inline void LBInstallContentScrollView(UIViewController *vc, UIScrollView *scroll,
                                              NSLayoutYAxisAnchor *bottomAnchor) {
  vc.view.backgroundColor = LBTheme.paper;
  vc.definesPresentationContext = YES;
  LBAuroraView *background = [LBAuroraView new];
  background.translatesAutoresizingMaskIntoConstraints = NO;
  background.userInteractionEnabled = NO;
  background.accessibilityElementsHidden = YES;
  [vc.view insertSubview:background atIndex:0];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAlways;
  scroll.automaticallyAdjustsScrollIndicatorInsets = YES;
  scroll.alwaysBounceVertical = YES;
  scroll.clipsToBounds = YES;
  // The system softly obscures content as it passes native navigation chrome.
  scroll.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle;
  scroll.topEdgeEffect.hidden = NO;
  scroll.bottomEdgeEffect.hidden = YES;
  [vc.view addSubview:scroll];
  [vc setContentScrollView:scroll forEdge:NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom];
  [NSLayoutConstraint activateConstraints:@[
    [background.topAnchor constraintEqualToAnchor:vc.view.topAnchor],
    [background.bottomAnchor constraintEqualToAnchor:vc.view.bottomAnchor],
    [background.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
    [background.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
    [scroll.topAnchor constraintEqualToAnchor:vc.view.topAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:bottomAnchor ?: vc.view.bottomAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor],
  ]];
}

static inline BOOL LBShouldAnimate(BOOL requested) {
  return requested && !UIAccessibilityIsReduceMotionEnabled();
}

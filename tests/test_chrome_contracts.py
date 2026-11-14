#!/usr/bin/env python3
"""Offline source/constraint contracts; NOT UIKit runtime or screenshot evidence."""
from pathlib import Path
import re
import unittest

SRC = Path(__file__).resolve().parents[1] / 'src'


def read(name):
    return (SRC / name).read_text()


class ChromeContracts(unittest.TestCase):
    def test_only_concrete_reader_can_minimize(self):
        app = read('LBApp.m')
        self.assertIn('[vc isKindOfClass:LBPostReaderViewController.class]', app)
        self.assertIn('reader && !UIAccessibilityIsReduceMotionEnabled()', app)
        self.assertEqual(app.count('UITabBarMinimizeBehaviorOnScrollDown'), 1)
        self.assertIn('? UITabBarMinimizeBehaviorOnScrollDown : UITabBarMinimizeBehaviorNever', app)
        self.assertIn('__weak LBTabBarController *weakChrome = chrome', app)
        provider = app.split('viewControllerProvider:', 1)[1].split('return navigation;', 1)[0]
        self.assertIn('if (!navigation)', provider)
        self.assertIn('navigation.delegate = weakChrome', provider)
        for hook in ['willShowViewController:', 'didShowViewController:',
                     'didSelectTab:', 'setSelectedTab:', 'setSelectedViewController:',
                     'sceneDidBecomeActive:', 'UIAccessibilityReduceMotionStatusDidChangeNotification']:
            self.assertIn(hook, app)
        self.assertIn('if (nav != [self activeTabViewController]) return', app)
        self.assertIn('self.selectedTab.viewController ?: self.selectedViewController', app)

    def test_reader_scroll_is_registered_without_private_hacks(self):
        app = read('LBApp.m')
        self.assertIn('[content isKindOfClass:WKWebView.class]', app)
        self.assertIn('((WKWebView *)content).scrollView', app)
        self.assertIn('setContentScrollView:scroll forEdge:', app)
        for forbidden in ['valueForKey:', 'setValue:', 'NSClassFromString(@"_',
                          'scroll.delegate =', 'tabBar.subviews', 'method_exchangeImplementations']:
            self.assertNotIn(forbidden, app)

    def test_chrome_backdrops_are_transparent_in_all_states(self):
        app = read('LBApp.m'); nav = read('LBNavigationController.m')
        self.assertIn('[[LBNavigationController alloc] initWithRootViewController:vc]', app)
        self.assertIn('[standard configureWithDefaultBackground]', nav)
        self.assertIn('standard.shadowColor = UIColor.clearColor', nav)
        self.assertIn('self.navigationBar.scrollEdgeAppearance = nil', nav)
        self.assertIn('self.navigationBar.compactScrollEdgeAppearance = nil', nav)
        self.assertIn('appearance.backgroundEffect = nil', app) # floating tab unchanged

    def test_backdrop_feathers_the_effect_not_an_opaque_color(self):
        # v1.9 removes the custom feather rather than retuning it again.
        nav = read('LBNavigationController.m')
        for forbidden in ['UIVisualEffectView', 'CAGradientLayer', 'maskView',
                          'contentOffset', 'addObserver:', 'LBInlineTitleView',
                          'backgroundEffect =', 'backgroundColor =']:
            self.assertNotIn(forbidden, nav)
        self.assertIn('item.titleView = nil', nav)
        self.assertIn('item.subtitleView = nil', nav)

    def test_feather_alpha_reaches_zero_continuously(self):
        # UIKit owns edge progression: general layouts keep soft top; article reader removes masks per user request.
        for name in ['LBLayout.h', 'LBSettings.m']:
            source = read(name)
            self.assertIn('topEdgeEffect.hidden = NO', source)
            self.assertIn('bottomEdgeEffect.hidden = YES', source)
        for name in ['LBApp.m', 'LBPostReader.m']:
            source = read(name)
            self.assertIn('topEdgeEffect.hidden = YES', source)
            self.assertIn('bottomEdgeEffect.hidden = YES', source)

    def test_full_frame_scroll_and_soft_top_have_no_hard_crop(self):
        layout = read('LBLayout.h')
        self.assertIn('scroll.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle', layout)
        self.assertIn('scroll.topEdgeEffect.hidden = NO', layout)
        self.assertIn('scroll.bottomEdgeEffect.hidden = YES', layout)
        self.assertNotIn('hardStyle', layout)
        self.assertNotIn('viewport', layout)
        for text in ['scroll.clipsToBounds = YES', '[vc.view addSubview:scroll]',
                     '[scroll.topAnchor constraintEqualToAnchor:vc.view.topAnchor]',
                     'UIScrollViewContentInsetAdjustmentAlways',
                     'setContentScrollView:scroll forEdge:NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom']:
            self.assertIn(text, layout)
        self.assertNotIn('[scroll.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor]', layout)
        self.assertNotIn('additionalSafeAreaInsets', layout)
        self.assertNotIn('setContentOffset:', layout)

    def test_notice_returns_centered_wrapper_not_stretched_stack(self):
        notice = read('LBCard.m').split('UIView *LBNotice(', 1)[1]
        for text in ['UIViewContentModeScaleAspectFit', 'return container;',
                     '[container addSubview:st]', 'container.safeAreaLayoutGuide',
                     '[st.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor]',
                     '[st.widthAnchor constraintLessThanOrEqualToConstant:360]',
                     't.numberOfLines = 0', 'b.numberOfLines = 0',
                     'setContentCompressionResistancePriority:UILayoutPriorityRequired']:
            self.assertIn(text, notice)
        self.assertNotIn('return st;', notice)
        sizes = re.findall(r'iv\.(?:width|height)Anchor constraintEqualToConstant:(\d+)', notice)
        self.assertEqual(sizes, ['48', '48'])

    def test_notice_constraint_model_does_not_scale_icon_with_table(self):
        # Analytical consequences of the source constants, not a UIKit solver.
        notice = read('LBCard.m').split('UIView *LBNotice(', 1)[1]
        bounds = dict(re.findall(r'iv\.(width|height)Anchor constraintEqualToConstant:(\d+)', notice))
        icon_width, icon_height = int(bounds['width']), int(bounds['height'])
        for table_width, safe_height in [(320, 480), (430, 780), (1024, 1100)]:
            stack_width = min(table_width - 48, 360)
            stack_height = icon_height + 24 + 54 + 36  # icon, title, body, three gaps
            top = (safe_height - stack_height) / 2
            self.assertGreaterEqual(top, 24)
            self.assertGreaterEqual((table_width - stack_width) / 2, 24)
            self.assertEqual(icon_width / icon_height, 1)
            self.assertLessEqual(icon_height, 56)
            self.assertLess(stack_height, safe_height - 48)


if __name__ == '__main__':
    unittest.main(verbosity=2)

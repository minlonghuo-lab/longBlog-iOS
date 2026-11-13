"""Native navigation regression after removing the v1.8 custom layer.
These source contracts do not execute UIKit or claim pixel equivalence to App Store.
"""
from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[1]/'src'
def read(n): return (R/n).read_text()
class NativeNavigation19(unittest.TestCase):
    def test_no_custom_overlay_mask_or_offset_state_machine(self):
        nav=read('LBNavigationController.m')
        for bad in ('UIVisualEffectView', 'CAGradientLayer', 'maskView', 'addObserver:',
                    'contentOffset', 'LBInlineTitleView', '_backdrop', 'UIViewPropertyAnimator'):
            self.assertNotIn(bad,nav)
    def test_native_title_is_not_replaced(self):
        nav=read('LBNavigationController.m')
        for text in ('item.titleView = nil', 'item.subtitleView = nil',
                     'item.style = UINavigationItemStyleBrowser',
                     'item.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever'):
            self.assertIn(text,nav)
        for name,title in [('LBConfig.m','站点配置'),('LBDashboard.m','仪表盘'),('LBMemosTimeline.m','说说')]:
            self.assertIn(title,read(name))
    def test_system_owns_edge_material(self):
        nav=read('LBNavigationController.m')
        for text in ('configureWithDefaultBackground', 'scrollEdgeAppearance = nil',
                     'compactScrollEdgeAppearance = nil', 'standard.shadowColor = UIColor.clearColor'):
            self.assertIn(text,nav)
        for bad in ('standard.backgroundEffect', 'standard.backgroundColor', 'configureWithTransparentBackground'):
            self.assertNotIn(bad,nav)
    def test_top_soft_edge_restored_in_all_registration_paths(self):
        for name in ('LBLayout.h','LBSettings.m'):
            s=read(name)
            self.assertIn('topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle',s)
            self.assertIn('topEdgeEffect.hidden = NO',s)
            self.assertIn('bottomEdgeEffect.hidden = YES',s)
        for name in ('LBApp.m','LBPostReader.m'):
            s=read(name)
            self.assertIn('topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle',s)
            self.assertIn('topEdgeEffect.hidden = YES',s)
            self.assertIn('bottomEdgeEffect.hidden = YES',s)
    def test_no_regression_in_scroll_geometry_or_tab_policy(self):
        layout=read('LBLayout.h');app=read('LBApp.m')
        self.assertIn('UIScrollViewContentInsetAdjustmentAlways',layout)
        self.assertIn('[scroll.topAnchor constraintEqualToAnchor:vc.view.topAnchor]',layout)
        self.assertIn('setContentScrollView:scroll forEdge:',layout)
        self.assertIn('memoPreview]) reader = NO',app)
        self.assertEqual(app.count('UITabBarMinimizeBehaviorOnScrollDown'),1)
        self.assertIn('animateAlongsideTransition:',app)
    def test_category_arrow_has_bounded_aspect_fit_geometry(self):
        config=read('LBConfig.m')
        arrow=config.split('UIImageView *arrow =')[1].split('c.trailingView = arrow')[0]
        self.assertIn('UIViewContentModeScaleAspectFit',arrow)
        self.assertIn('arrow.widthAnchor constraintEqualToConstant:14',arrow)
        self.assertIn('arrow.heightAnchor constraintEqualToConstant:20',arrow)
        self.assertNotIn('UILayoutPriorityRequired',arrow)
        self.assertIn('self.trailingView = nil',read('LBCard.m'))
if __name__=='__main__': unittest.main(verbosity=2)

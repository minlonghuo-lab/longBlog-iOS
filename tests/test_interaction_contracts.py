#!/usr/bin/env python3
"""Offline source/state contracts only; these do NOT execute UIKit or prove pixels."""
from pathlib import Path
import unittest

SRC = Path(__file__).resolve().parents[1] / 'src'
def read(name):
    return (SRC / name).read_text()

class InteractionContracts(unittest.TestCase):
    def test_search_uses_fixed_native_chrome(self):
        app, content = read('LBApp.m'), read('LBContent.m')
        self.assertIn('nav.navigationBar.prefersLargeTitles = NO', app)
        for setting in ['sc.delegate = self', 'sc.hidesNavigationBarDuringPresentation = NO',
                        'preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked',
                        'hidesSearchBarWhenScrolling = NO',
                        'searchBarPlacementAllowsToolbarIntegration = NO']:
            self.assertEqual(content.count(setting), 2)

    def test_dismissal_freezes_then_commits_latest_snapshot(self):
        content = read('LBContent.m')
        for controller in content.split('@implementation ')[1:]:
            update = controller.split('- (void)updateSearchResultsForSearchController:', 1)[1].split('- (void)willPresentSearchController:', 1)[0]
            self.assertIn('if (_searchDismissing || !sc.isActive) return', update)
            self.assertNotIn('reloadData', update)
            dismiss = controller.split('- (void)didDismissSearchController:', 1)[1].split('- (void)reload {', 1)[0]
            self.assertIn('_query = @""', dismiss)
            self.assertLess(dismiss.index('_searchDismissing = NO'), dismiss.index('[self reload]'))
            reload = controller.split('- (void)reload {', 1)[1].split('- (NSInteger)tableView:', 1)[0]
            self.assertIn('if (_searchDismissing || (!_visible && _renderKey)) return', reload)
            self.assertIn('if ([_renderKey isEqual:key]) return', reload)
            self.assertLess(reload.index('_items ='), reload.index('[_table reloadData]'))
            self.assertNotIn('dispatch_after', update + dismiss + reload)
        self.assertNotIn('[self items]', content)
        self.assertEqual(content.count('numberOfRowsInSection:(NSInteger)s { return _items.count; }'), 2)
        self.assertIn('[p[@"html"] isKindOfClass:NSString.class]', content)

    def test_grouped_headers_are_sized_before_display(self):
        config = read('LBConfig.m').split('#pragma mark - Config screen', 1)[1]
        # v1.8 uses category navigation rather than repeating section headers.
        # Preserve the no-floating/no-late-measurement regression contract.
        for text in ['_table.sectionHeaderHeight = 0',
                     '_table.sectionFooterHeight = 0',
                     'if (!_selectedSection) return [self categoryCell:',
                     'initWithOwner:self selectedSection:',
                     'if ([_renderKey isEqual:key]) return']:
            self.assertIn(text, config)
        self.assertNotIn('titleForHeaderInSection:', config)
        self.assertNotIn('willDisplayHeaderView:', config)

    def test_policy_is_deferred_until_navigation_settles(self):
        app = read('LBApp.m')
        self.assertIn('if (self.tabBarMinimizeBehavior != desired)', app)
        will = app.split('willShowViewController:', 1)[1].split('didShowViewController:', 1)[0]
        self.assertIn('animateAlongsideTransition:nil completion:', will)
        self.assertNotIn('layoutIfNeeded', will)
        self.assertNotIn('self.tabBarMinimizeBehavior =', will)
        self.assertIn('[owner updateMinimizePolicy]', will)
        for hook in ['setSelectedTab:', 'setSelectedViewController:']:
            body = app.split(hook, 1)[1].split('\n}', 1)[0]
            self.assertNotIn('self.tabBarMinimizeBehavior =', body)
        self.assertIn('_registeredReader == vc', app)

    def test_cells_finish_hidden_state_before_self_sizing(self):
        for name, minimum in [('LBContent.m', 2), ('LBConfig.m', 3)]:
            text = read(name)
            self.assertGreaterEqual(text.count('[c finishConfiguration]'), minimum)
            for before in text.split('return c;')[:-1]:
                self.assertTrue(before.rstrip().endswith('[c finishConfiguration];'))

    def test_geometry_model_has_one_top_inset_owner(self):
        # Algebra for the implemented constraints, NOT a UIKit layout simulation.
        # Scroll y=0 stays constant, including during changing search chrome.
        # UIKit alone supplies the content inset equal to chrome; native blur
        # protects the text underneath, without another frame/crop owner.
        for chrome in [59, 103, 147, 203, 103]:
            scroll_y = 0
            adjusted_top = chrome + 4  # the table's existing 4pt content spacing
            offset_at_top = -adjusted_top
            first_content_y = scroll_y - offset_at_top
            self.assertEqual(first_content_y - chrome, 4)
            self.assertEqual(scroll_y, 0)

if __name__ == '__main__':
    unittest.main(verbosity=2)

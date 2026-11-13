import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CARD = (ROOT / 'src/LBCard.m').read_text()
CONTENT = (ROOT / 'src/LBContent.m').read_text()


class CardLayoutTruncationFixTests(unittest.TestCase):
    def test_glass_and_stack_bottom_constraints_have_high_priority(self):
        # 2.14.7: content is incompressible; only the outer cell link yields (999),
        # so a short transient row overflows instead of cutting the card.
        self.assertIn('glassBottom.priority = UILayoutPriorityRequired - 1;', CARD)
        self.assertNotIn('stackBottom.priority = UILayoutPriorityDefaultHigh;', CARD)
        self.assertNotIn('glassBottom.priority = UILayoutPriorityDefaultHigh;', CARD)

    def test_preferred_max_layout_width_has_safe_screen_fallback(self):
        # Prevents multi-line title and body labels from calculating as single-line width 0
        self.assertIn('static CGFloat LBScreenWidth(UIView *view)', CARD)
        self.assertIn('CGFloat available = w - 68;', CARD)
        self.assertIn('_bodyLabel.preferredMaxLayoutWidth = available;', CARD)

    def test_swipe_action_delayed_refresh_avoids_animation_collision(self):
        # 2.14.7: no fixed 0.28s guess; rows are deferred while the swipe is open
        # and applied from didEndEditingRowAtIndexPath.
        self.assertIn('done(ok);', CONTENT)
        self.assertNotIn('(int64_t)(0.28 * NSEC_PER_SEC)', CONTENT)
        self.assertIn('if (_swipeActive) {', CONTENT)
        self.assertIn('didEndEditingRowAtIndexPath', CONTENT)

    def test_table_top_content_offset_guard_prevents_searchbar_overlap(self):
        # Prevents tableview from drifting into the searchbar area on reload
        self.assertIn('CGFloat targetTop = -_table.adjustedContentInset.top;', CONTENT)
        self.assertIn('[_table setContentOffset:CGPointMake(0, targetTop) animated:NO];', CONTENT)


if __name__ == '__main__':
    unittest.main()

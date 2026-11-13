import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / 'src'
CARD = (SRC / 'LBCard.m').read_text()
CONTENT = (SRC / 'LBContent.m').read_text()
MEMOS = (SRC / 'LBMemosTimeline.m').read_text()
STORE = (SRC / 'LBMdStore.m').read_text()
THEME = (SRC / 'LBTheme.m').read_text()
HEADER = (SRC / 'LB.h').read_text()


class Fixes2147(unittest.TestCase):
    def test_memo_swipe_has_edit_with_detail_page_gate(self):
        self.assertIn('title:@"编辑" handler:', MEMOS)
        self.assertIn('configurationWithActions:@[edit, action]', MEMOS)
        self.assertIn('- (void)editMemo:(NSDictionary *)memo', MEMOS)
        self.assertIn('[[LBMemosEditor alloc] initWithMemo:memo saved:nil]', MEMOS)
        self.assertIn('client.authenticationRequired', MEMOS)
        self.assertIn('if (_context != client.generation) return;', MEMOS)

    def test_badges_single_row_with_measured_widths(self):
        self.assertIn('- (void)fitChipsOnOneRow:(CGFloat)available', CARD)
        self.assertIn('sizeWithAttributes:@{ NSFontAttributeName: l.font }', CARD)
        self.assertNotIn('_extraStack.axis = UILayoutConstraintAxisVertical;', CARD)

    def test_swipe_background_is_clear_and_strip_clipped_to_card(self):
        self.assertIn('[UIBackgroundConfiguration clearConfiguration]', CARD)
        self.assertIn('self.automaticallyUpdatesBackgroundConfiguration = NO;', CARD)
        self.assertIn('void LBStyleSwipeActions(UITableView *table)', CARD)
        self.assertIn('void LBStyleSwipeActions(UITableView *table);', HEADER)
        self.assertIn('SwipeActionPullView', CARD)
        for src in (CONTENT, MEMOS):
            self.assertIn('LBStyleSwipeActions(tableView);', src)

    def test_card_never_truncates(self):
        # Truncating paragraph style made attributed text measure as a single line.
        self.assertIn('style.lineBreakMode = NSLineBreakByWordWrapping;', CARD)
        self.assertNotIn('style.lineBreakMode = NSLineBreakByTruncatingTail;', CARD)
        self.assertIn('[_bodyLabel setContentCompressionResistancePriority:UILayoutPriorityRequired', CARD)
        self.assertIn('[_extraStack setContentCompressionResistancePriority:UILayoutPriorityRequired', CARD)
        self.assertIn('glassBottom.priority = UILayoutPriorityRequired - 1;', CARD)

    def test_reload_deferred_during_swipe_and_in_place(self):
        self.assertIn('willBeginEditingRowAtIndexPath', CONTENT)
        self.assertIn('_pendingReload = YES;', CONTENT)
        self.assertIn('reconfigureRowsAtIndexPaths:changed', CONTENT)
        self.assertIn('[c resetCardContent];', CONTENT)
        self.assertIn('- (void)resetCardContent;', HEADER)
        self.assertIn('_swipeActive || _table.dragging', MEMOS)

    def test_staged_scan_off_main_thread(self):
        self.assertIn('[LBMdStore.shared stagedArticlesForArticles:articles]', CONTENT)
        self.assertNotIn('_stagedArticles = [LBMdStore.shared stagedArticles]', CONTENT)

    def test_staged_failure_reported(self):
        self.assertIn('done(ok);', CONTENT)
        self.assertIn('本地暂存失败，文章未改动', CONTENT)

    def test_baseline_alignment_saved_once(self):
        body = STORE[STORE.index('- (NSArray<NSDictionary *> *)stagedArticlesForArticles:'):STORE.index('- (void)commitStagedArticles:')]
        self.assertEqual(body.count('MDSaveState('), 1)
        self.assertIn('alignedFiles[localMD] = mutRec;', body)

    def test_relative_time_formatter_cached(self):
        fn = THEME[THEME.index('NSString *LBRelativeTime('):]
        fn = fn[:fn.index('\n}\n')]
        self.assertIn('dispatch_once', fn)


if __name__ == '__main__':
    unittest.main()

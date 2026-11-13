"""Source-level contracts for UI update boundaries; not UIKit/FPS measurements."""
from pathlib import Path
import unittest
SRC=Path(__file__).resolve().parents[1]/'src'
def source(name): return (SRC/name).read_text()

class MessageInteractions(unittest.TestCase):
    def test_inbox_uses_display_snapshot_not_live_mutating_list(self):
        s=source('LBInbox.m')
        self.assertIn('return _displaySessions.count;',s)
        self.assertIn('LBSession *s = _displaySessions[ip.row];',s)
        self.assertIn('_displaySessions = [s.sessions copy]',s)
        self.assertIn('if (![_rowsSignature isEqualToString:signature])',s)

    def test_inbox_does_not_reload_under_interactive_pop(self):
        s=source('LBInbox.m')
        self.assertIn('if (!_visible || _table.dragging || _table.decelerating) return',s)
        disappear=s.split('- (void)viewWillDisappear:')[1].split('- (void)dealloc')[0]
        self.assertIn('_visible = NO;',disappear)
        self.assertNotIn('reloadData',disappear)
        appear=s.split('- (void)viewDidAppear:')[1].split('- (void)viewWillDisappear:')[0]
        self.assertIn('_returnToInitialPage',appear)
        self.assertIn('-self->_table.adjustedContentInset.top',appear)

    def test_chat_freezes_rows_until_visible_and_idle(self):
        s=source('LBChat.m')
        self.assertIn('return _displayMessages.count;',s)
        self.assertIn('if (!_visible || _table.dragging || _table.decelerating) return;',s)
        self.assertIn('_pendingTableUpdate = YES;',s)
        self.assertIn('_displayMessages = [_messages copy]',s)

    def test_archive_freezes_rows_and_never_refreshes_during_transition(self):
        s=source('LBArchive.m')
        self.assertIn('return _displaySessions.count;',s)
        self.assertIn('_displaySessions = [_sessions copy]',s)
        self.assertIn('if (!_visible || _table.dragging || _table.decelerating) return',s)

    def test_reader_bottom_is_scrollable_content_not_opaque_band(self):
        s=source('LBPostReader.m')
        # Article WebKit extends to view.bottom so no bottom mask exists under the tab bar.
        self.assertIn('[_web.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]',s)
        # 2.15: memo preview shares the article Reader frame (safe-area top, no auto inset).
        self.assertIn('[_web.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor]',s)
        self.assertIn('_web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;',s)
        self.assertIn('_web.scrollView.bottomEdgeEffect.hidden = YES',s)
        self.assertIn('_web.scrollView.backgroundColor = UIColor.clearColor',s)
        self.assertNotIn('insets.bottom = bottom',s)
        adapter = (SRC.parent/'resources/Reader/article-adapter.css').read_text()
        # Bottom breathing room belongs to the SCROLLING document, not native
        # contentInset arithmetic which can hide the article's final paragraph.
        self.assertIn('padding:2.5rem 2.45rem 3rem',adapter)
        self.assertIn('padding:1.5rem 1.1rem 5.5rem',adapter)

    def test_card_visibility_is_finalized_before_sizing(self):
        s=source('LBCard.m')
        self.assertIn('- (void)finishConfiguration',s)
        layout = s.split('- (void)layoutSubviews {', 1)[1].split('- (void)fitChipsOnOneRow:', 1)[0]
        self.assertIn('[super layoutSubviews]', layout)
        self.assertIn('fitChipsOnOneRow:self.contentView.bounds.size.width - 68', layout)
        self.assertIn('_lastChipAvailable == available', s)
        self.assertIn('chips[i].hidden = YES', s)
        self.assertNotIn('[chips[i] removeFromSuperview]', s)
        for file in ['LBArchive.m','LBContent.m','LBConfig.m']:
            self.assertIn('finishConfiguration]',source(file))

if __name__=='__main__': unittest.main(verbosity=2)

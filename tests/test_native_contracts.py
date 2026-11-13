#!/usr/bin/env python3
"""Offline source/layout regression contracts, NOT UIKit/device runtime tests."""
from pathlib import Path
import unittest

SRC = Path(__file__).resolve().parents[1] / 'src'
def read(name):
    return (SRC / name).read_text()

class NativeContracts(unittest.TestCase):
    def test_explicit_scroll_registration(self):
        s = read('LBLayout.h')
        self.assertIn('setContentScrollView:scroll forEdge:NSDirectionalRectEdgeTop | NSDirectionalRectEdgeBottom', s)
        self.assertIn('UIScrollViewContentInsetAdjustmentAlways', s)
        self.assertIn('automaticallyAdjustsScrollIndicatorInsets = YES', s)

    def test_system_edges_and_safe_horizontal_chrome(self):
        s = read('LBLayout.h')
        for text in ['scroll.topEdgeEffect.style = UIScrollEdgeEffectStyle.softStyle',
                     'scroll.topEdgeEffect.hidden = NO', 'scroll.bottomEdgeEffect.hidden = YES',
                     'scroll.clipsToBounds = YES', 'safeAreaLayoutGuide.leadingAnchor',
                     'safeAreaLayoutGuide.trailingAnchor']:
            self.assertIn(text, s)
        self.assertNotIn('scroll.topAnchor constraintEqualToAnchor:vc.view.topAnchor constant:', s)

    def test_screens_use_unified_layout(self):
        for name, expr in [('LBCard.m', 'LBInstallContentScrollView(vc, t, nil)'),
                           ('LBDashboard.m', 'LBInstallContentScrollView(self, _scroll, nil)'),
                           ('LBInbox.m', 'LBInstallContentScrollView(self, _table, nil)'),
                           ('LBChat.m', 'LBInstallContentScrollView(self, _table, _composer.topAnchor)')]:
            with self.subTest(file=name): self.assertIn(expr, read(name))
        self.assertIn('LBGlassTable(self, self)', read('LBArchive.m'))

    def test_native_titles_and_search_retained(self):
        self.assertIn('definesPresentationContext = YES', read('LBLayout.h'))
        self.assertIn('prefersLargeTitles = NO', read('LBApp.m'))
        self.assertIn('self.navigationItem.searchController = sc', read('LBContent.m'))

    def test_keyboard_has_one_geometry_owner(self):
        s = read('LBChat.m')
        self.assertIn('self.view.keyboardLayoutGuide.topAnchor', s)
        self.assertNotIn('self.view.bounds.size.height - _composer.frame.origin.y', s)
        self.assertNotIn('_table.verticalScrollIndicatorInsets = in', s)

    def test_history_reading_not_forced_to_bottom(self):
        s = read('LBChat.m')
        for text in ['_table.dragging && !_table.decelerating', '_followBottom = bottom - _table.contentOffset.y <= 44',
                     'if (_followBottom) [self scrollToBottom:animated]', 'resized && _followBottom', '_needsBottomScroll = YES']:
            self.assertIn(text, s)

    def test_visible_page_timer_lifetime(self):
        for file in ['LBInbox.m', 'LBChat.m', 'LBDashboard.m']:
            self.assertIn('- (void)dealloc', read(file))
        self.assertIn('[weakSelf reload]', read('LBInbox.m'))
        self.assertIn('[weakSelf load:NO]', read('LBChat.m'))

    def test_reduce_motion(self):
        self.assertIn('!UIAccessibilityIsReduceMotionEnabled()', read('LBLayout.h'))
        self.assertIn('UITabBarMinimizeBehaviorNever', read('LBApp.m'))

    def test_archive_cannot_compose(self):
        s = read('LBChat.m')
        self.assertIn('if (!_session.archived) [self buildComposer]', s)
        self.assertIn('fetchArchivedMessages:_session.sessionId', s)
        self.assertIn('if (_session.archived || _connectionRevision != LBAPI.shared.connectionRevision', s)
        self.assertIn('if (!self->_session.archived) [LBSync.shared markRead:', s)

    def test_pagination_is_validated_before_commit(self):
        s = read('LBAPI.m')
        for text in ['LBInteger(j[@"cursor"], from, 200)', 'next != expected', 'all.count + page.count > 200',
                     '[ids containsObject:m.mid]', 'archived ? m.sequence > expected : m.sequence == expected + 1']:
            self.assertIn(text, s)
        self.assertIn('if (generation != self->_generation) return', read('LBSync.m'))

    def test_keychain_update_preserves_existing_secret_on_failure(self):
        self.assertIn('SecItemUpdate', read('LBAPI.m'))
        self.assertIn('SecItemUpdate', read('LBSite.m'))
        self.assertIn('钥匙串保存失败', read('LBSettings.m'))

    def test_authenticated_redirect_is_not_followed(self):
        s = read('LBAPI.m')
        self.assertIn('willPerformHTTPRedirection:', s)
        self.assertIn('done(nil); // Never redirect a credential-bearing request', s)

    def test_permanent_archive_expiry_and_explicit_delete(self):
        s = read('LBAPI.m')
        self.assertIn('deadline == NSNull.null', s)
        self.assertIn('path:@"/owner/archive-delete"', s)
        archive = read('LBArchive.m')
        self.assertIn('performsFirstActionWithFullSwipe = NO', archive)
        self.assertIn('永久删除', archive)
        self.assertIn('永久保留', archive)
        self.assertNotIn('再保留%ld天', archive)

    def test_private_contact_optional_and_cleared_on_connection_change(self):
        self.assertIn('path:@"/owner/session-contact"', read('LBAPI.m'))
        s = read('LBChat.m')
        self.assertIn('访客填写邮箱 · 仅站长可见', s)
        self.assertIn('if (!email.length) { [self clearContact]; return; }', s)
        self.assertIn('if (revision != LBAPI.shared.connectionRevision)', s)
        self.assertIn('copy.accessibilityLabel = @"复制访客邮箱"', s)
        self.assertIn('NSLineBreakByCharWrapping', s)

if __name__ == '__main__':
    unittest.main(verbosity=2)

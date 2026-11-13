import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORE = (ROOT / 'src/LBMdStore.m').read_text()
CONTENT = (ROOT / 'src/LBContent.m').read_text()
MEMOS = (ROOT / 'src/LBMemosTimeline.m').read_text()
DASHBOARD = (ROOT / 'src/LBDashboard.m').read_text()
INBOX = (ROOT / 'src/LBInbox.m').read_text()
CONFIG = (ROOT / 'src/LBConfig.m').read_text()


class UnifiedHeaderAndUnpublishTests(unittest.TestCase):
    def test_unpublishing_badge_on_card(self):
        self.assertIn('下架中…', CONTENT)
        self.assertIn('发布中…', CONTENT)
        self.assertIn('unpublishing', CONTENT)
        self.assertIn('LBChip(@"下架中…", UIColor.systemOrangeColor)', CONTENT)

    def test_unpublish_and_external_publish_bypass_conflict_block(self):
        check = STORE[STORE.index('- (BOOL)checkRemote:'):STORE.index('- (void)preparePublish')]
        self.assertIn('[self.operation isEqual:@"unpublish"]', check)
        self.assertIn('[self.operation isEqual:@"delete"]', check)
        # Articles written outside the app without a prior record are permitted to publish
        self.assertIn('if (!record)', check)

    def test_sidecar_html_does_not_block_unpublish(self):
        prep = STORE[STORE.rindex('- (void)preparePublish'):STORE.rindex('- (void)applyPublish')]
        self.assertIn('![self.operation isEqual:@"unpublish"]', prep)
        self.assertIn('![self.operation isEqual:@"delete"]', prep)

    def test_memos_header_view_and_symbol_effects(self):
        self.assertIn('_navHeaderView', MEMOS)
        self.assertIn('_navSyncIcon', MEMOS)
        self.assertIn('_navSubtitleLabel', MEMOS)
        self.assertIn('NSSymbolRotateEffect rotateClockwiseEffect', MEMOS)
        self.assertIn('NSSymbolBounceEffect effect', MEMOS)
        self.assertIn('[LBTheme rounded:18 weight:UIFontWeightBold]', MEMOS)
        self.assertIn('[LBTheme rounded:12 weight:UIFontWeightMedium]', MEMOS)

    def test_dashboard_inbox_config_consistent_headers(self):
        for code in (DASHBOARD, INBOX, CONFIG):
            self.assertIn('_navHeaderView', code)
            self.assertIn('[LBTheme rounded:18 weight:UIFontWeightBold]', code)
            self.assertIn('[LBTheme rounded:12 weight:UIFontWeightMedium]', code)
            self.assertIn('[_navSyncIcon.widthAnchor constraintEqualToConstant:12]', code)


if __name__ == '__main__':
    unittest.main()

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CARD = (ROOT / 'src/LBCard.m').read_text()
STORE = (ROOT / 'src/LBMdStore.m').read_text()
STORE_H = (ROOT / 'src/LBMdStore.h').read_text()
CONTENT = (ROOT / 'src/LBContent.m').read_text()
MEMOS_H = (ROOT / 'src/LBMemos.h').read_text()
MEMOS_CLIENT = (ROOT / 'src/LBMemosClient.m').read_text()
MEMOS_TIMELINE = (ROOT / 'src/LBMemosTimeline.m').read_text()


class LocalFirstAndScrollSmoothnessTests(unittest.TestCase):
    def test_scroll_smoothness_optimizations(self):
        # Paragraph style is cached statically rather than allocated on each cell
        self.assertIn('static NSDictionary *LBCachedParagraphAttrs(void)', CARD)
        # Chip widths come from one text measurement, never recursive systemLayoutSizeFittingSize:
        self.assertIn('static inline CGFloat LBChipWidth(UIView *view)', CARD)
        self.assertIn('sizeWithAttributes:', CARD)
        self.assertNotIn('systemLayoutSizeFittingSize:UILayoutFittingCompressedSize', CARD)
        # Glass effect is never reconstructed if tint color has not changed
        self.assertIn('if (_currentTint == tint || [_currentTint isEqual:tint]) return;', CARD)
        # Images flag precalculated during background indexing, eliminating <img text scan in hot cell loop
        self.assertIn('post[@"hasImage"] = @(hasImg);', STORE)
        self.assertIn('if ([p[@"hasImage"] boolValue]) [c.extraStack addArrangedSubview:LBChip(@"图片", LBTheme.muted)];', CONTENT)
        self.assertNotIn('for (NSUInteger i = 0; (i = [html rangeOfString:@"<img"', CONTENT)

    def test_articles_local_first_change_driven_sync(self):
        # No unprompted full sync on viewDidLoad or pull; uses remote HEAD commit sniffing
        self.assertIn('- (nullable NSString *)currentHeadCommit;', STORE_H)
        self.assertIn('- (NSString *)currentHeadCommit {', STORE)
        self.assertIn('checkRemoteCommitAndSyncIfNeeded:', CONTENT)
        self.assertIn('[LBGitHub.shared headCommit:', CONTENT)
        self.assertIn('[LBMdStore.shared currentHeadCommit]', CONTENT)
        self.assertNotIn('if (LBGitHub.shared.configured) [self syncArticles:nil];', CONTENT)

    def test_memos_local_first_and_lightweight_change_detection(self):
        # Memos client offers 1-item lightweight check
        self.assertIn('- (void)checkLatestMemoState:(NSString *)state', MEMOS_H)
        self.assertIn('- (void)checkLatestMemoState:(NSString *)state', MEMOS_CLIENT)
        # Timeline checks cloud changes rather than 30s recurring full syncs
        self.assertIn('checkCloudChangesAndSyncIfNeeded', MEMOS_TIMELINE)
        self.assertNotIn('_syncTimer = [NSTimer scheduledTimerWithTimeInterval:30', MEMOS_TIMELINE)


if __name__ == '__main__':
    unittest.main()

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORE = (ROOT / 'src/LBMdStore.m').read_text()
STORE_H = (ROOT / 'src/LBMdStore.h').read_text()
CONTENT = (ROOT / 'src/LBContent.m').read_text()
DASHBOARD = (ROOT / 'src/LBDashboard.m').read_text()
CONFIG = (ROOT / 'src/LBConfig.m').read_text()


class BatchStagingAndReviewTests(unittest.TestCase):
    def test_scroll_indicators_hidden(self):
        self.assertIn('_scroll.showsVerticalScrollIndicator = NO;', DASHBOARD)
        self.assertIn('_table.showsVerticalScrollIndicator = NO;', CONFIG)

    def test_staging_methods_declared_and_implemented(self):
        self.assertIn('- (BOOL)stageUnpublishArticle:(NSString *)noteId error:(NSError * _Nullable * _Nullable)outError;', STORE_H)
        self.assertIn('- (BOOL)stagePublishArticle:(NSString *)noteId error:(NSError * _Nullable * _Nullable)outError;', STORE_H)
        self.assertIn('- (NSArray<NSDictionary *> *)stagedArticles;', STORE_H)
        self.assertIn('- (void)commitStagedArticles:(NSArray<NSDictionary *> *)staged', STORE_H)
        self.assertIn('- (NSArray<NSDictionary *> *)stagedArticles {', STORE)
        self.assertIn('- (void)commitStagedArticles:(NSArray<NSDictionary *> *)staged', STORE)

    def test_staged_badges_on_cards(self):
        self.assertIn('BOOL unpublishing = [activeOp isEqualToString:@"unpublish"] || [activeOp isEqualToString:@"unpublishing"];', CONTENT)
        self.assertIn('BOOL isStagedPublish = [activeOp isEqualToString:@"publish"];', CONTENT)
        self.assertIn('BOOL publishing = isStagedPublish || [activeOp isEqualToString:@"publishing"]', CONTENT)
        self.assertIn('LBChip(@"下架中…", UIColor.systemOrangeColor)', CONTENT)
        self.assertIn('LBChip(@"发布中…", UIColor.systemOrangeColor)', CONTENT)

    def test_review_staged_view_controller_present(self):
        self.assertIn('@interface LBArticlesReviewViewController : UIViewController', CONTENT)
        self.assertIn('@"保存预览"', CONTENT)
        self.assertIn('reviewStaged', CONTENT)
        self.assertIn('commitStagedArticles', CONTENT)
        self.assertIn('commitChanges:changes', STORE)

    def test_swipe_actions_stage_locally(self):
        self.assertIn('stageUnpublishArticle:noteId', CONTENT)
        self.assertIn('stagePublishArticle:noteId', CONTENT)
        self.assertIn('撤回下架', CONTENT)
        self.assertIn('撤回发布', CONTENT)


if __name__ == '__main__':
    unittest.main()

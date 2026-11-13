import os
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORE = (ROOT / 'src/LBMdStore.m').read_text()
CONTENT = (ROOT / 'src/LBContent.m').read_text()
READER_JS = (ROOT / 'resources/Reader/reader.js').read_text()
site_env = os.environ.get('LONGBLOG_SITE_ROOT')
site_path = (Path(site_env).expanduser() / 'src/data/md-posts.ts') if site_env else (ROOT / '../../src/data/md-posts.ts')
SITE_TS = site_path.read_text() if site_path.exists() else None
EDITOR = (ROOT / 'src/LBPostEditor.m').read_text()


class TableAndTaskList2141Tests(unittest.TestCase):
    def test_table_em_dash_normalization_in_reader(self):
        self.assertIn("[-—–－]{1,}", READER_JS)
        self.assertIn("replace(/[—–－]/g, '-')", READER_JS)

    def test_table_em_dash_normalization_in_site(self):
        if not SITE_TS:
            self.skipTest('Optional upstream site contract: set LONGBLOG_SITE_ROOT')
        self.assertIn("[-—–－]{1,}", SITE_TS)
        self.assertIn("replace(/[—–－]/g, '-')", SITE_TS)

    def test_smart_dashes_disabled_in_editor(self):
        self.assertIn('_textView.smartDashesType = UITextSmartDashesTypeNo;', EDITOR)
        self.assertIn('_textView.smartQuotesType = UITextSmartQuotesTypeNo;', EDITOR)

    def test_checkbox_whitelisted_and_task_list_item_tagged(self):
        self.assertIn('tag === \'input\' && node.getAttribute(\'type\') === \'checkbox\'', READER_JS)
        self.assertIn('task-list-item-checkbox', READER_JS)
        self.assertIn('task-list-item', READER_JS)

    def test_published_article_badge_not_misidentified_as_publishing(self):
        self.assertIn('BOOL isStagedPublish = [activeOp isEqualToString:@"publish"];', CONTENT)
        self.assertIn('BOOL publishing = isStagedPublish || [activeOp isEqualToString:@"publishing"]', CONTENT)
        self.assertIn('BOOL publishedArticle = pubState && !isStagedPublish;', CONTENT)
        self.assertIn('LBChip(@"已发布", [UIColor colorWithRed:0.1 green:0.75 blue:0.4 alpha:1.0])', CONTENT)

    def test_commit_staged_articles_writes_back_payload(self):
        commit = STORE[STORE.index('- (void)commitStagedArticles:'):STORE.index('@implementation LBArticleTask')]
        self.assertIn('[self beginArticleOperation:@"batch"', commit)
        apply = STORE[STORE.index('- (void)applyBatch:(NSDictionary *)result {'):]
        apply = apply.split('\n- (void)', 1)[0]
        self.assertIn('MDWrite(self.root, local, payload, &e)', apply)
        self.assertIn('!changedDuringUpload', apply)
        self.assertIn('return [self finish:e]', apply)
        self.assertIn('MDKeepLocalEdit', apply)


if __name__ == '__main__':
    unittest.main()

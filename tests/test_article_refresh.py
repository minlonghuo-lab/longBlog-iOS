"""Article refresh UI contracts; no server, credentials, or real notes needed."""
import unittest
from pathlib import Path

CONTENT = (Path(__file__).resolve().parent.parent / "src" / "LBContent.m").read_text(encoding="utf-8")
POSTS = CONTENT.split("#pragma mark - Posts list", 1)[1].split("#pragma mark - Shuoshuo", 1)[0]


class ArticleRefreshContracts(unittest.TestCase):
    def test_pull_downloads_articles_not_deploy_status(self):
        pull = POSTS.split('- (void)pull:(UIRefreshControl *)rc', 1)[1].split('// Inactive updates', 1)[0]
        self.assertIn('[self syncArticles:rc]', pull)
        self.assertNotIn('refreshDeploy:', pull)

    def test_sync_finishes_refresh_on_success_failure_busy_and_unconfigured(self):
        fetch = POSTS.split('- (void)syncArticles:', 1)[1].split('- (void)showArticleError:', 1)[0]
        self.assertIn('if (_syncingArticles)', fetch)
        self.assertIn('if (!LBGitHub.shared.configured)', fetch)
        # Repeated pulls must not terminate an active auto-sync spinner early.
        self.assertIn('if (_syncingArticles) return;', fetch)
        self.assertIn('if (_articleOperation) { [refresh endRefreshing];', fetch)
        unconfigured = fetch.split('if (!LBGitHub.shared.configured)', 1)[1].split('NSUUID *operation', 1)[0]
        self.assertIn('[refresh endRefreshing]', unconfigured)
        self.assertIn('syncFromGitHub:', fetch)
        completion = fetch.split('syncFromGitHub:', 1)[1]
        self.assertIn('dispatch_async(dispatch_get_main_queue()', completion)
        self.assertIn('self->_articleSyncOperation != operation', completion)
        self.assertIn('_syncingArticles = NO', completion)
        self.assertIn('[refresh endRefreshing]', completion)
        self.assertIn('[self->_table.refreshControl endRefreshing]', completion)
        self.assertIn('error.localizedDescription', completion)
        self.assertIn('同步失败', completion)
        self.assertIn('文章与附件同步完成', completion)

    def test_feedback_updates_on_sync_state_and_failure_without_reloading_rows(self):
        reload = POSTS.split('- (void)reload {', 1)[1].split('- (NSInteger)', 1)[0]
        self.assertIn('[self updateArticleFeedback]', reload)
        self.assertNotIn('@"syncingArticles":', reload)
        self.assertNotIn('@"articleSyncMessage":', reload)
        feedback = POSTS.split('- (void)updateArticleFeedback {', 1)[1].split('- (void)syncArticles:', 1)[0]
        self.assertIn('_articleOperationMessage ?: _articleSyncMessage', feedback)
        self.assertIn('正在同步文章与附件…', feedback)
        self.assertIn('NSSymbolRotateEffect', feedback)
        self.assertIn('removeAllSymbolEffects', feedback)
        self.assertIn('_navSubtitleLabel.text = subText', feedback)
        self.assertNotIn('tableFooterView', feedback)
        self.assertNotIn('_articleStatusFooter', POSTS)
        self.assertIn('navigationItem.subtitle', feedback)
        self.assertNotIn('reloadData', feedback)
        self.assertNotIn('listArticles', feedback)

    def test_local_working_directory_is_the_only_list_source(self):
        self.assertNotIn('Trilium', POSTS)
        self.assertIn('NSArray *all = _articles ?: @[];', POSTS)
        self.assertIn('publishArticle:noteId done:finished', POSTS)
        self.assertIn('unpublishArticle:noteId done:finished', POSTS)
        self.assertIn('if (!published) [actions addObject:del]', POSTS)


if __name__ == "__main__":
    unittest.main()

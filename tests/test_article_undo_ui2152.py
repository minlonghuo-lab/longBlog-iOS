"""Article toolbar/feedback contracts, not UIKit runtime or actual undo writes."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONTENT = (ROOT/'src/LBContent.m').read_text()
POSTS = CONTENT.split('#pragma mark - Posts list',1)[1].split('#pragma mark - Shuoshuo',1)[0]

def method(name):
    text = POSTS.split('- (void)'+name,1)[1]
    return text.split('\n- (',1)[0]

class ArticleUndoUI(unittest.TestCase):
    def test_native_undo_next_to_review_only_when_staged(self):
        self.assertIn('systemImageNamed:@"arrow.uturn.backward"', POSTS)
        self.assertIn('_revertItem.accessibilityLabel = @"撤销所有未提交操作"', POSTS)
        update = method('updateRightBarButtons:(BOOL)animated')
        self.assertIn('_stagedArticles.count > 0',update)
        self.assertIn('@[ _reviewItem, _revertItem, _composeItem, _filterItem ]',update)
        self.assertIn(': @[ _composeItem, _filterItem ]',update)
        self.assertIn('_revertItem.enabled = !busy',update)
        self.assertIn('_reviewItem.enabled = !busy',update)

    def test_confirmation_freezes_selection_before_presenting(self):
        prompt = method('promptRevertStaged')
        self.assertLess(prompt.index('selection = [_stagedArticles copy]'),prompt.index('UIAlertController alertController'))
        self.assertIn('UIAlertActionStyleDestructive',prompt)
        self.assertIn('UIAlertActionStyleCancel',prompt)
        self.assertIn('已提交到云端的操作不会撤回',prompt)
        self.assertIn('新草稿及附件会保留',prompt)
        self.assertIn('completion:^{ [weakSelf revertStagedSelection:selection]; }',prompt)
        self.assertNotIn('forceSyncFromGitHub',prompt)

    def test_revert_operation_fences_stale_scan_and_handles_errors(self):
        revert = method('revertStagedSelection:')
        self.assertIn('++_articleLoadGeneration',revert)
        self.assertIn('revertStagedArticles:selection',revert)
        self.assertIn('self->_articleOperation != operation',revert)
        self.assertIn('self->_articleOperation = nil',revert)
        self.assertIn('[self loadArticles]',revert)
        self.assertIn('[self showArticleError:error]',revert)

    def test_footer_is_removed_not_just_hidden_on_success(self):
        for old in ('_articleStatusFooter', '_articleStatusLabel', '_articleActivity'):
            self.assertNotIn(old,POSTS)
        self.assertNotIn('tableFooterView',POSTS)
        feedback=method('updateArticleFeedback')
        self.assertIn('_navSubtitleLabel.text = subText',feedback)
        self.assertIn('NSSymbolRotateEffect',feedback)
        self.assertIn('正在同步文章与附件…',feedback)
        self.assertIn('@"exclamationmark.circle"',feedback)

if __name__=='__main__':
    unittest.main(verbosity=2)

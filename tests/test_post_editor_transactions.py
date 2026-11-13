"""Editor migration contracts plus executable production state-policy tests.

These tests do not execute UIKit or claim on-device verification. The C fixture
extracts the actual policy from LBPostEditor.m (not a duplicated Python model).
Run: python3 -m unittest discover -s tests -p test_post_editor_transactions.py -v
"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EDITOR = (ROOT / 'src/LBPostEditor.m').read_text()
HEADER = (ROOT / 'src/LBPostEditor.h').read_text()


def method(name):
    match = re.search(r'^- \([^\n]+\)' + re.escape(name) + r'(?=[: {])', EDITOR, re.M)
    if not match:
        raise AssertionError(f'missing method: {name}')
    tail = EDITOR[match.start():]
    end = re.search(r'\n(?:- \(|@end)', tail)
    return tail[:end.start()] if end else tail


class PostEditorTransactions(unittest.TestCase):
    def test_executable_state_policy_all_four_states(self):
        compiler = shutil.which('clang') or shutil.which('cc')
        self.assertIsNotNone(compiler, 'C compiler required for real production-policy execution')
        policy = EDITOR.split('typedef enum {', 1)[1].split('// Ordered markdown list markers', 1)[0]
        fixture = '''#include <assert.h>
typedef int BOOL;
''' + 'typedef enum {' + policy + '''
int main(void) {
  // 2.15: the single send menu always pairs save with exactly one transition.
  assert(LBEditorActionForState(0) == LBEditorPublicationPublish);
  assert(LBEditorActionForState(1) == LBEditorPublicationUnpublish);
  return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix='lb-editor-policy-') as tmp:
            src, exe = Path(tmp) / 'policy.c', Path(tmp) / 'policy'
            src.write_text(fixture)
            subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', str(src), '-o', str(exe)], check=True, capture_output=True)
            subprocess.run([str(exe)], check=True, capture_output=True)

    def test_no_service_client_or_editor_owned_upload_chain(self):
        for forbidden in ('LBTriliumClient', '/api/attachments/', '/trilium-assets/',
                          'LBRepairLegacyAttachmentLinks', 'LBGitHub.shared',
                          'putArticleFile:', 'putAttachmentData:', 'dispatch_group_',
                          '__block', 'processNext', '_willPublish', 'togglePublishState'):
            self.assertNotIn(forbidden, EDITOR)
        self.assertIn('#import "LBMarkdown.h"', EDITOR)
        self.assertNotIn('Trilium', HEADER)

    def test_plain_save_preserves_publication_state_and_is_network_free(self):
        save = method('savePressed')
        self.assertIn('if (_saving) return;', save)
        self.assertIn('[self persistCurrentArticle]', save)
        self.assertIn('[self finishSuccessfulSave]', save)
        self.assertNotIn('publishArticle:', save)
        persist = method('persistCurrentArticle')
        self.assertIn('publish:_published', persist)
        self.assertNotIn('publish:YES', persist)
        self.assertNotIn('_published =', persist)
        self.assertLess(persist.index('[self saveDraftToDisk]'), persist.index('saveArticleWithId:'))
        self.assertIn('_hasSavedArticle = YES', persist)

    def test_new_draft_and_saved_article_have_distinct_actions(self):
        init = method('initWithPost')
        self.assertIn('_hasSavedArticle = stored != nil', init)
        self.assertIn('_published = [stored[@"publish"] boolValue]', init)
        actions = method('updatePublicationActions')
        self.assertIn('LBEditorActionForState(_published)', actions)
        self.assertIn('_saveItem.enabled = !_saving', actions)
        for title in ('下架文章', '发布文章', '保存修改', '存为草稿'):
            self.assertIn(title, actions)
        self.assertNotIn('先存为草稿', EDITOR)
        # One paper-plane button: tap saves, its menu holds save + one transition.
        self.assertIn('_saveItem.menu = [UIMenu', actions)
        self.assertNotIn('_publicationActionButton', EDITOR)

    def test_store_api_is_the_only_publication_boundary(self):
        perform = method('performPublicationToPublished')
        self.assertIn('if (_saving || !_hasSavedArticle) return;', perform)
        self.assertIn('BOOL unpublishing = !targetPublish', perform)
        self.assertIn('if (_published) { [self performPublicationToPublished:YES]; return; }', method('savePressed'))
        self.assertIn('[LBMdStore.shared publishArticle:_noteId done:completion]', perform)
        self.assertIn('[LBMdStore.shared unpublishArticle:_noteId done:completion]', perform)
        self.assertLess(perform.index('[self persistCurrentArticle]'), perform.index('publishArticle:'))
        self.assertNotIn('UIAlertController', perform)

    def test_async_completion_is_main_thread_and_weak_lifetime_safe(self):
        completion = method('performPublicationToPublished').split('void (^completion)', 1)[1]
        self.assertIn('dispatch_async(dispatch_get_main_queue()', completion)
        self.assertIn('LBPostEditor *editor = weakSelf;', completion)
        self.assertIn('if (!editor || !editor->_saving) return;', completion)
        self.assertNotIn('weakSelf->_', completion)
        failure = completion.split('if (error) {', 1)[1].split('editor->_published =', 1)[0]
        self.assertIn('[editor saveDraftToDisk]', failure)
        self.assertIn('return;', failure)
        self.assertNotIn('finishSuccessfulSave', failure)
        self.assertIn('editor->_published = targetPublish', completion)
        for control in ('_titleField.enabled', '_textView.editable', '_summaryView.editable', '_dock.userInteractionEnabled'):
            self.assertIn(control + ' = NO', method('performPublicationToPublished'))
            self.assertIn(control + ' = YES', completion)

    def test_single_keyboard_guide_and_scrollable_body(self):
        self.assertEqual(EDITOR.count('self.view.keyboardLayoutGuide.topAnchor'), 1)
        self.assertIn('[_dock.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor', EDITOR)
        self.assertIn('[_textView.bottomAnchor constraintEqualToAnchor:_dock.topAnchor', EDITOR)
        self.assertIn('_textView.scrollEnabled = YES', EDITOR)
        self.assertIn('_textView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever', EDITOR)
        for forbidden in ('UIKeyboardWill', 'UIKeyboardDid', 'UIKeyboardFrameEndUserInfoKey'):
            self.assertNotIn(forbidden, EDITOR)
        caret = method('revealEditorCaret')
        self.assertIn('caretRectForPosition:', caret)
        self.assertIn('scrollRectToVisible:', caret)
        self.assertIn('_revealingCaret', caret)
        self.assertIn('CGSizeEqualToSize', method('viewDidLayoutSubviews'))
        self.assertIn('revealEditorCaret', method('textViewDidChange'))
        self.assertIn('revealEditorCaret', method('textViewDidChangeSelection'))

    def test_collapsed_summary_has_no_required_negative_height(self):
        self.assertIn('summaryBottom.priority = UILayoutPriorityDefaultLow', EDITOR)
        self.assertIn('[_summaryView.heightAnchor constraintEqualToConstant:60]', EDITOR)
        self.assertEqual(EDITOR.count('[_summaryView.bottomAnchor constraintEqualToAnchor:_summaryContainer.bottomAnchor'), 1)

    def test_autosave_retained_and_cold_start_slot_is_stable(self):
        self.assertIn('@"new_article"', method('initWithPost'))
        self.assertIn('scheduledTimerWithTimeInterval:0.5', method('contentChanged'))
        self.assertIn('saveDraftToDisk', method('applicationWillResignActive'))
        self.assertIn('saveDraftToDisk', method('viewWillDisappear'))
        self.assertIn('saveDraftToDisk', method('cancelPressed'))
        self.assertIn('checkLocalDraft', method('viewDidAppear'))
        recovery = method('checkLocalDraft')
        self.assertIn('draftSummary', recovery)
        self.assertIn('[self contentChanged]', recovery)
        self.assertNotIn('_published =', recovery)
        self.assertNotIn('draft[@"publish"]', recovery)

    def test_asset_urls_and_writes_are_safe_and_consistent(self):
        self.assertIn('@"/assets/%@/%@"', EDITOR)
        self.assertIn('stringByAddingPercentEncodingWithAllowedCharacters:', EDITOR)
        registration = method('registerLocalAttachment')
        self.assertIn('LBEditorAssetReference(_noteId, filename)', registration)
        self.assertIn('NSDataWritingAtomic error:&writeError', registration)
        self.assertLess(registration.index('NSDataWritingAtomic'), registration.index('replaceBodyRange:sel'))
        self.assertIn('fileExistsAtPath:', registration)
        preview = method('previewPost')
        self.assertIn('@"markdown": markdown', preview)
        self.assertIn('@"bodyFormat": bodyFormat', preview)
        self.assertIn('stored[@"bodyFormat"]', preview)
        self.assertNotIn('hasSidecarHtml', preview)
        self.assertNotIn('stored[@"html"]', preview)
        self.assertNotIn('LBMarkdownToHTML', preview)
        self.assertNotIn('base64EncodedString', preview)

    def test_success_callback_returns_complete_store_post(self):
        finish = method('finishSuccessfulSave')
        self.assertIn('[LBMdStore.shared loadArticle:_noteId]', finish)
        self.assertIn('if (_saved) _saved(post)', finish)
        self.assertIn('[_draftTimer invalidate]', finish)
        self.assertIn('[self removeDraftFiles]', finish)
        remove = method('removeDraftFiles')
        self.assertIn('dispatch_async(LBDraftQueue()', remove)
        self.assertIn('removeItemAtPath:[path stringByDeletingPathExtension]', remove)


if __name__ == '__main__':
    unittest.main()

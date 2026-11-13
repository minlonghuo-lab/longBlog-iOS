"""2.12 UI contracts + executable production guards; no notes/network/UIKit runtime.

Run: python3 -m unittest discover -s tests -p test_article_ui212.py -v
Add LB_UI212_STRICT_COMPILE=1 to compile ONLY LBContent.m/LBPostEditor.m
with the real iOS SDK, strict project warning flags, into temporary object files.
Complements the updated ui211/article_refresh contracts with executable
refresh-burst/late-callback guards and opt-in strict SDK object compilation.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONTENT = (ROOT / 'src/LBContent.m').read_text().split('#pragma mark - Shuoshuo')[0]
EDITOR = (ROOT / 'src/LBPostEditor.m').read_text()
HEADER = (ROOT / 'src/LBPostEditor.h').read_text()


def method(source, name):
    match = re.search(r'^- \([^\n]+\)' + re.escape(name) + r'(?=[: {])', source, re.M)
    if not match:
        raise AssertionError(f'missing method: {name}')
    tail = source[match.start():]
    end = re.search(r'\n(?:- \(|@end)', tail)
    return tail[:end.start()] if end else tail


class ArticleUI212(unittest.TestCase):
    def test_card_dates_are_exactly_two_date_only_fields(self):
        self.assertIn('formatter.dateFormat = @"yyyy-MM-dd"', CONTENT)
        self.assertIn('NSCalendarIdentifierGregorian', CONTENT)
        self.assertIn('formatter.timeZone = NSTimeZone.localTimeZone', CONTENT)
        self.assertNotIn('HH:mm', CONTENT)
        card = method(CONTENT, 'tableView:(UITableView *)t cellForRowAtIndexPath')
        self.assertIn('c.metaLabel.text = [NSString stringWithFormat:@"发布：%@    更新：%@", LBArticleTimestamp(pubTs), LBArticleTimestamp(updTs)];', card)
        self.assertIn('c.metaLabel.text = [NSString stringWithFormat:@"创建：%@    更新：%@", LBArticleTimestamp(creTs), LBArticleTimestamp(updTs)];', card)
        self.assertIn('pubTs = published > 0 ? published : created', card)
        self.assertIn('c.metaLabel.numberOfLines = 1', card)
        self.assertNotIn('stringByAppendingFormat', card)
        self.assertNotIn('HTML保真', CONTENT)
        self.assertNotIn('LBRelativeTime(', CONTENT)

    def test_swipe_completes_immediately_and_reports_async_result(self):
        swipe = method(CONTENT, 'tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath')
        transition = swipe.split('UIContextualAction *transition =', 1)[1].split('transition.backgroundColor', 1)[0]
        self.assertIn('title:published ? @"下架文章" : @"发布"', transition)
        self.assertLess(transition.index('[self updateArticleFeedback]'), transition.index('done(YES)'))
        self.assertLess(transition.index('done(YES)'), transition.index('publishArticle:'))
        self.assertNotIn('done(error == nil)', transition)
        self.assertIn('dispatch_async(dispatch_get_main_queue()', transition)
        self.assertIn('self->_articleOperation != operation', transition)
        self.assertIn('self->_articleOperation = nil', transition)
        self.assertIn('stringByAppendingString:@"成功"', transition)
        self.assertIn('失败：%@ · 本地内容已保留', transition)

    def test_busy_feedback_not_percentage_or_full_table_reload(self):
        feedback = method(CONTENT, 'updateArticleFeedback')
        for text in ('NSSymbolRotateEffect', 'removeAllSymbolEffects', '_navSubtitleLabel.text = subText', 'navigationItem.subtitle'):
            self.assertIn(text, feedback)
        self.assertNotIn('tableFooterView', feedback)
        self.assertNotIn('reloadData', feedback)
        self.assertNotIn('listArticles', feedback)
        self.assertNotIn('UIProgressView', CONTENT + EDITOR)
        self.assertNotIn('setProgress:', CONTENT + EDITOR)
        reload = method(CONTENT, 'reload')
        self.assertNotIn('@"syncingArticles":', reload)
        self.assertNotIn('@"articleSyncMessage":', reload)
        self.assertIn('if ([_renderKey isEqual:key]) return', reload)

    def test_sync_coalesces_and_finishes_auto_sync_pull_indicator(self):
        sync = method(CONTENT, 'syncArticles')
        self.assertNotIn('[self reload]', sync)
        self.assertEqual(sync.count('[self loadArticles]'), 1)
        self.assertIn('[self->_table.refreshControl endRefreshing]', sync)
        self.assertIn('文章与附件同步完成', sync)
        self.assertIn('同步失败', sync)
        self.assertIn('if (_syncingArticles) return;', sync)
        self.assertNotIn('listArticles', method(CONTENT, 'pull'))
        notifications = method(CONTENT, 'articlesDidChange')
        self.assertNotIn('listArticles', notifications)
        self.assertIn('_articlesDirty = YES', notifications)
        self.assertIn('generation != self->_articleLoadGeneration', notifications)
        self.assertNotIn('name:LBSiteDataDidChange', CONTENT)
        self.assertEqual(CONTENT.count('[LBMdStore.shared listArticles]'), 1)

    def test_editor_spinner_and_explicit_failure_do_not_present_progress_alert(self):
        perform = method(EDITOR, 'performPublicationToPublished')
        self.assertIn('[spinner startAnimating]', perform)
        self.assertIn('editor.navigationItem.rightBarButtonItem = editor->_saveItem', perform)
        self.assertIn('正在同步文章与附件到 GitHub…', perform)
        self.assertIn('editor->_operationStatusLabel.textColor = UIColor.systemRedColor', perform)
        for text in ('下架文章失败', '更新文章失败', '发布文章失败', '编辑已保存在本地'):
            self.assertIn(text, perform)
        self.assertNotIn('UIAlertController', perform)
        self.assertNotIn('showEditorError:', perform)
        self.assertIn('dispatch_async(dispatch_get_main_queue()', perform)
        self.assertIn('editor->_publicationOperation != operation', perform)
        self.assertIn('![editor->_noteId isEqualToString:noteId]', perform)

    def test_editor_success_is_visible_after_dismissal(self):
        finish = method(EDITOR, 'finishSuccessfulSave')
        for text in ('LBPostEditorDidFinish', 'userInfo:@{@"message": message}',
                     'UIAccessibilityAnnouncementNotification', '_closed = YES'):
            self.assertIn(text, finish)
        self.assertIn('LBPostEditorDidFinish', HEADER)
        self.assertIn('name:LBPostEditorDidFinish', CONTENT)
        perform = method(EDITOR, 'performPublicationToPublished')
        for text in ('下架文章成功，本地草稿已保留', '文章更新成功', '文章发布成功'):
            self.assertIn(text, perform)
        self.assertIn('@"草稿保存成功"', finish)

    def test_single_source_preview_keeps_html_format_while_editing(self):
        preview = method(EDITOR, 'previewPost')
        self.assertIn('stored[@"bodyFormat"]', preview)
        self.assertIn('_original[@"bodyFormat"]', preview)
        self.assertIn('@"bodyFormat": bodyFormat', preview)
        self.assertIn('@"markdown": markdown', preview)
        for forbidden in ('unchangedBody', 'losslessPreview', 'hasSidecarHtml',
                          'hasHTMLSidecar', 'stored[@"html"]', 'LBMarkdownToHTML',
                          'LBHTMLToMarkdown', 'base64EncodedString'):
            self.assertNotIn(forbidden, preview)
        initial = method(EDITOR, 'populateInitialData')
        self.assertIn('_original[@"markdown"]', initial)
        self.assertNotIn('LBHTMLToMarkdown', initial)

    def test_saves_never_unpublish_and_new_draft_action_stays_hidden(self):
        save = method(EDITOR, 'savePressed')
        self.assertIn('if (_published) { [self performPublicationToPublished:YES]; return; }', save)
        self.assertIn('publish:_published', method(EDITOR, 'persistCurrentArticle'))
        actions = method(EDITOR, 'updatePublicationActions')
        self.assertIn('_saveItem.menu = [UIMenu', actions)
        self.assertNotIn('_publicationActionButton', EDITOR)
        self.assertIn('_cancelItem.enabled = !_saving', actions)
        self.assertNotIn('先存为草稿', EDITOR)
        self.assertNotIn('从博客撤下', CONTENT + EDITOR)

    def test_late_attachment_and_cancel_are_identity_guarded(self):
        picker = method(EDITOR, 'picker')
        for text in ('__weak typeof(self) weakSelf', 'editor->_closed', 'editor->_saving',
                     'generation != editor->_attachmentGeneration', 'isEqualToString:noteId'):
            self.assertIn(text, picker)
        self.assertIn('_closed = YES', method(EDITOR, 'cancelPressed'))
        self.assertIn('++_attachmentGeneration', method(EDITOR, 'savePressed'))
        self.assertIn('++_attachmentGeneration', method(EDITOR, 'performPublicationToPublished'))

    def test_down_confirmation_finishes_dismissal_before_local_validation(self):
        self.assertIn('dismissViewControllerAnimated:YES completion:^{ [weakSelf performPublication]; }',
                      method(EDITOR, 'publicationPressed'))

    def test_executable_production_refresh_and_callback_guards(self):
        """Compile actual production guard expressions, not a Python state replica."""
        compiler = shutil.which('clang') or shutil.which('cc')
        self.assertIsNotNone(compiler)
        notified = method(CONTENT, 'articlesDidChange')
        dirty_guard = re.search(r'if \((_syncingArticles \|\|[^\n]+)\) return;', notified).group(1)
        load = method(CONTENT, 'loadArticles')
        load_guard = re.search(r'if \((_syncingArticles \|\|[^\n]+)\) return;', load).group(1)
        picker = method(EDITOR, 'picker')
        callback_guard = re.search(r'if \((!editor \|\|[^\n]+)\) return;', picker).group(1)
        callback_guard = callback_guard.replace('![editor->_noteId isEqualToString:noteId]', '!sameNote')
        fixture = r'''
#include <assert.h>
#include <stdbool.h>
typedef struct { bool _closed, _saving; unsigned _attachmentGeneration; } Editor;
static int syncs, mutations, scans;
static bool defer_notification(bool _syncingArticles, bool _articleOperation,
                               bool _visible, bool _articleLoadScheduled) {
  if (DIRTY_GUARD) return true;
  return false;
}
static bool defer_scan(bool _syncingArticles, bool _articleOperation,
                       bool _visible, bool _articles) {
  if (LOAD_GUARD) return true;
  return false;
}
static bool drop_attachment(Editor *editor, unsigned generation, bool sameNote) {
  if (CALLBACK_GUARD) return true;
  return false;
}
int main(void) {
  for (int i=0; i<256; ++i) {
    bool sync=i&1, mutation=i&2, visible=i&4, scheduled=i&8;
    bool deferred=defer_notification(sync, mutation, visible, scheduled);
    assert(deferred == (sync || mutation || !visible || scheduled));
    bool snapshot=i&16;
    assert(defer_scan(sync, mutation, visible, snapshot) ==
           (sync || mutation || (!visible && snapshot)));
  }
  // A burst of sync changes schedules zero scans; completion performs one scan.
  syncs=1;
  for (int i=0; i<10000; ++i)
    if (!defer_notification(syncs, mutations, true, false)) ++scans;
  assert(scans==0);
  syncs=0;
  if (!defer_scan(syncs, mutations, true, true)) ++scans;
  assert(scans==1);
  Editor e={false,false,7};
  assert(!drop_attachment(&e,7,true));
  assert(drop_attachment(0,7,true));
  assert(drop_attachment(&e,6,true));
  assert(drop_attachment(&e,7,false));
  e._saving=true; assert(drop_attachment(&e,7,true));
  e._saving=false; e._closed=true; assert(drop_attachment(&e,7,true));
  return 0;
}
'''
        fixture = fixture.replace('DIRTY_GUARD', dirty_guard).replace('LOAD_GUARD', load_guard).replace('CALLBACK_GUARD', callback_guard)
        with tempfile.TemporaryDirectory(prefix='lb-ui212-guards-') as tmp:
            src, exe = Path(tmp) / 'guards.c', Path(tmp) / 'guards'
            src.write_text(fixture)
            built = subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
                                    str(src), '-o', str(exe)], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            subprocess.run([str(exe)], check=True, capture_output=True)

    @unittest.skipUnless(os.getenv('LB_UI212_STRICT_COMPILE') == '1', 'opt-in real iOS SDK object compile')
    def test_strict_compile_only_modified_objc_translation_units(self):
        sdk = Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'
        self.assertTrue(sdk.exists())
        with tempfile.TemporaryDirectory(prefix='lb-ui212-objects-') as tmp:
            for filename in ('LBContent.m', 'LBPostEditor.m'):
                obj = Path(tmp) / (filename + '.o')
                result = subprocess.run(['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
                    '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc',
                    '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-nullability-completeness',
                    '-I', str(ROOT / 'src'), '-c', str(ROOT / 'src' / filename), '-o', str(obj)],
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertGreater(obj.stat().st_size, 0)


if __name__ == '__main__':
    unittest.main()

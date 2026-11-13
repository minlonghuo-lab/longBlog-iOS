"""Dirty-state regressions: source contracts plus offline behavioral fixtures.

Fixtures below are a reference model, NOT UIKit/ObjC execution. Source assertions
bind the compared fields, early-return ordering, recovery and account fences to
production. No SDK build, network, real drafts or user workspace writes occur.
"""
from copy import deepcopy
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
POST = (ROOT / 'src/LBPostEditor.m').read_text()
MEMO = (ROOT / 'src/LBMemosEditor.m').read_text()


def method(source, name):
    match = re.search(r'^- \([^\n]+?\)' + re.escape(name) + r'(?=[: {])', source, re.M)
    if not match:
        raise AssertionError('Missing method: ' + name)
    tail = source[match.start():]
    end = re.search(r'\n(?:- \(|@end|#pragma)', tail)
    return tail[:end.start()] if end else tail


def post_snapshot(state):
    # Projection keys are extracted from the production snapshot; values are
    # fixture values. This is deliberately not a claim of native execution.
    snapshot = method(POST, 'contentSnapshot').split('return @{', 1)[1]
    keys = re.findall(r'@"(\w+)"\s*:', snapshot)
    result = {key: deepcopy(state[key]) for key in keys}
    result['attachments'] = {
        name: data for name, data in state['attachments'].items()
        if '/assets/n/' + name in state['markdown']
    }
    return result


def memo_dirty(current, baseline):
    ids = list(dict.fromkeys(a['id'] for a in current['attachments'] if a.get('id')))
    old_ids = list(dict.fromkeys(a['id'] for a in baseline['attachments'] if a.get('id')))
    return (current['text'] != baseline['text'] or
            current['visibility'] != baseline['visibility'] or ids != old_ids or
            any(not a.get('id') for a in current['attachments']))


class DirtyBehaviorFixtures(unittest.TestCase):
    def test_article_every_content_field_changes_then_reverts(self):
        original = dict(title='标题', markdown='正文\n', summary='摘要', publish=True, attachments={})
        baseline = post_snapshot(original)
        self.assertEqual(set(baseline), {'title', 'markdown', 'summary', 'publish', 'attachments'})
        for field, value in [('title', '新标题'), ('markdown', '正文\n\n'), ('summary', ''), ('publish', False)]:
            with self.subTest(field=field):
                current = deepcopy(original)
                current[field] = value
                self.assertNotEqual(post_snapshot(current), baseline)
                current[field] = original[field]
                self.assertEqual(post_snapshot(current), baseline)

    def test_article_ui_actions_do_not_change_snapshot(self):
        original = dict(title='标题', markdown='正文', summary='', publish=False, attachments={})
        for event in ('cursor', 'selection', 'keyboard', 'preview', 'summaryExpanded'):
            current = deepcopy(original)
            current[event] = (17, 3)
            self.assertEqual(post_snapshot(current), post_snapshot(original))

    def test_article_attachment_insertion_undo_and_byte_changes(self):
        original = dict(title='标题', markdown='正文', summary='', publish=False, attachments={})
        current = deepcopy(original)
        current['attachments']['photo.jpg'] = b'one'
        # Recovery bytes left behind by undo are not content by themselves.
        self.assertEqual(post_snapshot(current), post_snapshot(original))
        current['markdown'] += '\n![x](/assets/n/photo.jpg)\n'
        self.assertNotEqual(post_snapshot(current), post_snapshot(original))
        inserted = post_snapshot(current)
        current['attachments']['photo.jpg'] = b'two'
        self.assertNotEqual(post_snapshot(current), inserted)
        current['markdown'] = original['markdown']
        self.assertEqual(post_snapshot(current), post_snapshot(original))

    def test_memo_edits_and_visibility_revert_to_clean(self):
        original = dict(text='说说', visibility='PRIVATE', attachments=[{'id': 7}])
        for field, value in [('text', '新说说'), ('visibility', 'PUBLIC'), ('attachments', [])]:
            current = deepcopy(original)
            current[field] = value
            self.assertTrue(memo_dirty(current, original))
            current[field] = original[field]
            self.assertFalse(memo_dirty(current, original))
        current = dict(original, cursor=5, selection=(0, 2), keyboard=True, preview=True)
        self.assertFalse(memo_dirty(current, original))

    def test_memo_pending_failed_missing_files_and_uploaded_ids(self):
        original = dict(text='', visibility='PRIVATE', attachments=[])
        for state in ('importing', 'ready', 'failed', 'missing'):
            current = deepcopy(original)
            current['attachments'] = [{'state': state, 'file': 'fixture-only'}]
            self.assertTrue(memo_dirty(current, original))
            current['attachments'] = []
            self.assertFalse(memo_dirty(current, original))
        current['attachments'] = [{'id': 8, 'state': 'ready'}]
        self.assertTrue(memo_dirty(current, original))

    def test_recovered_memo_compares_to_its_conflict_snapshot(self):
        old = dict(text='A', visibility='PRIVATE', attachments=[{'id': 7}])
        remote = dict(text='B', visibility='PUBLIC', attachments=[{'id': 9}])
        recovered = deepcopy(remote)
        self.assertTrue(memo_dirty(recovered, old))  # Cannot rebase onto remote B.
        self.assertFalse(memo_dirty(deepcopy(old), old))


class DirtySourceContracts(unittest.TestCase):
    def test_article_baseline_captured_before_recovery_and_refreshed_after_write(self):
        self.assertIn('_contentBaseline = [self contentSnapshot]', method(POST, 'populateInitialData'))
        persist = method(POST, 'persistCurrentArticle')
        self.assertLess(persist.index('if (!ok)'), persist.index('_contentBaseline ='))
        self.assertIn('![[self contentSnapshot] isEqual:_contentBaseline]', method(POST, 'hasContentChanges'))
        snapshot = method(POST, 'contentSnapshot')
        for value in ('_titleField.text', '_textView.text', '_summaryView.text', '@(_published)', 'att.data'):
            self.assertIn(value, snapshot)
        for ui in ('selectedRange', 'isFirstResponder', 'contentOffset', '_summaryExpanded'):
            self.assertNotIn(ui, snapshot)

    def test_article_selection_was_not_the_dirty_callback(self):
        for name in ('textViewDidChangeSelection', 'textViewDidBeginEditing', 'previewPost', 'toggleSummary'):
            code = method(POST, name)
            self.assertNotIn('[self contentChanged]', code)
            self.assertNotIn('_dirty =', code)
        self.assertNotIn('_dirty = YES', POST)

    def test_article_noop_save_skips_store_publish_notifications_and_callback(self):
        save = method(POST, 'savePressed')
        self.assertLess(save.index('![self hasContentChanges]'), save.index('persistCurrentArticle'))
        self.assertLess(save.index('[self cancelPressed]'), save.index('performPublicationToPublished'))
        self.assertNotIn('finishSuccessfulSave', save.split('_completionMessage = nil')[0])
        persist = method(POST, 'persistCurrentArticle')
        self.assertLess(persist.index('_hasSavedArticle && ![self hasContentChanges]'), persist.index('saveArticleWithId:'))
        self.assertIn('if (!_hasSavedArticle && ![self hasContentChanges]) [self writeDraftSnapshot]', persist)

    def test_article_real_autosave_is_debounced_and_revert_cancels_it(self):
        changed = method(POST, 'contentChanged')
        self.assertLess(changed.index('invalidate'), changed.index('hasContentChanges'))
        self.assertLess(changed.index('hasContentChanges'), changed.index('scheduledTimerWithTimeInterval:0.5'))
        draft = method(POST, 'saveDraftToDisk')
        self.assertLess(draft.index('hasContentChanges'), draft.index('writeDraftSnapshot'))
        self.assertIn('containsString:LBEditorAssetReference', method(POST, 'writeDraftSnapshot'))
        self.assertIn('dispatch_async(LBDraftQueue()', method(POST, 'removeDraftFiles'))
        self.assertIn('if (!_ownsDraft) return', method(POST, 'clearUnchangedDraft'))

    def test_article_cancel_and_interactive_dismiss_share_comparison(self):
        cancel = method(POST, 'cancelPressed')
        self.assertLess(cancel.index('endEditing:YES'), cancel.index('hasContentChanges'))
        self.assertIn('saveDraftToDisk', cancel)
        self.assertIn('[self cancelPressed]', method(POST, 'presentationControllerDidAttemptToDismiss'))
        self.assertIn('presentationController.delegate = self', method(POST, 'viewDidAppear'))
        for lifecycle in ('viewWillDisappear', 'applicationWillResignActive'):
            self.assertIn('saveDraftToDisk', method(POST, lifecycle))

    def test_identical_article_recovery_checks_attachment_bytes_read_only(self):
        check = method(POST, 'checkLocalDraft')
        self.assertLess(check.index('draftAttachmentsMatchCurrentContent'), check.index('UIAlertController'))
        self.assertIn('!_hasSavedArticle || !draft[@"noteId"]', check)
        compare = method(POST, 'draftAttachmentsMatchCurrentContent')
        for expected in ('containsString:LBEditorAssetReference', 'readOnlyAssetURLForNote:',
                         '!recovery.length || ![current isEqual:recovery]', 'key.lastPathComponent', 'filename.lastPathComponent'):
            self.assertIn(expected, compare)
        for forbidden in ('writeTo', 'removeItem', 'assetsFolderForNote:'):
            self.assertNotIn(forbidden, compare)
        restore = method(POST, 'restoreAttachmentsFromDraft')
        self.assertIn('existing && [LBEditorString(_contentBaseline[@"markdown"]) containsString:', restore)
        self.assertIn('_ownsDraft = NO', restore)
        self.assertNotIn('_published =', check)  # Recovery never authorizes publish.

    def test_article_revert_redo_preserves_attachment_recovery_queue_order(self):
        register = method(POST, 'registerLocalAttachment')
        self.assertIn('dispatch_async(LBDraftQueue()', register)
        self.assertIn('[recoveryBytes writeToFile:', register)
        write = method(POST, 'writeDraftSnapshot')
        for expected in ('attachmentData[att.key] = att.data', 'mediaSnapshot = [attachmentData copy]',
                         'fileExistsAtPath:file', '[mediaSnapshot[key] writeToFile:file atomically:YES]'):
            self.assertIn(expected, write)
        self.assertLess(write.index('dispatch_async(LBDraftQueue()'), write.index('writeToFile:file'))
        self.assertLess(write.index('writeToFile:file'), write.index('dataWithJSONObject:snapshot'))

    def test_memo_compares_actual_content_and_all_unuploaded_rows(self):
        compare = method(MEMO, 'hasContentChanges')
        for expression in ('[(_text.text ?: @"") isEqual:_initialText]',
                           '[_visibility isEqual:_initialVisibility]',
                           '[[self resourceIDs] isEqual:_initialIDs]', 'if (!a.resourceID) return YES'):
            self.assertIn(expression, compare)
        self.assertNotIn('_changed', MEMO)
        for ui in ('selectedRange', 'fraction', 'isFirstResponder'):
            self.assertNotIn(ui, compare)

    def test_memo_focus_preview_background_share_guarded_draft_writer(self):
        for caller in ('textViewDidEndEditing', 'backgrounding'):
            self.assertIn('persistDraft', method(MEMO, caller))
        self.assertIn('endEditing:YES', method(MEMO, 'showPreview'))
        persist = method(MEMO, 'persistDraft')
        self.assertLess(persist.index('![self accountCurrent]'), persist.index('hasContentChanges'))
        self.assertLess(persist.index('hasContentChanges'), persist.index('saveDraft:draft'))
        self.assertIn('_text.markedTextRange', persist)
        self.assertIn('![self hasContentChanges] && !_unknownOutcome', persist)
        clear = method(MEMO, 'clearUnchangedDraft')
        for guard in ('!_ownsDraft', '_unknownOutcome', '![self accountCurrent]'):
            self.assertIn(guard, clear)

    def test_memo_real_edits_debounce_but_revert_cancels_timer(self):
        changed = method(MEMO, 'changed')
        self.assertLess(changed.index('cancelPreviousPerformRequests'), changed.index('hasContentChanges'))
        self.assertLess(changed.index('hasContentChanges'), changed.index('afterDelay:1.0'))
        self.assertIn('clearUnchangedDraft', changed)

    def test_memo_noop_save_and_both_exit_paths_share_actual_comparison(self):
        for name in ('savePressed', 'beginSave'):
            code = method(MEMO, name)
            self.assertLess(code.index('![self accountCurrent]'), code.index('hasContentChanges'))
            self.assertIn('_original && ![self hasContentChanges] && !_unknownOutcome', code)
            self.assertIn('[self closeEditor]; return;', code)
        close = method(MEMO, 'closeEditor')
        self.assertIn('BOOL dirty = [self hasContentChanges] || _unknownOutcome', close)
        self.assertIn('!dirty && !_pendingImports', close)
        self.assertIn('[self finishClosing:NO]', close)
        self.assertNotIn('saveOriginal:', close)
        self.assertIn('[self closeEditor]', method(MEMO, 'presentationControllerDidAttemptToDismiss'))

    def test_memo_recovery_baseline_remains_original_A_not_remote_B(self):
        restore = method(MEMO, 'restoreDraft')
        for line in ('_original = [snapshot copy]', '_initialText = LBEditorString(_original[@"content"])',
                     '_initialVisibility = LBEditorVisibility(_original[@"visibility"])',
                     '_initialIDs = ids.array', '_draftSaved = [self hasContentChanges]'):
            self.assertIn(line, restore)
        self.assertIn('if (!_draftSaved) [self clearUnchangedDraft]', restore)
        persist = method(MEMO, 'persistDraft')
        self.assertIn('draft[@"originalSnapshot"] = _original', persist)
        self.assertIn('[stored[@"localFiles"] isEqual:files]', persist)
        self.assertIn('saveOriginal:_original', method(MEMO, 'uploadNext'))


if __name__ == '__main__':
    unittest.main(verbosity=2)

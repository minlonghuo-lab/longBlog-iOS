"""2.15 contracts: Notes-style toolbar, single send button, AI assistant,
memo preview parity and settings redesign.
Mostly source contracts; the list-marker regex is EXECUTED with the exact
pattern extracted from LBPostEditor.m, and changed sources are strict-compiled
against the iOS 26 SDK. No UIKit, network or device runtime is claimed.
Run: python3 -m unittest discover -s tests -p 'test_features215.py' -v
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src'
EDITOR = (SRC / 'LBPostEditor.m').read_text()
AI = (SRC / 'LBAI.m').read_text()
AIH = (SRC / 'LBAI.h').read_text()
SETTINGS = (SRC / 'LBSettings.m').read_text()
READER = (SRC / 'LBPostReader.m').read_text()
MEMO_EDITOR = (SRC / 'LBMemosEditor.m').read_text()
READER_JS = (ROOT / 'resources/Reader/reader.js').read_text()


def method(code, name):
    # Instance or class method; `name` may be a multi-part selector prefix.
    m = re.search(r'^[-+] \([^\n]+?\)' + re.escape(name) + r'(?=[: {])', code, re.M)
    if not m:
        raise AssertionError('missing method ' + name)
    tail = code[m.start():]
    end = re.search(r'\n(?:[-+] \(|@end|#pragma)', tail[1:])
    return tail[:end.start() + 1] if end else tail


def list_regex():
    raw = re.search(r'regularExpressionWithPattern:@"(\^\(\\\\s\*\)[^"]+)"', EDITOR).group(1)
    return re.compile(raw.replace('\\\\', '\\'))


class NotesToolbar(unittest.TestCase):
    def test_capsule_glass_toolbar_with_notes_order(self):
        self.assertIn('_toolbar.cornerConfiguration = [UICornerConfiguration capsuleConfiguration]', EDITOR)
        self.assertIn('UIStackViewDistributionEqualSpacing', EDITOR)
        setup = method(EDITOR, 'setupToolbarButtons')
        order = [setup.index(s) for s in ('@"textformat"', '@"checklist"', '@"tablecells"', '@"paperclip"', '@"sparkles"', '@"eye"', '@"keyboard.chevron.compact.down"')]
        self.assertEqual(order, sorted(order), 'Aa, checklist, table, attachment first like Notes')
        self.assertNotIn('UIScrollView', setup)  # no hidden overflow strip anymore

    def test_aa_swaps_keyboard_for_format_panel_and_back(self):
        toggle = method(EDITOR, 'toggleFormatPanel')
        self.assertIn('_textView.inputView = _formatPanel', toggle)
        self.assertIn('_textView.inputView = nil', toggle)
        self.assertIn('reloadInputViews', toggle)
        self.assertIn('UIInputViewStyleKeyboard', method(EDITOR, 'buildFormatPanel'))
        ended = method(EDITOR, 'textViewDidEndEditing')
        self.assertIn('_textView.inputView = nil', ended)

    def test_format_panel_contains_styles_inline_lists_and_blocks(self):
        panel = method(EDITOR, 'buildFormatPanel')
        for text in ('@"二级标题"', '@"三级标题"', '@"四级标题"', '@"正文"', '@"代码块"', '@"bold"', '@"italic"',
                     '@"strikethrough"', '@"list.bullet"', '@"list.number"', '@"checklist"',
                     '@"decrease.indent"', '@"increase.indent"', '@"提示卡片"', '@"公式"', '@"折叠"', '@"分割线"'):
            self.assertIn(text, panel)

    def test_line_edits_are_single_undoable_replacements(self):
        transform = method(EDITOR, 'transformSelectedLines')
        self.assertIn('replaceBodyRange:block withText:replacement', transform)
        self.assertNotIn('_textView.text =', transform)
        self.assertNotIn('__block', EDITOR)

    def test_list_marker_regex_behaviour(self):
        rx = list_regex()
        cases = {'- item': '- ', '* item': '* ', '12. item': '12. ', '- [ ] todo': '- [ ] ',
                 '- [x] done': '- [x] ', '> quote': '> ', '  - nested': '- '}
        for line, marker in cases.items():
            m = rx.match(line)
            self.assertIsNotNone(m, line)
            self.assertEqual(m.group(2), marker, line)
        for line in ('plain text', '#heading', '-no space', '1.no space'):
            self.assertIsNone(rx.match(line), line)
        self.assertEqual(rx.match('  - nested').group(1), '  ')
        self.assertEqual(rx.match('7. seven').group(3), '7')

    def test_return_continues_and_ends_lists(self):
        ret = method(EDITOR, "textView:(UITextView *)textView shouldChangeTextInRange")
        for text in ('markedTextRange', 'range.location != lineEnd', 'if (!rest.length)',
                     'integerValue] + 1', '@"- [ ] "', 'return NO;'):
            self.assertIn(text, ret)


class SingleSendButton(unittest.TestCase):
    def test_paper_plane_tap_saves_and_menu_offers_one_transition(self):
        load = method(EDITOR, 'viewDidLoad')
        self.assertIn('paperplane.fill', load)
        self.assertIn('initWithPrimaryAction:', load)
        self.assertIn('[weakSelf savePressed]', load)
        actions = method(EDITOR, 'updatePublicationActions')
        self.assertIn('_saveItem.menu =', actions)
        self.assertIn('[weakSelf publicationPressed]', actions)
        self.assertIn('UIMenuElementAttributesDestructive', actions)
        self.assertEqual(EDITOR.count('self.navigationItem.rightBarButtonItem = _saveItem'), 1)

    def test_new_article_can_publish_from_menu(self):
        pub = method(EDITOR, 'publicationPressed')
        self.assertIn('if (_saving || _closed) return;', pub)
        self.assertNotIn('!_hasSavedArticle', pub)
        self.assertLess(pub.index('persistCurrentArticle'), pub.index('stagePublishArticle'))
        self.assertLess(pub.index('stageUnpublishArticle'), pub.index('_published = targetPublish'))

    def test_spinner_replaces_and_restores_send_button(self):
        perform = method(EDITOR, 'performPublicationToPublished')
        self.assertIn('initWithCustomView:spinner', perform)
        self.assertIn('editor.navigationItem.rightBarButtonItem = editor->_saveItem', perform)


class DraftPerformance(unittest.TestCase):
    def test_autosave_serializes_off_main_on_one_serial_queue(self):
        save = method(EDITOR, 'saveDraftToDisk')
        self.assertIn('if (![self hasContentChanges])', save)
        self.assertIn('[self writeDraftSnapshot]', save)
        writer = method(EDITOR, 'writeDraftSnapshot')
        self.assertIn('dispatch_async(LBDraftQueue()', writer)
        self.assertLess(writer.index('NSDictionary *snapshot = [draft copy]'), writer.index('dispatch_async'))
        self.assertIn('DISPATCH_QUEUE_SERIAL', EDITOR)
        self.assertIn('dispatch_async(LBDraftQueue()', method(EDITOR, 'removeDraftFiles'))
        self.assertIn('dispatch_sync(LBDraftQueue(), ^{})', method(EDITOR, 'checkLocalDraft'))
        self.assertNotIn('removeItemAtPath:self->_draftPath', EDITOR)


class AIAssistant(unittest.TestCase):
    def test_key_only_in_keychain_and_https_endpoint(self):
        self.assertIn('[LBKeychain set:', AI)
        self.assertIn('@"ai-api-key"', AI)
        self.assertNotIn('LBAIKeychainAccount]; [NSUserDefaults', AI)
        self.assertNotRegex(AI, r'setObject:[^\n]*apiKey')
        endpoint = method(AI, 'endpointForBase')
        for text in ('@"https"', 'c.user', 'c.password', 'c.query', '@"/chat/completions"'):
            self.assertIn(text, endpoint)
        for logging in ('NSLog(', 'printf(', 'os_log('):
            self.assertNotIn(logging, AI)

    def test_streaming_sse_and_non_stream_fallback(self):
        for text in ('@"stream": @YES', 'text/event-stream', '@"data:"', '@"[DONE]"', '@"delta"', '@"message"',
                     'ephemeralSessionConfiguration', 'Bearer '):
            self.assertIn(text, AI)
        # Preparation is asynchronous: the returned token cancels the stream,
        # including pending validation and task creation, not a captured task.
        self.assertIn('return ^{ [stream cancel]; };', AI)
        self.assertIn('@property (atomic) BOOL cancelled;', AI)
        self.assertIn('if (self.cancelled) return;', AI)
        self.assertIn('self.cancelled || _completionQueued || _finished', AI)
        self.assertIn('if (!self.cancelled && self.done)', AI)

    def test_errors_never_include_key_or_request(self):
        msg = AI.split('static NSString *LBAIServerMessage', 1)[1].split('#pragma mark', 1)[0]
        self.assertNotIn('Authorization', msg)
        self.assertIn('substringToIndex:160', msg)

    def test_result_sheet_streams_and_apply_is_generation_guarded(self):
        start = method(AI, 'start')
        self.assertIn('me->_generation != generation', start)
        self.assertIn('textStorage appendAttributedString', start)
        self.assertIn('[self stop]', method(AI, 'applyResult'))
        self.assertIn('[self stop]', method(AI, 'viewDidDisappear'))

    def test_editor_actions_cover_summary_and_body(self):
        menu = method(EDITOR, 'aiMenuElements')
        for text in ('生成摘要', '润色摘要', '润色所选文字', '润色全文', '从光标处续写', '自定义指令', 'LBPresentSettings'):
            self.assertIn(text, menu)
        self.assertIn('UIDeferredMenuElement elementWithUncachedProvider', EDITOR)

    def test_apply_never_overwrites_concurrent_edits(self):
        apply = method(EDITOR, 'applyAIText')
        self.assertIn('isEqualToString:original', apply)
        self.assertIn('insertTextAtCursor:text', apply)
        self.assertIn('LBAIMaxInput', method(EDITOR, 'aiPolishBody'))

    def test_settings_card_probe_and_validation(self):
        load = method(SETTINGS, 'viewDidLoad')
        for text in ('@"AI 写作助手"', '_aiBase', '_aiModel', '_aiKey'):
            self.assertIn(text, load)
        save = method(SETTINGS, 'saveAndTest')
        self.assertIn('[LBAI endpointForBase:aiBase]', save)
        self.assertIn('maxTokens:1', save)
        self.assertIn('LBAI.shared.apiKey = aiKey', save)
        self.assertIn('[LBAI.shared.apiKey ?: @"" isEqualToString:aiKey]', save)


class MemoPreviewParity(unittest.TestCase):
    def test_memo_preview_uses_site_article_style_but_keeps_memo_safety(self):
        self.assertIn("const article = !data.isMemo || data.memoSiteStyle === true;", READER_JS)
        self.assertIn("if (data.isMemo) return doc.createTextNode('[图片请在附件区预览]');", READER_JS)
        self.assertIn("const resourceBase = !data.isMemo ? str(data.resourceBase) : '';", READER_JS)
        self.assertIn('@"memoSiteStyle":@([self memoPreview])', READER)

    def test_memo_editor_presents_preview_sheet_like_article_editor(self):
        preview = method(MEMO_EDITOR, 'showPreview')
        self.assertIn('presentViewController:nav animated:YES', preview)
        self.assertNotIn('pushViewController', preview)

    def test_previews_have_done_and_no_publish_menu(self):
        self.assertIn('[_post[@"isEditorPreview"] boolValue]) {', READER)
        self.assertIn('UIBarButtonSystemItemDone target:self action:@selector(closePreview)', READER)
        close = method(READER, 'closePreview')
        self.assertIn('dismissViewControllerAnimated', close)
        self.assertIn('popViewControllerAnimated', close)


class SettingsRedesign(unittest.TestCase):
    def test_sections_status_chips_and_filled_fields(self):
        load = method(SETTINGS, 'viewDidLoad')
        self.assertEqual(load.count('sectionHeader('), 8)
        self.assertIn('[self refreshStatus]', load)
        field = method(SETTINGS, 'field')
        self.assertIn('UIColor.tertiarySystemFillColor', field)
        self.assertIn('field.secureTextEntry = !field.secureTextEntry', field)

    def test_primary_button_pinned_above_keyboard(self):
        load = method(SETTINGS, 'viewDidLoad')
        self.assertIn('[_test.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor', load)
        self.assertEqual(load.count('keyboardLayoutGuide'), 1)
        self.assertIn('_resultCard.hidden', method(SETTINGS, 'show'))


class StrictCompile(unittest.TestCase):
    def test_new_and_changed_sources_strict_sdk26(self):
        sdk = Path(os.environ.get('IOS_SDK', Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'))
        if not shutil.which('clang') or not sdk.is_dir():
            self.skipTest('clang/iPhoneOS SDK not installed')
        for name in ('LBAI.m', 'LBPostEditor.m', 'LBSettings.m', 'LBPostReader.m', 'LBMemosEditor.m'):
            r = subprocess.run(['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
                                '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc', '-I', str(SRC),
                                '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-nullability-completeness',
                                '-fsyntax-only', str(SRC / name)], text=True, capture_output=True, timeout=300)
            self.assertEqual(r.returncode, 0, name + r.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)

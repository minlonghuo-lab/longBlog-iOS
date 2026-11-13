"""Editor 2.15.1 regressions. Source contracts plus executed extracted style table.
No UIKit runtime or real workspace writes are claimed.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
EDITOR = (ROOT / 'src/LBPostEditor.m').read_text()

def method(name):
    start = re.search(r'^- \([^\n]+?\)' + re.escape(name) + r'(?=[: {])', EDITOR, re.M)
    assert start, name
    rest = EDITOR[start.start():]
    end = re.search(r'\n(?:- \(|@end|#pragma)', rest[1:])
    return rest[:end.start() + 1] if end else rest

class EditorSafety(unittest.TestCase):
    def test_heading_labels_match_actual_markdown(self):
        panel = method('buildFormatPanel')
        styles = re.findall(r'@\[@"([^"]+)", @"([^"]*)", @\d+\]', panel)
        self.assertEqual(styles, [('二级标题', '## '), ('三级标题', '### '), ('四级标题', '#### '), ('正文', '')])
        self.assertIn('level - 2 : -1', method('refreshFormatPanelState'))

    def test_code_button_never_inserts_inline_or_objc_by_default(self):
        panel = method('buildFormatPanel')
        self.assertIn('@"代码块"', panel)
        self.assertNotIn('@"等宽"', panel)
        code = method('insertCode')
        self.assertIn('stringWithString:@"```"', code)
        self.assertIn('while ([selected containsString:fence])', code)
        self.assertNotIn('```objc', code)
        self.assertNotIn('withPrefix:@"`"', code)
        self.assertIn('placeholder:@"// 代码在此"', code)
        # Exercise the same fence-selection rule against nested Markdown.
        for selected in ('one line', 'a\nb', '```js\nx\n```', '````\n```\n````'):
            fence = '```'
            while fence in selected:
                fence += '`'
            self.assertNotIn(fence, selected)
            self.assertEqual((f'\n{fence}\n{selected}\n{fence}\n').count(fence), 2)

    def test_ai_deferred_menu_checks_keychain_off_main(self):
        setup = method('setupToolbarButtons')
        self.assertIn('checkConfigured:^(BOOL ready)', setup)
        self.assertIn('completion([weakSelf aiMenuElements:ready]', setup)
        self.assertNotIn('LBAI.shared.configured', method('aiMenuElements'))

    def test_numbered_list_requires_real_match(self):
        code = method('toggleListMarker')
        self.assertIn('numbered ? (m && [m rangeAtIndex:3].location != NSNotFound)', code)

    def test_whitespace_only_indent_cannot_substring_nsnotfound(self):
        code = method('toggleListMarker')
        self.assertIn('firstContent == NSNotFound ? line.length : firstContent', code)
        for line in (' ', '   ', '\t', ' \t ', '  text  '):
            first = next((i for i, c in enumerate(line) if not c.isspace()), len(line))
            self.assertTrue(line[:first].isspace())

    def test_publish_persists_before_transition_and_checks_failure(self):
        code = method('publicationPressed')
        self.assertLess(code.index('persistCurrentArticle'), code.index('stagePublishArticle'))
        self.assertIn('stageUnpublishArticle:_noteId error:&error', code)
        self.assertIn('if (!staged)', code)
        self.assertIn('_published = previousPublish', code)
        self.assertLess(code.index('if (!staged)'), code.index('_published = targetPublish'))

    def test_ai_custom_never_clips_text_that_will_be_replaced(self):
        code = method('aiRunCustom')
        self.assertIn('range.length > LBAIMaxInput', code)
        self.assertNotIn('[self aiClip:original]', code)
        self.assertLess(code.index('range.length > LBAIMaxInput'), code.index('substringWithRange:range'))

    def test_wrapping_clamps_invalid_selection(self):
        self.assertIn('sel.length > text.length - sel.location', method('wrapSelectionWithPrefix'))

if __name__ == '__main__':
    unittest.main(verbosity=2)

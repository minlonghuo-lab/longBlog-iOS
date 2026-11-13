import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EDITOR = (ROOT / 'src/LBPostEditor.m').read_text()
CONTENT = (ROOT / 'src/LBContent.m').read_text()


class EditorScroll2135(unittest.TestCase):
    def test_body_uses_exact_contiguous_layout(self):
        # Non-contiguous layout estimated contentSize and stopped scrolling early.
        self.assertIn('[UITextView textViewUsingTextLayoutManager:NO]', EDITOR)
        self.assertIn('_textView.layoutManager.allowsNonContiguousLayout = NO', EDITOR)
        self.assertNotIn('allowsNonContiguousLayout = YES', EDITOR)

    def test_placeholder_does_not_constrain_content_size(self):
        self.assertIn('_placeholder.topAnchor constraintEqualToAnchor:_textView.frameLayoutGuide.topAnchor', EDITOR)
        self.assertNotIn('_placeholder.trailingAnchor constraintEqualToAnchor:_textView.trailingAnchor', EDITOR)

    def test_writing_room_tracks_viewport(self):
        self.assertIn('viewport.height * 0.45', EDITOR)
        self.assertIn('inset.bottom = room', EDITOR)

    def test_toolbar_edits_in_place(self):
        self.assertIn('[_textView replaceRange:target withText:', EDITOR)
        self.assertEqual(len(re.findall(r'_textView\.text = \[', EDITOR)), 1)  # fallback only

    def test_dock_status_does_not_crush_toolbar(self):
        self.assertNotIn('[_dock.heightAnchor constraintEqualToConstant:44]', EDITOR)
        self.assertIn('[_toolbar.heightAnchor constraintEqualToConstant:52]', EDITOR)

    def test_symbol_effects(self):
        self.assertIn('NSSymbolBounceEffect bounceUpEffect', EDITOR)
        self.assertIn('NSSymbolReplaceContentTransition replaceDownUpTransition', EDITOR)
        self.assertIn('NSSymbolRotateEffect rotateClockwiseEffect', CONTENT)
        self.assertNotIn('transform.rotation.z', CONTENT)


if __name__ == '__main__':
    unittest.main()

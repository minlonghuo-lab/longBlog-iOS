import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORE = (ROOT / 'src/LBMdStore.m').read_text()
EDITOR = (ROOT / 'src/LBPostEditor.m').read_text()
READER = (ROOT / 'src/LBPostReader.m').read_text()
JS = (ROOT / 'resources/Reader/reader.js').read_text()


class ArchivePreview2136(unittest.TestCase):
    def test_containment_strips_private_consistently(self):
        # Pure string prefix comparison with /private normalized on both sides.
        # Avoids POSIX realpath(3) which fails with EPERM in iOS sandboxes on
        # security-scoped parent paths, and avoids URLByResolvingSymlinksInPath which
        # refuses to strip /private on non-existent destination targets.
        raw = STORE[STORE.index('static NSURL *MDRawURL(NSURL *root, NSString *relative) {'):]
        raw = raw[:raw.index('\n}\n')]
        self.assertIn('MDSafePathStripPrivate(root.path)', raw)
        self.assertIn('MDSafePathStripPrivate(url.path)', raw)
        self.assertNotIn('URLByResolvingSymlinksInPath', raw)
        self.assertIn('static NSString *MDSafePathStripPrivate(NSString *p)', STORE)
        self.assertIn('[p hasPrefix:@"/private/"]', STORE)

    def test_editor_sends_caret_anchor(self):
        self.assertIn('LBPreviewMarkdownWithAnchor(markdown, focus, anchor)', EDITOR)
        self.assertIn('@"previewAnchor": anchor', EDITOR)
        self.assertIn('closestPositionToPoint:top', EDITOR)
        fn = EDITOR[EDITOR.index('static NSString *LBPreviewMarkdownWithAnchor'):EDITOR.index('typedef enum {')]
        for guard in ('```', '~~~', '"$$"', 'fence', 'math'):
            self.assertIn(guard, fn)

    def test_reader_positions_preview_in_dom(self):
        self.assertIn('positionsPreviewInDOM', READER)
        self.assertIn('if ([self positionsPreviewInDOM]) return;', READER)
        self.assertIn("/^LBCARET[0-9A-F]{8}$/.test(marker)", JS)
        self.assertIn('initialTop(doc,send,str(data.initialTopGeneration),data.initialTopCancelled === true,previewTarget)', JS)


if __name__ == '__main__':
    unittest.main()

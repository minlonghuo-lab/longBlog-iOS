"""Source contracts + real iOS SDK syntax checks, NOT UIKit runtime tests."""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
VIEWER = (ROOT / 'src/LBDiagramPreview.m').read_text()
READER = (ROOT / 'src/LBPostReader.m').read_text()
MEMO = (ROOT / 'src/LBMemoContentView.m').read_text()
DETAIL = (ROOT / 'src/LBMemosDetail.m').read_text()

class Diagram18Tests(unittest.TestCase):
    def test_fit_is_native_safe_area_not_document_or_800px_minimum(self):
        for text in ('MIN(bounds.width / _diagramSize.width, bounds.height / _diagramSize.height)',
                     'self.view.safeAreaLayoutGuide', '[close.heightAnchor constraintGreaterThanOrEqualToConstant:44]',
                     '[_scroll.topAnchor constraintEqualToAnchor:bar.bottomAnchor',
                     '_scroll.minimumZoomScale = 1', '_scroll.maximumZoomScale = 5',
                     'doubleTap.numberOfTapsRequired = 2', 'accessibilityPerformEscape',
                     'prefersGrabberVisible = YES', '@selector(resetZoom)'):
            self.assertIn(text, VIEWER)
        self.assertNotIn('naturalWidth', VIEWER)

    def test_inert_bounded_image_no_network_no_bridge(self):
        for text in ('url.length > 8000000', 'svg.length > 2000000',
                     'data:image/svg+xml;charset=utf-8,', 'parser.shouldResolveExternalEntities = NO',
                     '++_nodes > 12000', '++_depth > 81', 'v[2] > 20000',
                     'default-src \'none\'', 'img-src data:', 'script-src \'none\'',
                     'allowsContentJavaScript = NO', 'WKWebsiteDataStore.nonPersistentDataStore',
                     'WKNavigationActionPolicyCancel'):
            self.assertIn(text, VIEWER)
        self.assertNotIn('addScriptMessageHandler', VIEWER)
        self.assertNotIn('loadRequest:', VIEWER)
        self.assertNotIn('NSURLSession', VIEWER)

    def test_native_readers_keep_nonce_mainframe_generation_and_exact_action(self):
        for source in (READER, MEMO):
            self.assertIn('message.frameInfo.mainFrame', source)
            self.assertIn('value', source)
            self.assertIn('8000000', source)
        self.assertLess(READER.index('body.count != 3'), READER.index('isEqualToString:@"diagram"'))
        self.assertIn('body.count != 4', MEMO)
        self.assertIn('currentRevision:[body[@"revision"] unsignedIntegerValue]', MEMO)
        self.assertIn('!_ready || !_visible', MEMO)
        self.assertIn('generation != self->_context', DETAIL)
        self.assertIn('if (self.resetDiagram) self.resetDiagram();', MEMO)
        self.assertIn('LBMemosDidChange', VIEWER)
        self.assertIn('_dataURL = nil', VIEWER)
        self.assertIn('[_image removeFromSuperview]', VIEWER)
        self.assertIn('value.length > 262144', READER)
        self.assertIn('value.length > 4096', READER)

    def test_strict_real_sdk_including_actual_helper_fixtures(self):
        sdk = Path(os.environ.get('IOS_SDK', Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'))
        if not shutil.which('clang') or not sdk.is_dir():
            self.skipTest('clang/iOS SDK missing; no native runtime claim')
        for name in ('src/LBDiagramPreview.m', 'src/LBPostReader.m', 'src/LBMemoContentView.m', 'src/LBMemosDetail.m', 'tests/DiagramBoundaryFixtures.m'):
            with self.subTest(source=name):
                command = ['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk), '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc', '-I', str(ROOT / 'src'), '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-nullability-completeness', '-fsyntax-only', str(ROOT / name)]
                result = subprocess.run(command, text=True, capture_output=True, timeout=180)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stderr, '')

if __name__ == '__main__':
    unittest.main(verbosity=2)

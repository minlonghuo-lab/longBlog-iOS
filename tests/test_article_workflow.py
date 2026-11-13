"""Cross-module contracts for native Markdown workflow; not UIKit runtime tests."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src'
class ArticleWorkflow(unittest.TestCase):
    def test_removed_service_has_no_client_or_network_callers(self):
        self.assertFalse((SRC/'LBTriliumClient.m').exists())
        self.assertFalse((SRC/'LBTriliumClient.h').exists())
        for p in SRC.glob('*'):
            if p.suffix in ('.m','.h'):
                self.assertNotIn('LBTriliumClient',p.read_text(),str(p))
                self.assertNotIn('/etapi/',p.read_text(),str(p))
    def test_settings_downloads_after_token_save_and_folder_selection(self):
        settings=(SRC/'LBSettings.m').read_text()
        self.assertEqual(settings.count('[LBMdStore.shared syncFromGitHub:'),2)
        self.assertNotIn('_trilium',settings)
    def test_editor_raw_preview_and_online_update_are_explicit(self):
        editor=(SRC/'LBPostEditor.m').read_text()
        preview=editor.split('- (void)previewPost {',1)[1].split('#pragma mark - Save',1)[0]
        self.assertIn('@"markdown": markdown',preview)
        self.assertIn('if (_published) { [self performPublicationToPublished:YES]; return; }',editor)
        self.assertIn('editor->_published = targetPublish',editor)
    def test_upgrade_adoption_requires_verified_equal_bytes_and_no_local_race(self):
        store=(SRC/'LBMdStore.m').read_text()
        self.assertIn('[localData isEqual:remoteData]',store)
        self.assertIn('[MDCanonicalReferences(left) isEqual:MDCanonicalReferences(right)]',store)
        self.assertIn('[MDDigest(localData) isEqual:self.before[local]]',store)
        self.assertIn('!self.records[local] && equivalent',store)
    def test_encoded_attachment_names_decode_once_with_component_guards(self):
        store=(SRC/'LBMdStore.m').read_text()
        self.assertIn('NSString *decoded = encoded.stringByRemovingPercentEncoding',store)
        self.assertIn('!MDPath(decoded) || [decoded containsString:@"/"]',store)
        self.assertIn('static size_t MDReferenceEnd',store)
    def test_failed_compile_cannot_reuse_stale_object(self):
        build=(ROOT/'tools/build_local.py').read_text()
        self.assertIn('if result.returncode == 0 and obj.exists() and obj.stat().st_size > 0',build)
        attempt=build.split('for attempt in range(4):',1)[1]
        self.assertLess(attempt.index('obj.unlink()'),attempt.index('subprocess.run(flags'))
if __name__=='__main__': unittest.main()

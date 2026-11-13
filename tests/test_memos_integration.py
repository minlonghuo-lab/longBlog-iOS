from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
def src(n):return (ROOT/'src'/n).read_text()
class MemosIntegration(unittest.TestCase):
 def test_connection_atomic_before_reset_notification(self):
  client=src('LBMemosClient.m');body=client.split('- (BOOL)configureBaseURL:')[1].split('- (NSString *)token')[0]
  self.assertLess(body.index('self->_baseURL ='),body.index('[self reset]'))
  self.assertLess(body.index('[LBKeychain set:key'),body.index('[self reset]'))
  views=src('LBMemosViews.m');self.assertIn('configureBaseURL:_base.text token:key',views)
  self.assertNotIn('api.baseURL =',views)
 def test_401_cannot_trigger_reverification_loop(self):
  s=src('LBMemosClient.m');self.assertIn('self.authenticationRequired = YES; self.user = nil; [self reset]',s)
  timeline=src('LBMemosTimeline.m');self.assertIn('if (client.authenticationRequired)',timeline)
  reset=timeline.split('if (_context != LBMemosClient.shared.generation) {')[1].split('NSDictionary *memo')[0]
  self.assertNotIn('[self refresh]',reset)
  self.assertIn('[_table reloadData]',reset)
 def test_identity_precedes_editor_and_draft_restore(self):
  compose=src('LBMemosTimeline.m').split('- (void)compose {')[1].split('- (void)pickTag')[0]
  self.assertLess(compose.index('if (!LBMemosClient.shared.user)'),compose.index('LBMemosEditor *editor'))
  self.assertIn('originalSnapshot',src('LBMemosClient.m'))
  self.assertIn('_original = [snapshot copy]',src('LBMemosEditor.m'))
 def test_private_preview_clears_on_account_change(self):
  self.assertIn('@"memosGeneration"',src('LBMemosViews.m'))
  reader=src('LBPostReader.m');self.assertIn('- (void)memosConnectionChanged:',reader)
  self.assertIn('if (![self memosPreviewCurrent]) return;',reader)
  self.assertIn('[_web removeFromSuperview]; _web = nil',reader)
 def test_full_photos_and_preview_frameworks(self):
  yaml=(ROOT/'project.yaml').read_text()
  for name in ['PhotosUI','UniformTypeIdentifiers','QuickLook']:self.assertIn(name,yaml)
 def test_search_pagination_scope_and_no_public_fallback(self):
  t=src('LBMemosTimeline.m');self.assertIn('搜索说说',t)
  self.assertIn('allState:self->_state text:@"" tag:@""',t)
  self.assertNotIn('LBSiteData.shared.memos',t)
if __name__=='__main__':unittest.main(verbosity=2)

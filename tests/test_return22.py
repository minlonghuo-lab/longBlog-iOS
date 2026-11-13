"""Source + event-order model regressions, not a UIKit crash/FPS reproduction."""
from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[1]
A=(R/'src/LBApp.m').read_text()
P=(R/'src/LBPostReader.m').read_text().split('#pragma mark - Weak bridge',1)[0]
class ReconcileModel:
 def __init__(self): self.stack={'posts':'reader','memos':'list'};self.active='posts';self.transition=None;self.policy='scroll';self.queued=False
 def schedule(self):self.queued=True
 def drain(self):
  if not self.queued:return
  self.queued=False
  if self.transition==self.active:return
  self.policy='scroll' if self.stack[self.active]=='reader' else 'never'
 def begin(self): self.transition=self.active
 def finish(self, cancelled=False):
  n=self.transition
  if not cancelled:self.stack[n]='list'
  self.transition=None;self.schedule()
class Return22(unittest.TestCase):
 def test_no_policy_changes_or_forced_layout_in_live_transition(self):
  will=A.split('willShowViewController:',1)[1].split('didShowViewController:',1)[0]
  self.assertNotIn('layoutIfNeeded',will);self.assertNotIn('self.tabBarMinimizeBehavior =',will)
  self.assertIn('animateAlongsideTransition:nil completion:',will)
  self.assertIn('if (!registered)',will)
 def test_reconciliation_reads_current_stack_and_coalesces(self):
  update=A.split('- (void)updateMinimizePolicy {',1)[1].split('- (void)viewDidLoad',1)[0]
  for x in ['_policyUpdateScheduled','dispatch_async(dispatch_get_main_queue()', '[owner activeTabViewController]', 'nav.topViewController', '_transitionNavigationController == nav','_applyingPolicy']:
   self.assertIn(x,update)
  self.assertNotIn('applyPolicyForViewController:vc',A.split('willShowViewController:',1)[1].split('@end',1)[0])
 def test_commit_cancel_and_tab_switch_orders(self):
  for cancel in [False,True]:
   m=ReconcileModel();m.begin();m.schedule();m.drain();self.assertEqual(m.policy,'scroll');m.finish(cancel);m.drain();self.assertEqual(m.policy,'scroll' if cancel else 'never')
  m=ReconcileModel();m.begin();m.active='memos';m.schedule();m.drain();self.assertEqual(m.policy,'never');m.finish(True);m.drain();self.assertEqual(m.policy,'never')
 def test_late_transition_revision_and_reader_actions_are_guarded(self):
  self.assertIn('revision != owner->_navigationRevision',A)
  reader=(R/'src/LBPostReader.m').read_text()
  for text in ['nav.topViewController == self', '!nav.transitionCoordinator', '!_rendered || ![self canActOnReader]', 'CGSizeEqualToSize(_fitViewport, _scroll.bounds.size)']:
   self.assertIn(text,reader)
 def test_preview_mutable_state_single_queue(self):
  self.assertIn('delegate:self delegateQueue:NSOperationQueue.mainQueue',P)
  self.assertIn('NSData *data = (!error && _accepted && _bytes.length) ? [_bytes copy] : nil',P)
  self.assertIn('dispatch_get_global_queue(QOS_CLASS_USER_INITIATED',P)
  self.assertIn('generation != owner->_imageGeneration',P)
  self.assertIn('_session = nil; _bytes = nil; _accepted = NO',P)
  self.assertIn('kCGImageSourceThumbnailMaxPixelSize:@2560',P)
if __name__=='__main__':unittest.main(verbosity=2)

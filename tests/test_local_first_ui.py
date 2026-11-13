"""Offline source contracts. No UIKit/FPS/network behavior is simulated."""
from pathlib import Path
import unittest
R=Path(__file__).resolve().parents[1]
def code(n):return (R/'src'/n).read_text()
class LocalFirstUI(unittest.TestCase):
 def test_cache_seed_and_background_poll_do_not_grant_identity(self):
  s=code('LBMemosTimeline.m')
  self.assertIn('cachedState:_state',s)
  self.assertIn('_hasLocalSeed',s)
  self.assertIn('if (_visible) [self loadCachedRows]',s)
  self.assertIn('scheduledTimerWithTimeInterval:30',s)
  self.assertIn('reconcileCacheNormal:',s)
  self.assertIn('UIApplicationWillResignActiveNotification',s)
  self.assertIn('if (![_lastRenderedRows isEqual:_display])',s)
  self.assertNotIn('_rows.description',s)
  self.assertIn('if (!LBMemosClient.shared.user)',s) # writes still await verified identity
 def test_image_success_is_just_image(self):
  s=code('LBMemoContentView.m')
  self.assertIn('if (!_imageResource) [self addArrangedSubview:name]',s)
  self.assertIn('row.status.hidden = row.imageResource',s)
  self.assertIn('row.button.hidden = row.imageResource',s)
  self.assertIn('row.status.hidden = NO; row.button.hidden = NO',s)
 def test_cache_originals_are_not_view_owned(self):
  s=code('LBMemoContentView.m')
  self.assertNotIn('removeItemAtURL:file',s)
  self.assertIn('invalidateCachedResource:row.resource',s)
  self.assertIn('cachedState:_memo',code('LBMemosDetail.m'))
 def test_media_tap_uses_native_player(self):
  self.assertIn('self.playMedia(item.resource)',code('LBMemoContentView.m'))
  self.assertIn('_content.installMedia =',code('LBMemosDetail.m'))
  self.assertIn('initWithResource:resource',code('LBMemosDetail.m'))
  self.assertNotIn('LBMemoMediaPlayer(resource)',code('LBMemosDetail.m'))
  self.assertNotIn('下载并播放音频',code('LBMemoContentView.m'))
if __name__=='__main__':unittest.main(verbosity=2)

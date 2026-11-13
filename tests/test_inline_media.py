"""Offline source integration contracts; no UIKit/AVKit runtime claim."""
from pathlib import Path
import unittest
R = Path(__file__).resolve().parents[1]
MEDIA = (R / 'src/LBMemoMedia.m').read_text()
DETAIL = (R / 'src/LBMemosDetail.m').read_text()
CONTENT = (R / 'src/LBMemoContentView.m').read_text()

class InlineMediaContracts(unittest.TestCase):
    def test_parent_contains_retains_and_removes_children(self):
        for text in ('NSMutableArray<LBMemoInlineMediaController *> *_mediaChildren',
                     '[self->_mediaChildren addObject:child]', '[self addChildViewController:child]',
                     '[host addSubview:child.view]', '[child didMoveToParentViewController:self]',
                     '[child invalidateMedia]', '[child willMoveToParentViewController:nil]',
                     '[child removeFromParentViewController]', '++_mediaEpoch',
                     'epoch != owner->_mediaEpoch', 'if (other != playing) [other pausePlayback]'):
            self.assertIn(text, DETAIL)
        self.assertNotIn('presentViewController:player', DETAIL)
        self.assertIn('_content.resetMedia =', DETAIL)
        self.assertIn('_content.installMedia =', DETAIL)

    def test_card_frame_stable_and_no_video_file_title(self):
        start = CONTENT.index('if (LBMemoPlayable(resource) && self.installMedia)')
        end = CONTENT.index('LBMemoAttachmentView *row', start)
        block = CONTENT[start:end]
        for text in ('9.0 / 16.0', 'constraintLessThanOrEqualToConstant:240',
                     'constraintEqualToConstant:88', 'self.installMedia(host, resource); continue;'):
            self.assertIn(text, block)
        self.assertNotIn('filename', block)
        self.assertIn('[_memo isEqual:memo] && _generation == generation', CONTENT)
        cache = CONTENT[CONTENT.index('- (void)cacheBecameAvailable:'):CONTENT.index('- (void)pumpDownloads')]
        self.assertNotIn('clearContentState', cache)
        self.assertNotIn('resetMedia', cache)

    def test_lazy_tap_only_setup_and_cache_only_poster(self):
        inline = MEDIA[MEDIA.index('@implementation LBMemoInlineMediaController'):]
        before_tap = inline[:inline.index('- (void)togglePlayback')]
        self.assertNotIn('LBMemoMediaPlayer(', before_tap)
        self.assertIn('if (!file.isFileURL) return;', before_tap)
        self.assertIn('generateCGImageAsynchronouslyForTime:', before_tap)
        self.assertIn('maximumSize = CGSizeMake(900, 506)', before_tap)
        self.assertIn('_media.inlineMode = YES', inline)
        self.assertIn('[self addChildViewController:_media]', inline)
        self.assertIn('[_media didMoveToParentViewController:self]', inline)
        self.assertIn('if (!self.inlineMode && !self.started && !self.closed)', MEDIA)
        self.assertEqual(inline.count('[player play]'), 1)

    def test_audio_native_controls_and_bounded_observation(self):
        for text in ('UISlider *_seek', 'CMTimeMakeWithSeconds(.5, 600)',
                     'removeTimeObserver:_timeObserver', 'AVPlayerItemStatusReadyToPlay',
                     '_seek.accessibilityLabel = @"音频播放进度"',
                     '_seek.accessibilityValue = _time.text', '@"暂停音频"',
                     'forKeyPath:@"rate"', 'removeObserver:self forKeyPath:@"rate"'):
            self.assertIn(text, MEDIA)
        self.assertNotIn('NSTimer', MEDIA)

    def test_fullscreen_same_player_and_hidden_stop(self):
        for text in ('willBeginFullScreenPresentationWithAnimationCoordinator:',
                     'willEndFullScreenPresentationWithAnimationCoordinator:',
                     'self.presentingFullscreen = YES', 'weakSelf.presentingFullscreen = NO',
                     '[_media closeMedia]', '[self discardPlayer]; if (!_audio) _play.hidden = NO',
                     '_resumeTime = position', 'UIApplicationWillResignActiveNotification'):
            self.assertIn(text, MEDIA)
        self.assertIn('child.isPresentingFullscreen', DETAIL)
        self.assertIn('if (fullscreen && !self.isMovingFromParentViewController', DETAIL)
        self.assertIn('if (_displayMemo && ![_displayMemo isEqual:_memo]) [self resetInlineMedia]', DETAIL)
        self.assertIn('if (self.resetMedia) self.resetMedia()', CONTENT)

    def test_theme_retry_cache_poster_and_foreground_recovery(self):
        for text in ('_audio ? LBTheme.accentSoft', '_name.textColor = LBTheme.ink',
                     '_play.tintColor = LBTheme.accent', '_media.inlineFailure =',
                     'self->_play.hidden = NO', '@"播放失败，点按重试"',
                     'name:UIApplicationDidBecomeActiveNotification', 'name:LBMemosCacheDidChange',
                     '- (void)cachedPosterAvailable:', '- (void)appBecameActive:'):
            self.assertIn(text, MEDIA)
        active = MEDIA[MEDIA.index('- (void)appBecameActive:'):MEDIA.index('- (void)appBecameInactive:')]
        self.assertIn('[self installTimeObserver]', active)
        self.assertNotIn(' play]', active)
        self.assertNotIn('colorWithRed:1 green:.96', MEDIA)

    def test_cancelled_fullscreen_and_discard_reset_owner_flag(self):
        begin = MEDIA.split('willBeginFullScreenPresentationWithAnimationCoordinator:')[1].split('willEndFullScreenPresentationWithAnimationCoordinator:')[0]
        self.assertIn('if (context.isCancelled) weakSelf.presentingFullscreen = NO', begin)
        discard = MEDIA.split('- (void)discardPlayer {')[1].split('- (void)invalidateMedia')[0]
        self.assertIn('self.presentingFullscreen = NO', discard)
        inactive = MEDIA.split('- (void)appBecameInactive:')[1].split('willBeginFullScreenPresentationWithAnimationCoordinator:')[0]
        self.assertIn('[self discardPlayer]', inactive)
        self.assertIn('_resumeTime = position', inactive)

    def test_any_transport_failure_invalidates_all_requests(self):
        fail = MEDIA[MEDIA.index('- (void)fail:'):MEDIA.index('- (void)stop {')]
        self.assertIn('[self stop]', fail)
        self.assertIn('requireAuthentication', MEDIA)
        self.assertNotIn('AVURLAssetHTTPHeaderFieldsKey', MEDIA)
        self.assertNotIn('removeItemAtURL:', MEDIA)

if __name__ == '__main__':
    unittest.main(verbosity=2)

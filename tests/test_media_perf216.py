"""Offline regression source contracts + explicit state/width specification fixtures.
No device playback, scrolling FPS, live requests, or production data are exercised.
The SDK test syntax-checks the actual four implementations when clang/SDK exist.
"""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src'
CARD, TIMELINE, MEDIA, AUDIO = [
    (SRC / name).read_text() for name in
    ('LBCard.m', 'LBMemosTimeline.m', 'LBMemoMedia.m', 'LBAudioCenter.m')
]


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class MediaPerf216Contracts(unittest.TestCase):
    def test_cold_read_only_seed_validates_before_cloud_probe(self):
        check = between(TIMELINE, '- (void)checkCloudChangesAndSyncIfNeeded {',
                        '- (void)becameActive:')
        self.assertLess(check.index('if (!client.user) { [self refresh]; return; }'),
                        check.index('[client checkLatestMemoState:'))
        fetch = between(TIMELINE, '- (void)fetch:', '- (void)changed:')
        self.assertIn('else [client validate:', fetch)
        self.assertIn('client.authenticationRequired', check)
        self.assertIn('_checkingCloud', check)
        self.assertIn('generation != client.generation', check)
        self.assertIn('request != self->_request', check)
        self.assertIn('self->_checkingCloud = NO', check)

    def test_thumbnail_hits_avoid_download_and_repeat_decode(self):
        thumb = between(TIMELINE, '- (void)loadThumbnail:', '- (void)populateThumbnails:')
        self.assertLess(thumb.index('[_thumbnails objectForKey:key]'),
                        thumb.index('downloadResource:resource'))
        self.assertIn('if (cached) { iv.image = cached; return; }', thumb)
        self.assertIn('if (waiters) { [waiters addObject:iv]; return; }', thumb)
        self.assertIn('[LBMemosDiskCache fingerprint:resource]', thumb)
        self.assertIn('(unsigned long)generation, fingerprint', thumb)
        self.assertIn('NSHashTable weakObjectsHashTable', thumb)
        self.assertIn('[_thumbnails setObject:img forKey:key cost:cost]', thumb.replace('self->', ''))

    def test_thumbnail_memory_decode_and_concurrency_are_bounded(self):
        for required in ('countLimit = 128', 'totalCostLimit = 24 * 1024 * 1024',
                         'maxConcurrentOperationCount = 2', '@autoreleasepool',
                         'kCGImageSourceThumbnailMaxPixelSize: @(360)',
                         'kCGImageSourceShouldCacheImmediately: @YES',
                         'CGImageGetBytesPerRow(thumb) * CGImageGetHeight(thumb)'):
            self.assertIn(required, TIMELINE)
        decode = between(TIMELINE, '[owner->_thumbnailQueue addOperationWithBlock:',
                         '- (void)populateThumbnails:')
        self.assertIn('CGImageSourceCreateThumbnailAtIndex', decode)
        self.assertIn('dispatch_async(dispatch_get_main_queue()', decode)
        self.assertIn('generation != LBMemosClient.shared.generation', decode)

    def test_identity_switch_purges_private_thumbnails_and_work(self):
        changed = between(TIMELINE, '- (void)changed:', '- (void)render {')
        for required in ('[_thumbnails removeAllObjects]', '[_thumbnailWaiters removeAllObjects]',
                         '[_thumbnailQueue cancelAllOperations]', '_checkingCloud = NO'):
            self.assertIn(required, changed)
        tap = between(TIMELINE, '- (void)thumbnailTapped:', '- (void)openImagePreview:')
        self.assertIn('owner->_visible && generation == LBMemosClient.shared.generation', tap)

    def test_chip_fit_keeps_originals_and_restores_at_final_width(self):
        fit = between(CARD, '- (void)fitChipsOnOneRow:', '- (void)setTrailingView:')
        self.assertNotIn('removeFromSuperview', fit)
        for required in ('for (UIView *chip in chips) chip.hidden = NO',
                         'chips[i].hidden = YES', 'if (v == _moreChip) continue',
                         '_lastChipAvailable == available'):
            self.assertIn(required, fit)
        layout = between(CARD, '- (void)layoutSubviews {', '- (void)fitChipsOnOneRow:')
        self.assertIn('self.contentView.bounds.size.width - 68', layout)
        config = between(CARD, '- (void)finishConfiguration {', '- (void)layoutSubviews {')
        self.assertIn('_lastChipAvailable = 0', config)

    def test_custom_fullscreen_dismiss_clears_owner_and_never_autoplays(self):
        custom = between(MEDIA, '@implementation LBMMFullscreenController', 'static const int64_t LBMMCap')
        self.assertIn('- (void)viewDidDisappear:', custom)
        self.assertIn('if (self.didClose) self.didClose()', custom)
        expand = between(MEDIA, '- (void)openFullscreenVideo {', '- (void)pinView:')
        for required in ('!_visible || ![self current]', 'parent.presentedViewController',
                         'self->_fullscreen != fullscreen', 'self.presentingFullscreen = NO',
                         'fullscreen.player = nil', 'completion:nil'):
            self.assertIn(required, expand)
        self.assertNotIn('rate = 1.0', expand)
        self.assertNotIn(' play]', expand)
        self.assertIn('if (parent.presentedViewController != pvc)', expand)

    def test_discard_also_tears_down_ancestor_presented_fullscreen(self):
        discard = between(MEDIA, '- (void)discardPlayer {', '- (void)invalidateMedia {')
        for required in ('self.presentingFullscreen = NO', '_fullscreen = nil',
                         'fullscreen.didClose = nil; fullscreen.player = nil',
                         '[fullscreen dismissViewControllerAnimated:NO', '[_media closeMedia]'):
            self.assertIn(required, discard)
        self.assertLess(discard.index('fullscreen.player = nil'), discard.index('dismissViewControllerAnimated:'))
        self.assertIn('[LBAudioCenter deactivatePlaybackForPlayer:_ratePlayer]', MEDIA)
        self.assertNotIn('[LBAudioCenter deactivatePlayback]', MEDIA)

    def test_audio_no_ducking_and_balanced_session_and_remote_targets(self):
        self.assertNotIn('AVAudioSessionCategoryOptionDuckOthers', AUDIO)
        self.assertIn('options:0 error:NULL', AUDIO)
        self.assertIn('AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation', AUDIO)
        self.assertIn('endReceivingRemoteControlEvents', AUDIO)
        self.assertNotIn('removeTarget:nil', AUDIO)
        for token in ('LBAudioPlayTarget', 'LBAudioPauseTarget', 'LBAudioToggleTarget'):
            self.assertIn('removeTarget:' + token, AUDIO)
        self.assertIn('[NSNotificationCenter.defaultCenter removeObserver:observer]', AUDIO)

    def test_audio_interruption_unplug_and_end_pause_without_auto_resume(self):
        observers = between(AUDIO, 'id interruption =', 'LBAudioObservers =')
        for required in ('AVAudioSessionInterruptionTypeBegan', 'AVAudioSessionRouteChangeNotification',
                         'AVAudioSessionRouteChangeReasonOldDeviceUnavailable',
                         'AVPlayerItemDidPlayToEndTimeNotification', '[p pause]', 'LBReleaseAudioSession()'):
            self.assertIn(required, observers)
        self.assertNotIn(' play]', observers)
        self.assertIn('if (LBAudioInterrupted) return NO', AUDIO)

    def test_audio_ownership_and_main_queue_fence_stale_callbacks(self):
        self.assertIn('static __weak AVPlayer *LBAudioPlayer', AUDIO)
        remote = between(AUDIO, '+ (MPRemoteCommandHandlerStatus)remoteAction:(NSInteger)action player:(AVPlayer *)player {',
                         '+ (void)updateNowPlayingWithTitle:')
        self.assertIn('dispatch_sync(dispatch_get_main_queue()', remote)
        self.assertIn('player != LBAudioPlayer || !player.currentItem', remote)
        scoped = between(AUDIO, '+ (void)deactivatePlaybackForPlayer:(AVPlayer *)player {',
                         '+ (void)deactivatePlayback {')
        self.assertIn('if (player && player == LBAudioPlayer)', scoped)
        update = between(AUDIO, '+ (void)updatePlaybackProgressWithPlayer:(AVPlayer *)player duration:(NSTimeInterval)duration {',
                         '+ (void)deactivatePlaybackForPlayer:(AVPlayer *)player {')
        self.assertIn('player != LBAudioPlayer', update)
        self.assertIn('if (player.rate == 0) LBReleaseAudioSession()', update)

    def test_strict_sdk_syntax_of_all_owned_implementations(self):
        sdk = Path(os.environ.get('IOS_SDK', Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'))
        if not shutil.which('clang') or not sdk.is_dir():
            self.skipTest('clang/iPhoneOS SDK unavailable; no runtime claim')
        for name in ('LBCard.m', 'LBMemosTimeline.m', 'LBMemoMedia.m', 'LBAudioCenter.m'):
            with self.subTest(source=name):
                result = subprocess.run([
                    'clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
                    '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc',
                    '-I', str(SRC), '-Wall', '-Wextra', '-Werror',
                    '-Wno-unused-parameter', '-Wno-nullability-completeness',
                    '-fsyntax-only', str(SRC / name),
                ], text=True, capture_output=True, timeout=180)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stderr, '')


class RegressionSpecificationFixtures(unittest.TestCase):
    """Explicit models documenting edge sequences, not an ObjC runtime test."""
    def test_preliminary_320_width_then_actual_width_restores_chips(self):
        widths = [70, 70, 70, 70]

        def fit(available):
            if sum(widths) + 6 * (len(widths) - 1) <= available:
                return list(range(len(widths))), 0
            used = 0
            keep = 0
            for width in widths:
                if keep and used + width + 42 > available:
                    break
                used += width + 6
                keep += 1
            return list(range(keep)), len(widths) - keep

        narrow, overflow = fit(320 - 68)
        self.assertEqual(narrow, [0, 1])
        self.assertEqual(overflow, 2)
        # A destructive fit would permanently leave only [0, 1, '+2'] here.
        self.assertEqual(fit(430 - 68), ([0, 1, 2, 3], 0))
        self.assertEqual(fit(320 - 68), (narrow, overflow))
        self.assertEqual(widths, [70, 70, 70, 70])

    def test_idle_audio_card_cannot_clear_new_owner(self):
        owner = 'new-playing-card'
        active = True

        def discard(player):
            nonlocal owner, active
            if player is not None and player == owner:
                owner, active = None, False

        discard(None)
        discard('old-paused-card')
        self.assertEqual(owner, 'new-playing-card')
        self.assertTrue(active)
        discard('new-playing-card')
        self.assertIsNone(owner)
        self.assertFalse(active)


if __name__ == '__main__':
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Offline contracts for v2.6 6-item targeted fixes and polish."""
from pathlib import Path
import unittest

SRC = Path(__file__).resolve().parents[1] / 'src'

def read(name):
    return (SRC / name).read_text()

class Fixes26Contracts(unittest.TestCase):
    def test_composer_buttons_symmetric_and_coordinated(self):
        chat = read('LBChat.m')
        self.assertIn('[quick.widthAnchor constraintEqualToConstant:38]', chat)
        self.assertIn('[quick.heightAnchor constraintEqualToConstant:38]', chat)
        self.assertIn('[_send.widthAnchor constraintEqualToConstant:38]', chat)
        self.assertIn('[_send.heightAnchor constraintEqualToConstant:38]', chat)
        self.assertIn('[quick.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:7]', chat)
        self.assertIn('[_send.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-7]', chat)
        self.assertIn('[quick.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-7]', chat)
        self.assertIn('[_send.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-7]', chat)

    def test_posts_title_and_summary_persistence_guard(self):
        content = read('LBContent.m')
        self.assertIn('title = p[@"slug"] ?: @"未命名文章"', content)
        self.assertIn('c.titleLabel.hidden = NO;', content)
        self.assertIn('summary = @"（暂无摘要）"', content)
        self.assertIn('c.bodyLabel.hidden = NO;', content)
        card = read('LBCard.m')
        self.assertIn('_titleLabel.hidden = NO;', card)
        self.assertIn('_head.hidden = NO;', card)
        self.assertIn('_bodyLabel.hidden = NO;', card)
        self.assertIn('_titleLabel.hidden = !_titleLabel.text.length;', card)
        self.assertIn('_head.hidden = !_titleLabel.text.length && _trailingHost.hidden;', card)

    def test_badges_clean_type_without_quantifiers(self):
        timeline = read('LBMemosTimeline.m')
        self.assertIn('LBChip(@"图片", LBTheme.muted)', timeline)
        self.assertIn('LBChip(@"视频", UIColor.systemPurpleColor)', timeline)
        self.assertIn('LBChip(@"音频", UIColor.systemOrangeColor)', timeline)
        self.assertIn('LBChip(@"附件", LBTheme.muted)', timeline)
        self.assertNotIn('1 图', timeline)
        self.assertNotIn('1 视频', timeline)
        self.assertNotIn('1 附件', timeline)

        content = read('LBContent.m')
        self.assertIn('LBChip(@"图片", LBTheme.muted)', content)
        self.assertNotIn('%lu 图', content)

    def test_video_fullscreen_magnification(self):
        media = read('LBMemoMedia.m')
        self.assertIn('_fullscreenBtn = [UIButton buttonWithConfiguration:', media)
        self.assertIn('openFullscreenVideo', media)
        self.assertIn('LBMMFullscreenController *pvc = [LBMMFullscreenController new];', media)
        self.assertIn('@interface LBMMFullscreenController : AVPlayerViewController', media)
        self.assertIn('pvc.didClose = ^{', media)
        self.assertNotIn('pvc.player.rate = 1.0', media)
        self.assertIn('pvc.showsPlaybackControls = YES;', media)
        self.assertIn('pvc.modalPresentationStyle = UIModalPresentationFullScreen;', media)
        self.assertIn('presentViewController:pvc animated:YES', media)

    def test_audio_dynamic_island_now_playing(self):
        media = read('LBMemoMedia.m')
        self.assertIn('setupNowPlaying', media)
        self.assertIn('updateNowPlaying', media)
        self.assertIn('teardownNowPlaying', media)
        self.assertIn('LBAudioCenter', media)

        audio = read('LBAudioCenter.m')
        self.assertIn('MPNowPlayingInfoCenter', audio)
        self.assertIn('MPRemoteCommandCenter', audio)
        self.assertIn('MPMediaItemPropertyTitle', audio)
        self.assertIn('MPMediaItemArtwork', audio)
        self.assertIn('AVAudioSessionCategoryPlayback', audio)

if __name__ == '__main__':
    unittest.main(verbosity=2)

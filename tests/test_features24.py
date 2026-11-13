#!/usr/bin/env python3
"""Offline source contracts for v2.4 5-feature batch enhancements."""
from pathlib import Path
import unittest

SRC = Path(__file__).resolve().parents[1] / 'src'

def read(name):
    return (SRC / name).read_text()

class Features24Contracts(unittest.TestCase):
    def test_cert_symmetric_capsule_layout(self):
        dash = read('LBDashboard.m')
        self.assertIn('status.layer.cornerRadius = 9;', dash)
        self.assertIn('contentRow.axis = UILayoutConstraintAxisHorizontal;', dash)
        self.assertIn('status.backgroundColor = [color colorWithAlphaComponent:0.14];', dash)
        self.assertIn('status.layer.borderColor = [color colorWithAlphaComponent:0.32].CGColor;', dash)

    def test_inbox_and_chat_enhancements(self):
        chat = read('LBChat.m')
        self.assertIn('updateBubbleShape', chat)
        self.assertIn('isFollowup', chat)
        self.assertIn('_bubbleTop.constant = isFollowup ? 1.0 : 3.0;', chat)
        self.assertIn('quick.menu = [UIMenu menuWithTitle:@"常用快捷回复"', chat)
        inbox = read('LBInbox.m')
        self.assertIn('contextMenuConfigurationForRowAtIndexPath', inbox)
        self.assertIn('checkmark.circle', inbox)
        self.assertIn('bubble.left.and.text.bubble.right', inbox)

    def test_timeline_thumbnail_grid(self):
        timeline = read('LBMemosTimeline.m')
        self.assertIn('populateThumbnails:', timeline)
        self.assertIn('buildThumbnailItem:', timeline)
        self.assertIn('cell.mediaStack addArrangedSubview:', timeline)
        card = read('LBCard.m')
        self.assertIn('_mediaStack', card)

    def test_fluid_gestures_and_haptics(self):
        reader = read('LBPostReader.m')
        self.assertIn('_panDismiss = [[UIPanGestureRecognizer alloc]', reader)
        self.assertIn('handlePanDismiss:', reader)
        self.assertIn('下滑退出', reader)
        app = read('LBApp.m')
        self.assertIn('UISelectionFeedbackGenerator', app)
        self.assertIn('[feedback selectionChanged];', app)

    def test_site_config_dock_and_friends(self):
        cfg = read('LBConfig.m')
        self.assertIn('subReview', cfg)
        self.assertIn('subRevert', cfg)
        self.assertIn('arrow.up.right', cfg)
        self.assertIn('LBOpenURL(weakOwner, link)', cfg)

if __name__ == '__main__':
    unittest.main(verbosity=2)

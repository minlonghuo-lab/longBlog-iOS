#!/usr/bin/env python3
"""Offline contracts ensuring all preview interfaces support swipe-down dismiss."""
from pathlib import Path
import unittest

SRC = Path(__file__).resolve().parents[1] / 'src'

def read(name):
    return (SRC / name).read_text()

class SwipeDismissContracts(unittest.TestCase):
    def test_reader_image_controller_pan_dismiss(self):
        reader = read('LBPostReader.m')
        self.assertIn('_panDismiss = [[UIPanGestureRecognizer alloc]', reader)
        self.assertIn('handlePanDismiss:', reader)
        self.assertIn('initWithLocalFile:', reader)
        self.assertIn('t.y > 60 || v.y > 450', reader)

    def test_memos_detail_uses_swipeable_image_controller(self):
        detail = read('LBMemosDetail.m')
        self.assertIn('LBReaderImageController', detail)
        self.assertIn('initWithLocalFile:file', detail)
        self.assertIn('isImg', detail)

    def test_timeline_thumbnails_open_swipeable_image_controller(self):
        timeline = read('LBMemosTimeline.m')
        self.assertIn('thumbnailTapped:', timeline)
        self.assertIn('openImagePreview:', timeline)
        self.assertIn('LBReaderImageController', timeline)

if __name__ == '__main__':
    unittest.main(verbosity=2)

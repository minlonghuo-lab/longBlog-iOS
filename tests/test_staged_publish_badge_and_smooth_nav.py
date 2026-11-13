import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTENT = (ROOT / 'src/LBContent.m').read_text()
READER = (ROOT / 'src/LBPostReader.m').read_text()


class StagedPublishBadgeAndSmoothNavTests(unittest.TestCase):
    def test_draft_staged_as_publish_shows_publishing_badge(self):
        # When a draft is staged for publishing, it must show [发布中…], never [已发布]
        self.assertIn('BOOL isStagedPublish = [activeOp isEqualToString:@"publish"];', CONTENT)
        self.assertIn('BOOL publishing = isStagedPublish || [activeOp isEqualToString:@"publishing"]', CONTENT)
        self.assertIn('BOOL publishedArticle = pubState && !isStagedPublish;', CONTENT)
        self.assertIn('[c.extraStack addArrangedSubview:LBChip(@"发布中…", UIColor.systemOrangeColor)];', CONTENT)
        self.assertIn('[c.extraStack addArrangedSubview:LBChip(@"已发布", [UIColor colorWithRed:0.1 green:0.75 blue:0.4 alpha:1.0])];', CONTENT)

    def test_reader_no_retry_flicker_on_publish_or_unpublish(self):
        # In finishPublication, DOM meta is updated smoothly without tearing down the webview via retry
        finish = READER[READER.index('- (void)finishPublication:(NSError *)error'):READER.index('- (void)publishCurrentPost')]
        self.assertNotIn('[self retry];', finish)
        self.assertIn('[self updateMetaTextInDOM];', finish)
        self.assertIn('UINotificationFeedbackGenerator', finish)

    def test_smooth_bar_button_items_animated_transition(self):
        # Buttons are retained and animated via setRightBarButtonItems:animated:
        self.assertIn('[self.navigationItem setRightBarButtonItems:targetItems animated:shouldAnimate];', CONTENT)
        self.assertIn('_composeItem = [[UIBarButtonItem alloc]', CONTENT)
        self.assertIn('_filterItem = [[UIBarButtonItem alloc]', CONTENT)
        self.assertIn('_reviewItem = [[UIBarButtonItem alloc]', CONTENT)

    def test_subtitle_fade_animation(self):
        self.assertIn('kCATransitionFade', CONTENT)
        self.assertIn('fadeSubtitle', CONTENT)

    def test_swipe_action_haptic_feedback(self):
        self.assertIn('UIImpactFeedbackGenerator', CONTENT)
        self.assertIn('UIImpactFeedbackStyleLight', CONTENT)


if __name__ == '__main__':
    unittest.main()

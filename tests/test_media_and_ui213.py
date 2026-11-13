"""Tests for longBlog v2.13:
1. PDF, audio, and video media rendering & adaptation (app + site).
2. Horizontal article card and reader detail dates with exact prefixes.
3. Removal of README.longblog.txt generation.
4. Removal of top and bottom edge scroll masks on article reader.
"""
from pathlib import Path
import os
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
site_env = os.environ.get('LONGBLOG_SITE_ROOT')
SITE_ROOT = Path(site_env).expanduser() if site_env else Path(__file__).resolve().parents[3]
READER = (ROOT / 'src/LBPostReader.m').read_text()
CONTENT = (ROOT / 'src/LBContent.m').read_text().split('#pragma mark - Shuoshuo')[0]
MD_STORE = (ROOT / 'src/LBMdStore.m').read_text()
READER_JS = (ROOT / 'resources/Reader/reader.js').read_text()
READER_HTML = (ROOT / 'resources/Reader/index.html').read_text()
READER_CSS = (ROOT / 'resources/Reader/article-adapter.css').read_text()
APP = (ROOT / 'src/LBApp.m').read_text()


class MediaAndUI213Tests(unittest.TestCase):
    def test_pdf_audio_video_allowed_in_reader_resources(self):
        self.assertIn('@"application/pdf"', READER)
        self.assertIn('@"video/mp4"', READER)
        self.assertIn('@"audio/mpeg"', READER)
        self.assertIn('256ULL * 1024 * 1024', READER)

    def test_remote_media_and_pdf_in_post_reader(self):
        self.assertIn('QLPreviewController *preview = [QLPreviewController new]', READER)
        self.assertIn('AVPlayerViewController *player = [AVPlayerViewController new]', READER)
        self.assertIn('downloadTaskWithURL:', READER)

    def test_reader_csp_allows_media(self):
        self.assertIn('media-src https: data: lbreader-resource: blob:;', READER_HTML)

    def test_reader_js_allows_audio_video_and_marks_pdf(self):
        self.assertIn('audio video source', READER_JS)
        self.assertIn('article-pdf-card', READER_JS)
        self.assertIn('rawHTMLBody', READER_JS)
        self.assertIn('dataset.isPdf', READER_JS)
        self.assertIn('.pdf', READER_JS)

    def test_reader_css_styles_pdf_and_media(self):
        self.assertIn('.article-pdf-card', READER_CSS)
        self.assertIn('.article-video', READER_CSS)
        self.assertIn('.article-audio', READER_CSS)

    def test_article_card_dates_are_horizontal_with_exact_prefixes(self):
        self.assertIn('c.metaLabel.text = [NSString stringWithFormat:@"发布：%@    更新：%@",', CONTENT)
        self.assertIn('c.metaLabel.text = [NSString stringWithFormat:@"创建：%@    更新：%@",', CONTENT)
        self.assertIn('c.metaLabel.numberOfLines = 1', CONTENT)

    def test_reader_dates_are_horizontal_with_exact_prefixes(self):
        self.assertIn('[NSString stringWithFormat:@"发布：%@    更新：%@", primary, update];', READER)
        self.assertIn('[NSString stringWithFormat:@"创建：%@    更新：%@", primary, update];', READER)
        self.assertIn('white-space:normal', READER_CSS.replace(' ', ''))

    def test_no_readme_generation_in_md_store(self):
        self.assertNotIn('writeToURL:[copy URLByAppendingPathComponent:@"README.longblog.txt"]', MD_STORE)
        self.assertNotIn('NSData *readme = [@"此目录由 longBlog 按篇归档', MD_STORE)

    def test_top_and_bottom_masks_removed_from_article_reader(self):
        self.assertIn('_web.scrollView.topEdgeEffect.hidden = YES;', READER)
        self.assertIn('_web.scrollView.bottomEdgeEffect.hidden = YES;', READER)
        self.assertIn('[_web.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]', READER)
        reader_reg = APP.split('BOOL isReader = [vc isKindOfClass:LBPostReaderViewController.class];', 1)[1].split('break;', 1)[0]
        self.assertIn('scroll.topEdgeEffect.hidden = YES;', reader_reg)
        self.assertIn('scroll.bottomEdgeEffect.hidden = YES;', reader_reg)

    def test_editor_keyboard_handling_and_shortcuts(self):
        editor = (ROOT / 'src/LBPostEditor.m').read_text()
        self.assertIn('_textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive', editor)
        self.assertIn('UIEdgeInsetsMake(16, 8, 16, 8)', editor)
        self.assertIn('UIEdgeInsetsMake(0, 0, 120, 0)', editor)
        self.assertIn('handleBackgroundTap', editor)
        self.assertIn('insertCallout', editor)
        self.assertIn('insertTable', editor)
        self.assertIn('insertLink', editor)
        self.assertIn('insertStrikethrough', editor)
        self.assertIn('insertDetails', editor)
        self.assertIn('transformSelectedLines', editor)
        self.assertIn('toggleFormatPanel', editor)

    def test_unified_media_cards_in_reader(self):
        self.assertIn('.article-video-card', READER_CSS)
        self.assertIn('.article-audio-card', READER_CSS)
        self.assertIn('.article-file-card', READER_CSS)
        self.assertIn('dataset.isVideo', READER_JS)
        self.assertIn('dataset.isAudio', READER_JS)

    def test_site_media_enhancement_and_math(self):
        enhance_path = SITE_ROOT / 'src/data/media-enhance.ts'
        if not enhance_path.exists():
            self.skipTest('Optional upstream site contract: set LONGBLOG_SITE_ROOT')
        content = enhance_path.read_text()
        self.assertIn('article-pdf-container', content)
        self.assertIn('article-video-player', content)
        self.assertNotIn('article-media-caption', content)
        self.assertIn('normalizeEmbeddedMarkdown', content)

        md_posts_path = SITE_ROOT / 'src/data/md-posts.ts'
        md_posts = md_posts_path.read_text()
        self.assertIn('readerBlockMath', md_posts)
        self.assertIn('readerInlineMath', md_posts)
        self.assertIn('admonition', md_posts)


    def test_v2132_fixes(self):
        md_store = (ROOT / 'src/LBMdStore.m').read_text()
        self.assertIn('[self.operation isEqual:@"sync"] || [self.operation isEqual:@"forceSync"]', md_store)

        card = (ROOT / 'src/LBCard.m').read_text()
        self.assertIn('systemLayoutSizeFittingSize:', card)
        self.assertIn('_titleLabel.preferredMaxLayoutWidth = available', card)

        content = (ROOT / 'src/LBContent.m').read_text()
        self.assertIn('_navSyncIcon', content)
        self.assertIn('arrow.triangle.2.circlepath', content)
        self.assertIn('NSSymbolRotateEffect', content)
        self.assertIn('发布中…', content)
        self.assertIn('已发布', content)


if __name__ == '__main__':
    unittest.main()

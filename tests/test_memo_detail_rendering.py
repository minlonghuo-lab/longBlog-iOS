"""Static contracts only. UIKit/WebKit runtime and real account I/O are NOT simulated."""
import pathlib
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
DETAIL = (ROOT / 'src/LBMemosDetail.m').read_text()
CONTENT = (ROOT / 'src/LBMemoContentView.m').read_text()
JS = (ROOT / 'resources/Reader/memo-detail.js').read_text()
HTML = (ROOT / 'resources/Reader/memo-detail.html').read_text()
CSS = (ROOT / 'resources/Reader/memo-detail.css').read_text()

class MemoDetailContracts(unittest.TestCase):
    def test_one_native_scroll_and_one_card_no_full_markdown_route(self):
        self.assertIn('LBInstallContentScrollView(self, _scroll, nil)', DETAIL)
        self.assertIn('_scroll.contentLayoutGuide', DETAIL)
        self.assertIn('_scroll.frameLayoutGuide.widthAnchor constant:-32', DETAIL)
        self.assertEqual(CONTENT.count('[LBTheme glassWithTint:'), 1)
        self.assertNotIn('LBMemoMarkdownPreview', DETAIL)
        self.assertNotIn('UITableView', DETAIL)
        self.assertIn('scrollView.scrollEnabled = NO', CONTENT)
        self.assertIn('contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever', CONTENT)

    def test_offline_isolation_and_no_web_credentials(self):
        self.assertIn('worldWithName:@"LongBlogMemoDetail"', CONTENT)
        self.assertIn('inContentWorld:_world', CONTENT)
        self.assertIn('WKWebsiteDataStore.nonPersistentDataStore', CONTENT)
        self.assertIn('script-src \'none\'', HTML)
        self.assertIn('img-src data:', HTML)
        self.assertIn('connect-src \'none\'', HTML)
        self.assertNotIn('Authorization', CONTENT)
        self.assertNotIn('.token', CONTENT)
        self.assertNotIn('baseURL', CONTENT)
        self.assertIn('root.LBReader.render({...payload,isMemo:true}', JS)

    def test_native_images_and_explicit_independent_retry(self):
        self.assertIn('downloadResource:row.resource', CONTENT)
        self.assertIn('while (_active < 2 && _queue.count)', CONTENT)
        self.assertIn('kCGImageSourceThumbnailMaxPixelSize:@2048', CONTENT)
        self.assertIn('CGImageSourceCreateWithURL', CONTENT)
        self.assertIn('LBMemoIsImage(resource)', CONTENT)
        self.assertIn('conformsToType:UTTypeImage', CONTENT)
        self.assertIn('application/octet-stream', CONTENT)
        self.assertIn('image/heic', CONTENT)
        self.assertNotIn('imageWithContentsOfFile', CONTENT)
        self.assertNotIn('dataWithContentsOfURL', CONTENT)
        self.assertIn('UIViewContentModeScaleAspectFit', CONTENT)
        self.assertIn('MIN(320,', CONTENT)
        self.assertIn('重新鉴权加载', CONTENT)
        self.assertIn('附件未能加载，请检查网络后重试', CONTENT)
        self.assertIn('QLPreviewController', DETAIL)

    def test_generation_reset_and_hidden_measurement(self):
        self.assertIn('_generation == LBMemosClient.shared.generation', CONTENT)
        self.assertIn('_revision == revision', CONTENT)
        self.assertIn('_web.hidden = YES', CONTENT)
        self.assertIn('row.imageView.image = nil; row.file = nil;', CONTENT)
        self.assertNotIn('removeItemAtURL:file', CONTENT)
        self.assertIn('LBMemosCache.h', CONTENT)
        self.assertIn('window.LBMemoDetail.clear(revision)', CONTENT)
        self.assertIn('if (_visible && fabs(_webHeight.constant', CONTENT)
        self.assertIn('if (_pendingHeight > 0)', CONTENT)
        self.assertIn('if(!Number.isSafeInteger(next)||next<revision)', JS)
        self.assertIn('root.LBReaderDiagramsComplete', JS)
        self.assertIn('doc.fonts.ready', JS)
        self.assertIn('ResizeObserver', JS)
        self.assertIn('Math.min(120000', JS)
        self.assertIn('overflow-x:hidden', CSS)
        self.assertIn('revision != self->_revision', DETAIL)

    def test_delete_menu_uses_archive_and_explicit_permanent_path(self):
        self.assertIn('删除…', DETAIL)
        self.assertIn('移至归档（可恢复）', DETAIL)
        self.assertIn('永久删除（不可恢复）', DETAIL)
        self.assertIn('updateMemo:snapshot fields:@{@"rowStatus":@"ARCHIVED"}', DETAIL)
        self.assertIn('deleteArchived:archived', DETAIL)
        self.assertIn('第一步已归档；永久删除未确认', DETAIL)
        self.assertIn('[self change:@{@"rowStatus":@"ARCHIVED"}]', DETAIL)
        self.assertIn('deleteArchived:', DETAIL)
        self.assertIn('UIMenuElementAttributesDisabled', DETAIL)
        self.assertNotIn('NSLog', DETAIL + CONTENT)

if __name__ == '__main__':
    unittest.main()

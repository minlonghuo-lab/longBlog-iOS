import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STORE = (ROOT / 'src/LBMdStore.m').read_text()
CONTENT = (ROOT / 'src/LBContent.m').read_text()
READER = (ROOT / 'src/LBPostReader.m').read_text()


class SyncPerf2138Tests(unittest.TestCase):
    def test_sync_runs_on_background_queue(self):
        # Heavy disk hashing and downloads must not block the main queue.
        self.assertIn('dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)', STORE)
        start = STORE[STORE.rindex('- (void)start'):STORE.rindex('- (void)resumePending')]
        self.assertIn('dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)', start)

    def test_download_loop_skips_existing_files_without_mdread(self):
        download = STORE[STORE.rindex('- (void)downloadNext'):STORE.rindex('- (void)applySync')]
        self.assertIn('while (self.index < self.paths.count)', download)
        self.assertIn('fileExistsAtPath:', download)
        # Does not synchronously read all binary asset payloads into memory just to check existence.
        self.assertNotIn('MDRead(self.root, local)', download)

    def test_finish_always_dispatches_to_main_thread(self):
        finish = STORE[STORE.rindex('- (void)finish:(NSError *)error'):STORE.rindex('- (void)start')]
        self.assertIn('dispatch_async(dispatch_get_main_queue()', finish)

    def test_load_articles_is_async_background(self):
        load = CONTENT[CONTENT.index('- (void)loadArticles'):CONTENT.index('- (void)updateArticleFeedback')]
        self.assertIn('dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)', load)
        self.assertIn('[LBMdStore.shared listArticles]', load)

    def test_cached_reader_scripts(self):
        self.assertIn('cachedReaderScript', READER)
        self.assertIn('dispatch_once(&scriptOnce', READER)


if __name__ == '__main__':
    unittest.main()

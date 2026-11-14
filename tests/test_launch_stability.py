"""Launch source contracts, not device timing, UIKit execution or crash proof."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).parent))
from test_dashboard_performance import method

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'src/LBApp.m').read_text()
SITE = (ROOT / 'src/LBSite.m').read_text()
STORE = (ROOT / 'src/LBMdStore.m').read_text()
STORE_IMPL = STORE[STORE.index('@implementation LBMdStore'):].replace('\n+ (', '\n- (')
DASH = (ROOT / 'src/LBDashboard.m').read_text()


class LaunchContracts(unittest.TestCase):
    def test_scene_connect_has_no_keychain_or_document_scan(self):
        connect = method('scene', APP)
        for forbidden in ['configured', 'LBMdStore', 'listArticles', 'navigationBar']:
            self.assertNotIn(forbidden, connect.split('launch.ready =')[0])
        self.assertIn('self.window.backgroundColor = LBTheme.paper', connect)
        self.assertIn('self.window.rootViewController = launch', connect)
        self.assertIn('[self.window makeKeyAndVisible]', connect)
        self.assertLess(connect.index('dispatch_get_global_queue'), connect.index('[LBAPI.shared configured]'))
        self.assertIn('owner.window.rootViewController != weakLaunch', connect)
        self.assertIn('if (_tabs) [LBSync.shared startForegroundPolling]', method('sceneDidBecomeActive', APP))

    def test_launch_discovery_begins_after_appearance_once(self):
        launch = APP[APP.index('@implementation LBLaunchViewController'):APP.index('@implementation LBSceneDelegate')]
        ready = method('viewDidAppear', launch)
        self.assertLess(ready.index('self.ready = nil'), ready.index('if (ready) ready()'))
        for bad in ['LBAPI', 'LBGitHub', 'LBMdStore', 'dispatch_sync', 'sleep(']:
            self.assertNotIn(bad, launch)

    def test_unvisited_tabs_have_lazy_retained_stacks(self):
        install = method('installTabsWithInboxOnly', APP)
        provider = install[install.index('viewControllerProvider:'):install.index('if ([s[0]')]
        self.assertIn('if (!navigation)', provider)
        self.assertIn('navigation = navFor(makeRoot())', provider)
        self.assertIn('navigation.delegate = weakChrome', provider)
        self.assertIn('return navigation', provider)
        self.assertNotIn('navFor(', install[:install.index('viewControllerProvider:')])
        nav_factory = APP[APP.index('static UINavigationController *navFor'):APP.index('- (void)openSession:')]
        self.assertNotIn('navigationBar', nav_factory)

    def test_notification_is_buffered_during_launch(self):
        self.assertIn('opts.notificationResponse', method('scene', APP))
        self.assertIn('if (!_tabs) { _pendingSessionID = [sid copy]; return; }', method('openSession', APP))
        self.assertIn('if (sid) [self openSession:sid]', method('installTabsWithInboxOnly', APP))
        self.assertIn('self.window = nil', method('sceneDidDisconnect', APP))
        self.assertIn('removeObserver:_openObserver', method('sceneDidDisconnect', APP))

    def test_dashboard_does_not_scan_in_view_did_load(self):
        self.assertNotIn('refreshAll:', method('viewDidLoad', DASH))
        active = method('becameActive', DASH)
        self.assertIn('if (!_initialRefreshStarted)', active)
        self.assertIn('_initialRefreshStarted = YES', active)
        self.assertIn('refreshAll:nil', active)

    def test_posts_scan_runs_off_main_and_publishes_on_main(self):
        posts = method('refreshPosts', SITE)
        self.assertIn('NSData *bookmark', posts)
        self.assertIn('dispatch_async(_postsQueue', posts)
        self.assertIn('[LBMdStore listArticlesForFolderBookmark:bookmark]', posts)
        self.assertLess(posts.index('dispatch_get_main_queue()'), posts.index('self->_posts ='))
        for guard in ['generation == self->_generation', 'revision == self->_postsRevision', 'isEqual:currentBookmark']:
            self.assertIn(guard, posts)
        self.assertIn('if (done) done()', posts)
        self.assertNotIn('LBMdStore.shared', posts)

    def test_current_scan_retries_changed_folder_but_not_obsolete_requests(self):
        posts = method('refreshPosts', SITE)
        self.assertIn('BOOL current = generation == self->_generation && revision == self->_postsRevision', posts)
        self.assertIn('if (current && sameFolder)', posts)
        retry = posts.split('} else if (current) {', 1)[1].split('\n        }', 1)[0]
        self.assertEqual(retry.count('[self refreshPosts:nil]'), 1)
        # The original group completion is outside the retry branch and runs once.
        self.assertEqual(posts.count('if (done) done()'), 1)
        self.assertGreater(posts.index('if (done) done()'), posts.index(retry) + len(retry))

    def test_readonly_scanner_owns_scope_without_changing_preferences(self):
        scan = method('listArticlesForFolderBookmark', STORE_IMPL)
        self.assertIn('initWithFolderBookmark:bookmark', scan)
        self.assertIn('[store listArticles]', scan)
        self.assertIn('renew:NO', method('initWithFolderBookmark', STORE_IMPL))
        self.assertIn('if (isStale && renew)', method('resolveFolderWithBookmark', STORE_IMPL))
        self.assertIn('stopAccessingSecurityScopedResource', method('dealloc', STORE))


if __name__ == '__main__':
    unittest.main(verbosity=2)

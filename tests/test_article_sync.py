"""Offline article-sync contracts + real Git object/atomic-ref fixtures.
No tokens, network requests, user articles, IPA builds or commits to this project.
Run: python3 -m unittest discover -s tests -p 'test_article_sync*.py' -v
Use LB_ARTICLE_STRICT_COMPILE=1 to additionally compile only LBMdStore.m/LBSite.m.
These are source contracts and local Git protocol fixtures, not iOS runtime tests.
"""
import base64
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MD = (ROOT / 'src/LBMdStore.m').read_text()
SITE = (ROOT / 'src/LBSite.m').read_text()
HEADER = (ROOT / 'src/LBMdStore.h').read_text()


def section(source, begin, end):
    return source[source.index(begin):source.index(end, source.index(begin))]


class ArticleSyncContracts(unittest.TestCase):
    def test_public_interfaces(self):
        for selector in ('syncFromGitHub:', 'publishArticle:', 'unpublishArticle:', 'deleteArticle:'):
            self.assertIn(selector, HEADER)
        self.assertIn('#import "LBMarkdown.h"', MD)
        self.assertNotIn('LBTriliumClient', MD)
        self.assertNotIn('trilium', SITE.lower())
        self.assertIn('MDLegacyAssets()', MD)
        self.assertIn('MDDecodedLocalPath', MD)
        self.assertIn('trilium-assets', MD)  # read-only legacy reference mapping remains supported
        self.assertNotIn('putAttachmentData:', MD)  # no legacy write API

    def test_main_queue_and_sync_coalescing(self):
        entry = section(MD, '- (void)beginArticleOperation:', '+ (instancetype)shared')
        self.assertIn('dispatch_async(dispatch_get_main_queue()', entry)
        self.assertIn('self.articleTask', entry)
        self.assertIn('self.syncCallbacks addObject', entry)
        self.assertIn('active.root isEqual:self.articlesFolderURL', entry)
        self.assertIn('MDError(409', entry)
        self.assertNotIn('__block', entry)
        self.assertIn('@interface LBArticleTask : NSObject', MD)
        self.assertIn('@interface LBGitCommitTask : NSObject', SITE)

    def test_binary_is_never_decoded_as_text(self):
        blob = section(SITE, '- (void)getBlobData:', '- (void)getData:')
        self.assertIn('initWithBase64EncodedString:', blob)
        self.assertNotIn('initWithData:', blob)
        download = section(MD, '- (void)downloadNext', '- (void)applySync')
        self.assertIn('getBlobData:entry[@"sha"]', download)
        self.assertNotIn('getFile:', download)
        self.assertIn('![local hasPrefix:@"assets/"]', download)

    def test_snapshot_is_immutable_and_truncation_errors(self):
        snapshot = section(SITE, '- (void)articleSnapshot:', '- (void)commitChanges:')
        self.assertIn('head[@"treeSHA"]', snapshot)
        self.assertIn('?recursive=1', snapshot)
        self.assertIn('if ([j[@"truncated"] boolValue]) return done(nil, httpErr(413', snapshot)
        self.assertLess(snapshot.index('truncated'), snapshot.index('NSMutableDictionary *files'))
        self.assertIn('queryItemWithName:@"recursive" value:@"1"', SITE)
        self.assertIn('frozenRepository', SITE)
        self.assertIn('frozenToken', SITE)

    def test_sync_preserves_modified_and_untracked_and_drafts(self):
        sync = section(MD, '- (void)prepareSync', '- (BOOL)checkRemote:')
        self.assertIn('!record || ![MDDigest(existing) isEqual:record[@"baseline"]]', sync)
        self.assertIn('parseFrontmatterAndBody:text][@"publish"] boolValue', sync)
        self.assertIn('protectedGroups containsObject:MDGroup(local)', sync)
        self.assertIn('self.before[local]', sync)
        self.assertIn('self.records[local][@"baseline"]', sync)
        self.assertIn('Preserve bytes exactly on disk', sync)
        self.assertIn('self.snapshot[@"files"][remote][@"sha"]', sync)

    def test_repo_binding_and_path_safety(self):
        self.assertIn('@".longblog-sync.json"', MD)
        self.assertIn('state[@"repository"] isEqual:repo.lowercaseString', MD)
        self.assertIn('state[@"branch"] isEqual:@"main"', MD)
        self.assertIn('NSFileTypeSymbolicLink', MD)
        self.assertIn('MDSafePathStripPrivate', MD)
        self.assertIn('precomposedStringWithCanonicalMapping.lowercaseString', MD)
        self.assertIn('旧新附件路径映射重名且内容不同', MD)
        for check in ('containsString:@"%"', 'containsString:@"\\\\"', 'hasPrefix:@"/"'):
            self.assertIn(check, MD)
            self.assertIn(check, SITE)

    def test_no_credentials_or_redirect_leaks(self):
        gh = section(SITE, '#pragma mark - GitHub', '#pragma mark - Site data cache')
        self.assertIn('completion(nil)', gh)
        self.assertIn('config.URLCache = nil', gh)
        self.assertIn('config.HTTPCookieStorage = nil', gh)
        self.assertIn('https://api.github.com/repos/', gh)
        self.assertNotIn('NSLog', gh)
        self.assertNotIn('localizedDescription', gh)
        self.assertNotIn('j[@"message"]', gh)
        self.assertNotIn('token', section(MD, 'static NSDictionary *MDLoadState', '@interface LBMdStore'))

    def test_single_tree_commit_nonforce_ref(self):
        task = section(SITE, '@implementation LBGitCommitTask', '#pragma mark - Site data cache')
        for endpoint in ('/git/blobs', '/git/trees', '/git/commits', '/git/refs/heads/main'):
            self.assertIn(endpoint, task)
        self.assertIn('@"parents":@[self.snapshot[@"head"]]', task)
        self.assertIn('@"force":@NO', task)
        self.assertIn('@"sha":NSNull.null', task)
        self.assertIn('dict(ref[@"object"])[@"sha"]', task)
        self.assertNotIn('putFile:', task)
        self.assertNotIn('__block', task)

    def test_remote_success_before_local_publish_transition(self):
        publish = section(MD, '- (void)preparePublish', '- (void)applyPublish:')
        self.assertIn('[self.github commitChanges:', publish)
        self.assertIn('if (error) return [self finish:error]', publish)
        self.assertLess(publish.index('if (error) return'), publish.index('[self applyPublish:result]'))
        save = section(MD, '- (BOOL)saveArticleWithId:', '- (BOOL)deleteArticleWithId:')
        self.assertIn('NSDictionary *oldFm = [LBMdStore parseFrontmatterAndBody:oldText ?: @""]', save)
        # Missing old metadata boolValue is NO: new saves are drafts; existing state is retained.
        self.assertNotIn('meta[@"publish"] = @(publish)', save)
        self.assertIn('prepared:^BOOL', publish)
        self.assertIn('self.state[@"pending"] = record', publish)
        self.assertIn('return MDSaveState(self.root, self.state, saveError)', publish)
        self.assertIn('meta[@"publish"] = @([oldFm[@"publish"] boolValue])', save)
        self.assertIn('(void)publish', save)
        self.assertIn('removeItemAtURL:sidecar', save)
        self.assertIn('changedDuringUpload', MD)

    def test_delete_removes_both_article_files_but_no_assets(self):
        delete = section(MD, 'if ([self.operation isEqual:@"delete"])', '  } else {\n    BOOL publishing')
        self.assertIn('self.changes[remoteMD] = NSNull.null', delete)
        self.assertIn('self.changes[remoteHTML] = NSNull.null', delete)
        self.assertNotIn('assets', delete)
        self.assertNotIn('- (void)putArticleFile:', SITE)
        self.assertNotIn('- (void)putAttachmentData:', SITE)

    def test_stale_sidecar_and_sha_checks(self):
        publish = section(MD, '- (void)preparePublish', '- (void)applyPublish:')
        self.assertIn('self.changes[remoteHTML] = NSNull.null', publish)
        self.assertIn('MDDigest(source) isEqual:self.records[md][@"baseline"]', publish)
        self.assertIn('[self checkRemote:remoteMD local:md error:&e]', publish)
        self.assertIn('[self checkRemote:remoteHTML local:html error:&e]', publish)
        self.assertIn('MDCanonicalReferences', publish)
        self.assertIn('MDAssetReferences(body, htmlText, &e)', publish)
        self.assertIn('MDDecodedLocalPath(destination)', MD)
        self.assertNotIn('enumeratorAtURL:', publish)  # only referenced local files, not arbitrary directory contents
        self.assertNotIn('dataWithContentsOfURL:[NSURL URLWithString:', publish)  # no remote attachment fetch

    def test_sha_integrity_and_attachment_html_is_not_sidecar(self):
        self.assertIn('GHBlobSHA(data) isEqual:sha', SITE)
        self.assertIn('GHBlobSHA(data) isEqual:j[@"sha"]', SITE)
        self.assertIn('static NSString *MDQuote', MD)
        self.assertIn('MDQuote(meta[@"summary"])', MD)
        self.assertIn('if ([local hasPrefix:@"assets/"] || ![local.pathExtension isEqual:@"html"]', MD)
        self.assertIn('[MDLocalPath(record[@"remote"]) isEqual:local]', MD)
        self.assertNotIn('seedDefaultFolderIfNeeded:', MD)

    def test_seed_upgrade_downloads_missing_assets_without_overwriting(self):
        guard = section(MD, '- (BOOL)canDownloadLocal:', '- (void)downloadNext')
        self.assertIn('hasPrefix:@"assets/"', guard)
        self.assertIn('!self.records[local]', guard)
        self.assertIn('![self.before[local] length]', guard)
        self.assertIn('!MDRead(self.root, local)', guard)
        self.assertIn('if (![self canDownloadLocal:local] && self.records[local])', MD)
        self.assertIn('if (![self canDownloadLocal:local])', MD)
        self.assertIn('[MDCanonicalReferences(left) isEqual:MDCanonicalReferences(right)]', MD)
        self.assertIn('!self.records[local] && equivalent', MD)
        self.assertIn('[MDDigest(localData) isEqual:self.before[local]]', MD)

    def test_metadata_only_single_source_save_and_remote_tombstones(self):
        self.assertIn('record[@"bodyBaseline"] = MDBodyDigest(data)', MD)
        save = section(MD, '- (BOOL)saveArticleWithId:', '- (BOOL)deleteArticleWithId:')
        self.assertIn('NSMutableDictionary *meta = [oldFm mutableCopy]', save)
        self.assertIn('serializeFrontmatter:meta body:markdown', save)
        serializer = section(MD, '+ (NSString *)serializeFrontmatter:', '#pragma mark - Store Operations')
        self.assertIn('@"bodyFormat", @"bodySource", @"singleSourceVersion"', serializer)
        self.assertIn('[out appendString:body ?: @""]', serializer)
        publish = section(MD, '- (void)preparePublish', '- (void)applyPublish:')
        self.assertIn('BOOL lossless = !singleSource && sidecar', publish)
        self.assertIn('self.changes[remoteHTML] = NSNull.null', publish)
        self.assertIn('tombstones', MD)
        self.assertIn('远端文件已删除，请核对后使用新 ID 保存', MD)
        deletion = section(MD, '// A remote deletion removes only', '// A removed remote HTML')
        self.assertIn('parseFrontmatterAndBody:text][@"publish"] boolValue', deletion)
        self.assertIn('protectedGroups', deletion)
        self.assertNotIn('removeObjectForKey', deletion)

    def test_single_source_sync_production_guard_rejects_legacy_overwrite(self):
        import ctypes
        function = section(MD, 'static int MDSingleSourceAllowsDownload(', '\nstatic NSString *currentDateString')
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp)/'guard.c'
            library = Path(temp)/'guard.so'
            source.write_text(function.replace('static int ', 'int ', 1))
            subprocess.run(['clang','-shared','-fPIC','-Wall','-Wextra','-Werror',str(source),'-o',str(library)],check=True,capture_output=True)
            guard = ctypes.CDLL(str(library)).MDSingleSourceAllowsDownload
            guard.argtypes = [ctypes.c_int]*6
            guard.restype = ctypes.c_int
            self.assertEqual(guard(1,0,1,0,1,1),0)  # old/new HTML sidecars never install
            self.assertEqual(guard(1,0,0,0,1,0),0)  # old lossy repo MD cannot downgrade
            self.assertEqual(guard(1,0,0,1,1,1),0)  # unpushed migration cannot be replaced
            self.assertEqual(guard(1,0,0,0,1,1),1)  # verified versioned MD allowed if clean
            self.assertEqual(guard(1,1,0,1,1,0),1)  # assets remain independent binary files
            self.assertEqual(guard(0,0,0,0,1,0),1)  # legacy reads still supported
        can_download = section(MD,'- (BOOL)canDownloadLocal:', '- (void)downloadNext')
        self.assertIn('MDSingleSourceAllowsDownload(',can_download)
        self.assertIn('protectedGroups containsObject:',can_download)
        pending = section(MD,'- (void)resumePending:', '- (void)prepareSync')
        self.assertIn('singleSourcePendingReview',pending)
        self.assertIn('pending[@"singleSourceVersion"]',pending)

    def test_site_posts_use_mdstore(self):
        refresh = section(SITE, '- (void)refreshPosts:', '- (void)refreshMemos:')
        self.assertIn('[LBMdStore listArticlesForFolderBookmark:bookmark]', refresh)
        self.assertIn('dispatch_async(_postsQueue', refresh)
        self.assertNotIn('LBMdStore.shared', refresh)
        self.assertNotIn('generated', refresh)
        self.assertNotIn('getFile:', refresh)

    @unittest.skipUnless(os.getenv('LB_ARTICLE_STRICT_COMPILE') == '1', 'opt-in iOS SDK strict compile')
    def test_strict_compile_modified_translation_units_only(self):
        sdk = Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'
        self.assertTrue(sdk.exists())
        for filename in ('LBMdStore.m', 'LBSite.m'):
            result = subprocess.run(['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
                '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc', '-fsyntax-only',
                '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-nullability-completeness',
                '-I', str(ROOT / 'src'), str(ROOT / 'src' / filename)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


class GitAtomicPublicationFixture(unittest.TestCase):
    def test_binary_roundtrip_single_tree_and_ref_compare_swap(self):
        with tempfile.TemporaryDirectory(prefix='longblog-article-sync-') as temp:
            def git(*args, data=None, ok=True):
                p = subprocess.run(['git', '-C', temp, *args], input=data, capture_output=True)
                if ok:
                    self.assertEqual(p.returncode, 0, p.stderr.decode())
                return p
            git('init', '-q')
            git('config', 'user.name', 'Offline fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            old_md = b'---\nid: "fixture"\npublish: false\n---\nold\n'
            binary = bytes(range(256)) + b'\x00\xff\xfePNG\x89\x00'
            self.assertEqual(base64.b64decode(base64.b64encode(binary)), binary)
            (Path(temp) / 'content/posts').mkdir(parents=True)
            (Path(temp) / 'content/posts/fixture.md').write_bytes(old_md)
            (Path(temp) / 'content/posts/fixture.html').write_text('<p>stale</p>')
            git('add', '.')
            git('commit', '-qm', 'initial fixture')
            head = git('rev-parse', 'HEAD').stdout.strip().decode()
            new_md = b'---\nid: "fixture"\npublish: true\n---\n![x](/assets/fixture/x.bin)\n'
            md_sha = git('hash-object', '-w', '--stdin', data=new_md).stdout.strip().decode()
            asset_sha = git('hash-object', '-w', '--stdin', data=binary).stdout.strip().decode()
            expected_blob_sha = hashlib.sha1(b'blob ' + str(len(binary)).encode() + b'\0' + binary).hexdigest()
            self.assertEqual(asset_sha, expected_blob_sha)
            git('update-index', '--add', '--cacheinfo', '100644', md_sha, 'content/posts/fixture.md')
            git('update-index', '--force-remove', 'content/posts/fixture.html')
            git('update-index', '--add', '--cacheinfo', '100644', asset_sha, 'public/assets/fixture/x.bin')
            tree = git('write-tree').stdout.strip().decode()
            commit = git('commit-tree', tree, '-p', head, '-m', 'atomic publish fixture').stdout.strip().decode()
            self.assertEqual(git('rev-parse', 'HEAD').stdout.strip().decode(), head)
            self.assertEqual(git('show', f'{head}:content/posts/fixture.md').stdout, old_md)
            git('update-ref', 'refs/heads/master', commit, head)
            self.assertEqual(git('show', f'{commit}:content/posts/fixture.md').stdout, new_md)
            self.assertEqual(git('show', f'{commit}:public/assets/fixture/x.bin').stdout, binary)
            self.assertNotEqual(git('cat-file', '-e', f'{commit}:content/posts/fixture.html', ok=False).returncode, 0)
            # Concurrent writer from the same expected parent must fail CAS.
            competitor = git('commit-tree', tree, '-p', head, '-m', 'competing fixture').stdout.strip().decode()
            self.assertNotEqual(git('update-ref', 'refs/heads/master', competitor, head, ok=False).returncode, 0)
            self.assertEqual(git('rev-parse', 'HEAD').stdout.strip().decode(), commit)
            # Explicit non-fast-forward ancestry proof used by GitHub force:false.
            self.assertNotEqual(git('merge-base', '--is-ancestor', commit, competitor, ok=False).returncode, 0)


if __name__ == '__main__':
    unittest.main()

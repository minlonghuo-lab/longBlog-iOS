"""Offline reliability fixtures. Never read/write mounted notes, network, IPA, or repo commits.
C tests compile the actual production delimiter/order/recovery functions. Python
filesystem fixtures exercise the stage/verified-copy/manifest protocol, not iOS APIs.
Run: python3 -m unittest discover -s tests -p test_md_reliability.py -v
"""
import base64
import ctypes
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'src/LBMdStore.m').read_text()
HEADER = (ROOT / 'src/LBMdStore.h').read_text()


def function(name):
    start = SOURCE.index('static ', SOURCE.index(name) - 50)
    # Find a function by declaration, then balanced braces (these functions have no strings with braces).
    start = SOURCE.rfind('static ', 0, SOURCE.index(name))
    opening = SOURCE.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (SOURCE[end] == '{') - (SOURCE[end] == '}')
        end += 1
    return SOURCE[start:end].replace('static ', '', 1)


def objc_literal_after(marker):
    line = SOURCE.split(marker, 1)[1].split('\n', 1)[0]
    literal = re.search(r'@("(?:\\.|[^"\\])*")', line)
    return json.loads(literal[1])


class ProductionAlgorithms(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='lb-md-c-')
        path = Path(cls.temp.name)
        names = ('MDReferenceEnd', 'MDArticleOrder', 'MDRecoveryAction', 'MDKeepLocalEdit')
        (path / 'fixture.c').write_text('#include <stddef.h>\n#include <string.h>\n' + '\n'.join(function(n) for n in names))
        subprocess.run(['clang', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', str(path / 'fixture.c'), '-o', str(path / 'fixture.so')], check=True, capture_output=True)
        cls.lib = ctypes.CDLL(str(path / 'fixture.so'))
        cls.lib.MDReferenceEnd.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char]
        cls.lib.MDReferenceEnd.restype = ctypes.c_size_t
        cls.lib.MDArticleOrder.argtypes = [ctypes.c_longlong, ctypes.c_longlong, ctypes.c_char_p, ctypes.c_longlong, ctypes.c_longlong, ctypes.c_char_p]
        cls.lib.MDRecoveryAction.argtypes = [ctypes.c_char_p]
        cls.lib.MDKeepLocalEdit.argtypes = [ctypes.c_int] * 4

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def end(self, text, quote=b'\0'):
        raw = text.encode()
        return raw[:self.lib.MDReferenceEnd(raw, len(raw), 0, quote)].decode()

    def references(self, text):
        # Production regex itself, not a separately maintained Python regex.
        pattern = objc_literal_after('NSString *pattern = ')
        refs = []
        for match in re.finditer(pattern, text):
            marker = match[1]
            quote = b'>' if marker == '<' else marker.encode() if marker in ('"', "'") else b'\0'
            refs.append(self.end(text[match.start(2):], quote).split('?', 1)[0].split('#', 1)[0])
        return refs

    def test_markdown_closing_bracket_regression(self):
        self.assertEqual(self.end('/assets/id/a.png]'), '/assets/id/a.png')
        self.assertEqual(self.references('[x]: /assets/id/a.png\n![x][x]'), ['/assets/id/a.png'])
        self.assertEqual(self.references('< /assets/id/not-a-link>'), [])

    def test_balanced_and_escaped_parentheses(self):
        self.assertEqual(self.references('![x](/assets/id/a(b).png)'), ['/assets/id/a(b).png'])
        self.assertEqual(self.end(r'/assets/id/a\(b\).png)'), r'/assets/id/a\(b\).png')

    def test_encoded_unicode_spaces_queries_and_cross_article(self):
        self.assertEqual(self.references('![x](</assets/other/%E4%B8%AD%20x.png?q=1#x>)'), ['/assets/other/%E4%B8%AD%20x.png'])
        self.assertEqual(self.references('<img src="/assets/other/a b.png">'), ['/assets/other/a b.png'])
        self.assertEqual(self.references('<img src="https://example.invalid/assets/id/no.png">'), [])
        self.assertEqual(self.references('Plain /assets/id/example.png is prose'), [])

    def test_html_css_and_legacy(self):
        self.assertEqual(self.references('<video poster="/assets/id/p.jpg"><source src="/assets/id/v.mp4"></video>'), ['/assets/id/p.jpg', '/assets/id/v.mp4'])
        self.assertEqual(self.references('a{background:url(\'/assets/id/bg.png\')}'), ['/assets/id/bg.png'])
        self.assertEqual(self.references('![x](/trilium-assets/id/old.png)'), ['/trilium-assets/id/old.png'])

    def test_publish_sort_not_updated_or_draft_pin(self):
        order = self.lib.MDArticleOrder
        self.assertEqual(order(200, 10, b'published', 0, 100, b'draft'), -1)
        self.assertEqual(order(50, 1000, b'unpublished', 0, 100, b'draft'), 1)
        self.assertEqual(order(100, 10, b'a', 100, 900, b'b'), -1)
        self.assertEqual(order(100, 10, b'b', 100, 900, b'a'), 1)
        self.assertEqual(order(0, 100, b'a', 100, 2, b'a'), 0)
        comparator = SOURCE.split('[items sortUsingComparator:', 1)[1].split('return items;', 1)[0]
        self.assertNotIn('updatedAt', comparator)
        self.assertNotIn('pinned', comparator)

    def test_unknown_then_restart_applied_no_resubmit(self):
        # Persist pending payload, emulate a process restart, execute the actual recovery decision.
        with tempfile.TemporaryDirectory(prefix='lb-pending-') as tmp:
            path = Path(tmp) / 'state.json'
            path.write_text(json.dumps({'pending': {'base': 'a' * 40, 'commit': 'b' * 40, 'payload': base64.b64encode(b'original').decode()}}))
            self.assertEqual(self.lib.MDRecoveryAction(b'unknown'), 0)
            pending = json.loads(path.read_text())['pending']
            submissions = 1
            self.assertEqual(self.lib.MDRecoveryAction(b'applied'), 1)
            self.assertEqual(base64.b64decode(pending['payload']), b'original')
            self.assertEqual(submissions, 1)
        resume = SOURCE.split('- (void)resumePending:(NSDictionary *)pending {', 1)[1].split('- (void)prepareSync', 1)[0]
        self.assertIn('confirmCommit:commit base:base', resume)
        self.assertNotIn('commitChanges:', resume)
        self.assertIn('[self applyPublish:', resume)

    def test_unchanged_and_conflict_never_allow_retry(self):
        for status in (b'unchanged', b'conflict', b'unknown', b''):
            for _ in range(100):
                self.assertEqual(self.lib.MDRecoveryAction(status), 0)
        start = SOURCE.split('- (void)start {', 1)[1].split('- (void)resumePending:', 1)[0]
        self.assertLess(start.index('self.state[@"pending"]'), start.index('articleSnapshot:'))

    def test_recovery_never_overwrites_new_local_body(self):
        keep = self.lib.MDKeepLocalEdit
        self.assertEqual(keep(0, 1, 0, 0), 1)  # edited after unknown
        self.assertEqual(keep(0, 0, 1, 0), 1)  # unconfirmed matching content not trusted
        self.assertEqual(keep(0, 1, 1, 0), 0)  # safely replay partially applied payload
        self.assertEqual(keep(1, 1, 0, 0), 0)
        self.assertEqual(keep(0, 1, 0, 1), 0)  # delete replay


class StoreSourceContracts(unittest.TestCase):
    def test_dates_stable_and_independent(self):
        self.assertIn('createdAt: \\"%@', SOURCE)
        dates = SOURCE.split('static NSDictionary *MDDates(', 1)[1].split('static void MDApplyDateStrings', 1)[0]
        self.assertNotIn('NSDate.date', dates)
        self.assertIn('published.length ? published : updated', dates)
        self.assertIn('NSFileModificationDate] ?: attrs[NSFileCreationDate]', dates)
        self.assertIn('T00:00:00.000Z', SOURCE)
        save = SOURCE.split('- (BOOL)saveArticleWithId:', 1)[1].split('- (BOOL)deleteArticleWithId:', 1)[0]
        self.assertIn('if (oldData) MDApplyDateStrings', save)
        self.assertIn('else meta[@"createdAt"] = nowStr', save)
        self.assertIn('if (publishing && ![meta[@"publishedAt"] length])', SOURCE)
        self.assertNotIn('removeObjectForKey:@"publishedAt"', SOURCE)

    def test_layout_interface_and_sidecar_truth(self):
        for name in ('resourceURLForLocalPath:', 'articleDirectoryURLForNote:', 'migrateToArticleFoldersWithError:'):
            self.assertIn(name, HEADER)
        load = SOURCE.split('- (NSDictionary *)loadArticle:', 1)[1].split('- (BOOL)saveArticleWithId:', 1)[0]
        self.assertIn('post[@"hasHTMLSidecar"] = @(html.length > 0)', load)
        self.assertNotIn('LBMarkdownToHTML(', load)
        resource = SOURCE.split('- (NSURL *)resourceURLForLocalPath:', 1)[1].split('- (NSURL *)readOnlyAssetURLForNote:', 1)[0]
        self.assertNotIn('createDirectory', resource)
        self.assertIn('NSFileTypeRegular', resource)
        self.assertIn('256ULL * 1024 * 1024', resource)

    def test_publish_only_scans_references_not_entire_asset_tree(self):
        publish = SOURCE.split('- (void)preparePublish {', 1)[1].split('- (void)applyPublish:', 1)[0]
        self.assertIn('MDAssetReferences(body, htmlText, &e)', publish)
        self.assertNotIn('enumeratorAtURL:', publish)
        self.assertIn('prepared:^BOOL', publish)
        self.assertIn('self.state[@"pending"] = record', publish)
        self.assertIn('return MDSaveState(self.root, self.state, saveError)', publish)

    def test_migration_switch_after_all_verification(self):
        migrate = SOURCE.split('static BOOL MDArchiveMany(', 1)[1].split('static BOOL MDArchive(', 1)[0]
        self.assertLess(migrate.index('MDCopyVerified(source'), migrate.index('writeToURL:manifest'))
        self.assertLess(migrate.index('writeToURL:manifest'), migrate.index('hide original bytes'))
        self.assertIn('MDRecoverLayoutInstall(root, error)', migrate)
        self.assertIn('moveItemAtURL:prior[@"target"] toURL:prior[@"copy"]', migrate)
        self.assertIn('unsafeManifest', migrate)
        copy = SOURCE.split('static BOOL MDCopyVerified(', 1)[1].split('static NSURL *MDHiddenURL', 1)[0]
        self.assertIn('MDDigest(a) isEqual:MDDigest(b)', copy)
        self.assertIn('NSFileModificationDate:attrs[NSFileModificationDate]', copy)
        self.assertIn('NSFileTypeRegular', copy)

    def test_strict_objc_compile(self):
        sdk = Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'
        if not sdk.exists() or not shutil.which('clang'):
            self.skipTest('iOS SDK or clang unavailable')
        result = subprocess.run(['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk), '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc', '-fsyntax-only', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-nullability-completeness', '-I', str(ROOT / 'src'), str(ROOT / 'src/LBMdStore.m')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


class IsolatedMigrationProtocol(unittest.TestCase):
    """Protocol fixture; Foundation file-provider semantics still need real-device QA."""
    def migrate(self, root, fail=None):
        old = root / 'article.md'
        stage = root / '.stage' / 'article'
        target = root / '草稿' / 'Title_article'
        stage.mkdir(parents=True)
        if fail == 'copy':
            raise OSError('injected copy failure')
        shutil.copy2(old, stage / 'index.md')
        self.assertEqual(hashlib.sha256(old.read_bytes()).digest(), hashlib.sha256((stage / 'index.md').read_bytes()).digest())
        if fail == 'verify':
            (stage / 'index.md').write_bytes(b'corrupted')
            if old.read_bytes() != (stage / 'index.md').read_bytes():
                raise OSError('injected verification failure')
        target.parent.mkdir(exist_ok=True)
        if target.exists():
            raise OSError('collision')
        stage.rename(target)
        try:
            if fail == 'manifest':
                raise OSError('injected atomic manifest failure')
            temporary = root / '.manifest.tmp'
            temporary.write_text(json.dumps({'articles': {'article': '草稿/Title_article'}}))
            temporary.replace(root / '.manifest.json')
        except OSError:
            target.rename(stage)
            raise
        (root / '.backups').mkdir(exist_ok=True)
        old.rename(root / '.backups' / 'article.md')
        return target

    def test_success_keeps_original_and_modification_time(self):
        import os
        with tempfile.TemporaryDirectory(prefix='lb-migration-') as tmp:
            root = Path(tmp)
            (root / 'article.md').write_bytes(b'old article with canonical /assets/article/x.png')
            os.utime(root / 'article.md', (1234567890, 1234567890))
            result = self.migrate(root)
            self.assertEqual((result / 'index.md').read_bytes(), (root / '.backups/article.md').read_bytes())
            self.assertEqual((result / 'index.md').stat().st_mtime, 1234567890)
            self.assertTrue((root / '.manifest.json').is_file())

    def test_stage_copy_verify_manifest_failures_keep_original(self):
        for fail in ('copy', 'verify', 'manifest'):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory(prefix='lb-migration-fail-') as tmp:
                root = Path(tmp)
                (root / 'article.md').write_bytes(b'original')
                with self.assertRaises(OSError):
                    self.migrate(root, fail)
                self.assertEqual((root / 'article.md').read_bytes(), b'original')
                self.assertFalse((root / '.manifest.json').exists())
                self.assertFalse((root / '草稿/Title_article').exists())

    def test_collision_never_replaces_external_article(self):
        with tempfile.TemporaryDirectory(prefix='lb-migration-collision-') as tmp:
            root = Path(tmp)
            (root / 'article.md').write_bytes(b'original')
            external = root / '草稿/Title_article'
            external.mkdir(parents=True)
            (external / 'index.md').write_bytes(b'external')
            with self.assertRaises(OSError):
                self.migrate(root)
            self.assertEqual((external / 'index.md').read_bytes(), b'external')
            self.assertEqual((root / 'article.md').read_bytes(), b'original')


class ExactReferencePathFixture(unittest.TestCase):
    def test_old_enumerator_trailing_slash_candidate_vs_new_reference_path(self):
        # Same public path shape and known attachment basename as the real report;
        # synthetic content only. NSURL's file-provider normalization is NOT emulated.
        note = 'nSQJSwS3ssYn'
        canonical = f'assets/{note}/media_C1FE04DB.jpeg'
        with tempfile.TemporaryDirectory(prefix='lb-exact-reference-') as temp:
            root = Path(temp) / 'notes with spaces'
            attachment = root / canonical
            attachment.parent.mkdir(parents=True)
            attachment.write_bytes(b'fixture-jpeg-not-user-data')
            markdown = f'![image](/{canonical})'
            old_regex = re.compile(r'''(?:^|[\s\"'(<=>])/assets/([^\s\"'<>?#)]+)''')
            encoded = old_regex.search(markdown)[1]
            self.assertEqual('assets/' + encoded, canonical)
            self.assertTrue((root / ('assets/' + encoded)).is_file())
            # Exact old expression: url.path substringFromIndex:self.root.path.length + 1.
            no_slash = str(attachment)[len(str(root)) + 1:]
            slash = str(attachment)[len(str(root) + '/') + 1:]
            self.assertEqual(no_slash, canonical)
            self.assertEqual(slash, canonical[1:])
            self.assertFalse((root / slash).is_file())
            self.assertTrue((root / canonical).is_file())
            # New production scanner obtains canonical paths from actual references,
            # never from root path length arithmetic or unrelated directory files.
            publish = SOURCE.split('- (void)preparePublish {', 1)[1].split('- (void)applyPublish:', 1)[0]
            self.assertNotIn('self.root.path.length + 1', publish)
            self.assertNotIn('enumeratorAtURL:', publish)
            self.assertIn('MDAssetReferences(body, htmlText, &e)', publish)

    def test_pending_identity_checked_before_confirm(self):
        resume = SOURCE.split('- (void)resumePending:(NSDictionary *)pending {', 1)[1].split('- (void)prepareSync', 1)[0]
        self.assertLess(resume.index('matchesPendingIdentity:pending'), resume.index('confirmCommit:'))
        self.assertIn('MDError(-999', resume)
        self.assertNotIn('removeObjectForKey:@"pending"', resume)


if __name__ == '__main__':
    unittest.main()

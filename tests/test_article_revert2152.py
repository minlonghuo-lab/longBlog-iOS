#!/usr/bin/env python3
"""Offline revert contracts + executable production draft-byte scanner.

Does not instantiate the native store, touch real articles, or contact GitHub.
Native task/control-flow checks complement actual C helper execution on temporary
fixtures; iOS SDK syntax checking is opt-in via LB_ARTICLE_STRICT_COMPILE=1.
"""
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MD = (ROOT / 'src/LBMdStore.m').read_text()
HEADER = (ROOT / 'src/LBMdStore.h').read_text()


def section(begin, end):
    return MD.split(begin, 1)[1].split(end, 1)[0]


class RevertStoreContracts(unittest.TestCase):
    def test_public_api_frozen_selection_main_completion_and_mutex(self):
        self.assertIn('- (void)revertStagedArticles:', HEADER)
        api = section('- (void)revertStagedArticles:', '- (void)commitStagedArticles:')
        self.assertIn('JSONObjectWithData:data', api)
        self.assertIn('MDBatchItemsValid(frozen)', api)
        self.assertIn('beginArticleOperation:@"revert"', api)
        begin = section('- (void)beginArticleOperation:(NSString *)operation note:(NSString *)note batch:', '+ (instancetype)shared')
        self.assertIn('if (self.articleTask)', begin)
        self.assertIn('self.articleTask = task', begin)
        self.assertIn('dispatch_async(dispatch_get_main_queue()', begin)

    def test_pending_refused_before_recovery_and_snapshot(self):
        start = section('- (void)start {', '- (BOOL)revertSelectionCurrent:')
        refusal = start.index('[self.operation isEqual:@"revert"] && (self.state[@"pending"]')
        self.assertLess(refusal, start.index('[self resumePending:'))
        self.assertLess(refusal, start.index('[self.github articleSnapshot:'))
        self.assertIn('singleSourcePendingReview', start)

    def test_no_remote_writes_or_pending_replay_in_revert(self):
        revert = section('- (BOOL)revertSelectionCurrent:', '- (void)resumePending:(NSDictionary *)pending {')
        for forbidden in ('commitChanges:', 'putFile:', 'deleteFile:', 'confirmCommit:', 'resumePending:', 'removeItemAtURL:', 'removeObjectForKey:@"pending"'):
            self.assertNotIn(forbidden, revert)
        self.assertIn('getBlobData:record[@"sha"]', revert)
        self.assertIn('MDGitBlobDigest(data)', revert)
        self.assertIn('[snapshot[@"head"] isEqual:self.snapshot[@"head"]]', revert)

    def test_guard_binds_all_local_bytes_and_identity(self):
        guard = section('static NSDictionary *MDRevertGuard(', '// A journal is an audit/backup')
        for key in ('@"repository"', '@"root"', '@"state"', '@"layout"', '@"files"'):
            self.assertIn(key, guard)
        self.assertIn('MDGroup(local)', guard)
        self.assertIn('MDJSONDigest(state)', guard)
        self.assertIn('NSFileTypeRegular', guard)
        current = section('- (BOOL)revertSelectionCurrent:', '- (void)prepareRevert {')
        self.assertIn('[self current]', current)
        self.assertIn('MDLoadState(', current)
        self.assertIn('MDRevertJournalClear(', current)
        self.assertIn('[guard isEqual:item[@"revertGuard"]]', current)
        self.assertIn('item[@"revertGuard"] = guard', MD)

    def test_only_confirmed_owned_regular_remote_blobs_are_restored(self):
        prepare = section('- (void)prepareRevert {', '- (void)downloadRevertNext {')
        self.assertIn('[entry[@"sha"] isEqual:rec[@"sha"]]', prepare)
        self.assertIn('@[@"100644", @"100755"]', prepare)
        self.assertIn('!self.records[local] && self.snapshot[@"files"][remote]', prepare)
        self.assertIn('[MDLocalPath(remote) isEqual:local]', prepare)
        self.assertIn('!MDID', section('static NSDictionary *MDRevertGuard(', '// A journal is an audit/backup'))

    def test_new_drafts_only_change_publish_scalar(self):
        prepare = section('- (void)prepareRevert {', '- (void)downloadRevertNext {')
        self.assertIn('MDRevertDraftData(source)', prepare)
        self.assertNotIn('serializeFrontmatter:', prepare)
        helper = section('static NSData *MDRevertDraftData(', 'static NSString *MDJSONDigest(')
        self.assertIn('replaceBytesInRange:', helper)
        self.assertIn('withBytes:"false" length:5', helper)

    def test_unchanged_assets_not_staged_backed_up_or_rewritten(self):
        download = section('- (void)downloadRevertNext {', '- (void)applyRevert {')
        skip = download.index('if ([MDGitBlobDigest(existing) isEqual:record[@"sha"]])')
        fetch = download.index('getBlobData:')
        self.assertLess(skip, fetch)
        self.assertNotIn('self.staged[local] = existing', download)
        apply = section('- (void)applyRevert {', '- (void)resumePending:')
        self.assertIn('for (NSString *local in self.staged)', apply)
        self.assertIn('self.staged.allKeys', apply)
        self.assertIn('for (NSString *local in self.before)', apply)

    def test_backup_precedes_archive_and_native_install_is_guarded(self):
        apply = section('- (void)applyRevert {', '- (void)resumePending:')
        self.assertLess(apply.index('writeToURL:journalURL'), apply.index('MDArchiveMany('))
        self.assertLess(apply.index('writeToURL:journalURL'), apply.index('!MDWrite('))
        for key in ('@"before"', '@"after"', '@"stateBefore"', '@"stateAfter"', '@"layoutBefore"', '@"layoutAfter"'):
            self.assertIn(key, apply)
        self.assertIn('dispatch_get_global_queue', apply)
        self.assertIn('self.store.revertInstalling = YES', apply)
        self.assertLess(apply.index('for (NSString *local in self.before)'), apply.index('!MDWrite('))
        self.assertIn('MDSaveState(self.root, newState', apply)
        self.assertIn('journal[@"phase"] = @"applied"', apply)
        self.assertGreaterEqual(MD.count('if (self.revertInstalling)'), 6)

    def test_interrupted_journal_and_layout_install_require_review(self):
        journal = section('static BOOL MDRevertJournalClear(', '@interface LBMdStore')
        self.assertIn('[@"phase"] isEqual:@"applied"', journal)
        self.assertIn('.longblog-layout-pending.json', journal)
        self.assertNotIn('removeItem', journal)
        self.assertNotIn('MDWrite', journal)

    def test_no_single_source_downgrade_or_untracked_delete(self):
        download = section('- (void)downloadRevertNext {', '- (void)applyRevert {')
        self.assertIn('MDSingleSource(self.root, note)', download)
        self.assertIn('[@"singleSourceVersion"] integerValue] < 1', download)
        apply = section('- (void)applyRevert {', '- (void)resumePending:')
        self.assertNotIn('removeItem', apply)
        self.assertNotIn('newState[@"head"] =', apply)

    @unittest.skipUnless(os.getenv('LB_ARTICLE_STRICT_COMPILE') == '1', 'opt-in iOS SDK syntax compile')
    def test_strict_compile_store_only(self):
        sdk = Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'
        self.assertTrue(sdk.exists())
        result = subprocess.run(['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
            '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc', '-fsyntax-only',
            '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-nullability-completeness',
            '-I', str(ROOT / 'src'), str(ROOT / 'src/LBMdStore.m')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


class DraftByteSafetyFixtures(unittest.TestCase):
    """Compile and execute the exact production C scanner, never a Python port."""
    @classmethod
    def setUpClass(cls):
        if not shutil.which('clang'):
            raise unittest.SkipTest('clang needed for production scanner fixture')
        cls.temp = tempfile.TemporaryDirectory(prefix='lb-revert-c-')
        cls.addClassCleanup(cls.temp.cleanup)
        function = 'static int MDRevertDraftRange(' + section('static int MDRevertDraftRange(', 'static NSData *MDRevertDraftData(')
        code = '#include <stddef.h>\n#include <string.h>\n' + function.replace('static int ', 'int ', 1)
        source = Path(cls.temp.name) / 'scanner.c'
        library = Path(cls.temp.name) / 'scanner.so'
        source.write_text(code)
        subprocess.run(['clang', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(library)], check=True, capture_output=True)
        cls.native = ctypes.CDLL(str(library)).MDRevertDraftRange
        cls.native.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t)]
        cls.native.restype = ctypes.c_int

    @classmethod
    def cancel(cls, data):
        start, end = ctypes.c_size_t(), ctypes.c_size_t()
        accepted = cls.native(data, len(data), ctypes.byref(start), ctypes.byref(end))
        if not accepted:
            return None
        assert data[start.value:end.value] == b'true'
        return data[:start.value] + b'false' + data[end.value:]

    def test_new_draft_lf_exact_body_comments_unknown_metadata(self):
        original = b'---\nid: "new"\n# author comment\npublish: true\ncustom: |\n  leave: everything\npublishedAt: "history"\n---\n\n# Body\n![x](/assets/new/new.bin)\n'
        self.assertEqual(self.cancel(original), original.replace(b'publish: true', b'publish: false', 1))

    def test_crlf_embedded_html_and_quoted_scalar_preserved_exactly(self):
        original = '---\r\nid: "new"\r\npublish:\t"true" # 保留注释\r\nbodyFormat: "html"\r\n---\r\n\r\n<div>原文\r\n\t&amp;</div>\r\n'.encode()
        self.assertEqual(self.cancel(original), original.replace(b'"true"', b'"false"', 1))

    def test_body_publish_is_never_changed(self):
        original = b'---\npublish: true\n---\npublish: true\n---\n'
        self.assertEqual(self.cancel(original), b'---\npublish: false\n---\npublish: true\n---\n')

    def test_duplicate_ambiguous_missing_or_malformed_metadata_refused(self):
        for data in (b'', b'publish: true\n', b'---\npublish: true\n',
                     b'---\npublish: true\npublish: false\n---\n',
                     b'---\npublish: trueish\n---\n', b'---\npublish: true evil\n---\n',
                     b'---\npublish: "true\n---\n', b'---\npublish: false\n---\n',
                     b'---\nother: true\n---\npublish: true\n'):
            with self.subTest(data=data):
                self.assertIsNone(self.cancel(data))

    def test_empty_body_and_no_final_newline(self):
        self.assertEqual(self.cancel(b'---\npublish: true\n---'), b'---\npublish: false\n---')

    def test_temporary_draft_attachment_and_sidecar_never_erased(self):
        with tempfile.TemporaryDirectory(prefix='lb-revert-new-draft-') as temp:
            root = Path(temp)
            md = root / 'index.md'
            asset = root / 'assets/new.bin'
            asset.parent.mkdir()
            asset.write_bytes(b'\x00\xffnew attachment\x00')
            html = root / 'index.html'
            html.write_bytes(b'<div>independent original</div>')
            md.write_bytes(b'---\nid: new\npublish: true\n---\n\nunsent text\n')
            before = {p.relative_to(root).as_posix(): p.read_bytes() for p in (md, asset, html)}
            md.write_bytes(self.cancel(md.read_bytes()))
            self.assertEqual(asset.read_bytes(), before['assets/new.bin'])
            self.assertEqual(html.read_bytes(), before['index.html'])
            self.assertTrue(md.read_bytes().endswith(b'\n\nunsent text\n'))

    def test_binary_before_after_journal_roundtrip_and_unchanged_filter_fixture(self):
        # Format/strategy fixture; native task wiring is checked above. Only paths
        # with differing bytes enter the journal, including binary attachments.
        before = {'a.md': b'local edited', 'assets/a/new.bin': b'\x00\xffnew', 'assets/a/old.bin': b'unchanged'}
        baseline = {'a.md': b'confirmed remote', 'assets/a/old.bin': b'unchanged'}
        changes = {p: data for p, data in baseline.items() if before.get(p) != data}
        journal = {'phase': 'prepared', 'before': {p: base64.b64encode(before[p]).decode() for p in changes},
                   'after': {p: base64.b64encode(data).decode() for p, data in changes.items()}}
        loaded = json.loads(json.dumps(journal))
        self.assertEqual(base64.b64decode(loaded['before']['a.md']), b'local edited')
        self.assertEqual(base64.b64decode(loaded['after']['a.md']), b'confirmed remote')
        self.assertNotIn('assets/a/old.bin', loaded['after'])
        self.assertNotIn('assets/a/new.bin', loaded['after'])
        self.assertEqual(before['assets/a/new.bin'], b'\x00\xffnew')
        sha = hashlib.sha1(b'blob 16\x00confirmed remote').hexdigest()
        self.assertEqual(len(sha), 40)


if __name__ == '__main__':
    unittest.main()

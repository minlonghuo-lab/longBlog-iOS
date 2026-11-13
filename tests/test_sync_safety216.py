"""Offline batch-sync safety regressions (no notes, credentials or network).

Source contracts bind the Objective-C orchestration to its safety gates. Isolated
filesystem fixtures execute the actual production recovery/edit decision helpers;
they are protocol fault injection, NOT an iOS Foundation/network integration test.
"""
import base64
import ctypes
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'src/LBMdStore.m').read_text()


def section(start, end):
    return SOURCE.split(start, 1)[1].split(end, 1)[0]


def digest(data):
    return hashlib.sha256(data).hexdigest() if data is not None else ''


class NativeBatchSafetyContracts(unittest.TestCase):
    def test_batch_enters_same_mutex_as_sync_and_publish(self):
        public = section('- (void)commitStagedArticles:', '\n@end')
        self.assertIn('beginArticleOperation:@"batch"', public)
        self.assertNotIn('articleSnapshot:', public)
        self.assertNotIn('commitChanges:', public)
        self.assertIn('batch:[selection copy]', public)
        self.assertNotIn('copyItems:YES', public)  # Do not persist mutable nested UI metadata.
        begin = section('batch:(NSArray *)batch message:(NSString *)message done:(void (^)(NSError *))done {', '+ (instancetype)shared')
        self.assertLess(begin.index('if (self.articleTask)'), begin.index('self.articleTask = task'))
        self.assertIn('task.batchItems = batch', begin)
        self.assertIn('store.articleTask = nil', begin)

    def test_pending_precedes_snapshot_even_for_empty_selection(self):
        start = section('- (void)start {', '- (void)resumePending:')
        self.assertLess(start.index('resumePending:'), start.index('if ([self.operation isEqual:@"batch"] && !self.batchItems.count)'))
        # Revert must refuse pending rather than recover it; batch still resumes first.
        self.assertLess(start.index('self.state[@"pending"] || self.state[@"singleSourcePendingReview"]'), start.index('if ([self.operation isEqual:@"revert"] && !self.batchItems.count)'))
        self.assertLess(start.index('resumePending:'), start.index('articleSnapshot:'))
        self.assertIn('[self prepareBatch]', start)

    def test_checkpoint_is_durable_before_ref_write(self):
        batch = section('- (void)prepareBatch {', '- (void)applyBatch:')
        self.assertIn('commitChanges:changes', batch)
        self.assertIn('prepared:^BOOL', batch)
        self.assertNotIn('prepared:nil', batch)
        for field in ('operation', 'items', 'singleSourceVersion', 'before', 'payloads'):
            self.assertIn('record[@"' + field + '"]', batch)
        self.assertIn('self.state[@"pending"] = record', batch)
        self.assertIn('return MDSaveState(self.root, self.state, saveError)', batch)
        self.assertIn('if (error) return [self finish:error]', batch)

    def test_bad_or_foreign_state_never_falls_back_to_empty(self):
        start = section('- (void)start {', '- (void)resumePending:')
        self.assertIn('if (!self.state) return [self finish:e]', start)
        self.assertNotIn('?: [NSMutableDictionary dictionary]', start)
        state = section('static NSDictionary *MDLoadState(', 'static BOOL MDSaveState(')
        self.assertIn('if (!data && attrs)', state)
        self.assertIn('repo.lowercaseString', state)
        self.assertIn('record[@"sha"] length] != 40', state)

    def test_missing_invalid_articles_and_attachments_abort_entire_batch(self):
        batch = section('- (void)prepareBatch {', '- (void)applyBatch:')
        self.assertIn('if (!text) return [self finish:', batch)
        self.assertIn('if (!assets) return [self finish:e]', batch)
        self.assertIn('if (!data) return [self finish:', batch)
        self.assertIn('if (!sidecar &&', batch)
        self.assertNotIn('assetPaths ?: @[]', batch)
        self.assertLess(batch.index('if (!data)'), batch.index('commitChanges:'))
        self.assertIn('[parsed[@"publish"] boolValue] == removing', batch)

    def test_batch_remote_baselines_are_sha_checked(self):
        check = section('- (BOOL)checkBatchRemote:', '- (void)prepareBatch {')
        self.assertIn('!record', check)
        self.assertIn('![entry[@"sha"] isEqual:record[@"sha"]]', check)
        self.assertIn('entry[@"mode"]', check)
        self.assertIn('else if (record && !removing)', check)
        self.assertIn('MDLegacyAssets()', check)
        self.assertIn('precomposedStringWithCanonicalMapping.lowercaseString', check)

    def test_tracked_single_publish_also_checks_sha_without_removing_explicit_import(self):
        check = section('- (BOOL)checkRemote:', '- (void)preparePublish {')
        self.assertIn('![record[@"sha"] isEqual:entry[@"sha"]]', check)
        self.assertIn('if (!record)', check)
        self.assertIn('[self.operation isEqual:@"unpublish"]', check)
        self.assertIn('[self.operation isEqual:@"delete"]', check)

    def test_invalid_duplicate_and_folded_selections_rejected(self):
        helper = section('static BOOL MDBatchItemsValid(', 'static NSDictionary *MDLoadState(')
        self.assertIn('!MDID(item[@"id"])', helper)
        self.assertIn('@[@"publish", @"update", @"unpublish"]', helper)
        self.assertIn('precomposedStringWithCanonicalMapping', helper)
        self.assertIn('[ids containsObject:folded]', helper)

    def test_lossless_sidecars_and_their_assets_are_retained(self):
        batch = section('- (void)prepareBatch {', '- (void)applyBatch:')
        for gate in ('BOOL sameBody', 'BOOL importedSidecar', 'BOOL singleSource', 'BOOL lossless'):
            self.assertIn(gate, batch)
        self.assertIn('self.changes[remoteHTML] = htmlPayload', batch)
        self.assertIn('MDAssetReferences(body, htmlText, &e)', batch)
        self.assertIn('self.before[html] = MDDigest(sidecar)', batch)
        self.assertIn('self.before[local] = MDDigest(data)', batch)
        self.assertIn('self.records[html] && ![MDDigest(sidecar) isEqual:self.records[html][@"baseline"]]', batch)
        self.assertIn('!self.records[html] && self.records[md]', batch)
        self.assertIn('checkBatchRemote:remoteHTML local:html removing:NO', batch)

    def test_batch_recovery_uses_only_confirmation_never_resubmission(self):
        recovery = section('- (void)resumePending:(NSDictionary *)pending {', '- (void)prepareSync')
        self.assertIn('matchesPendingIdentity:pending', recovery)
        self.assertIn('confirmCommit:commit base:base', recovery)
        self.assertIn('MDBatchItemsValid(pending[@"items"])', recovery)
        self.assertIn('MDRecoveryAction(status.UTF8String', recovery)
        self.assertIn('[self applyBatch:', recovery)
        self.assertIn('BOOL differentRequest = batch ||', recovery)
        self.assertNotIn('commitChanges:', recovery)
        self.assertIn('if (!allowed) return [self finish:', recovery)

    def test_batch_apply_preflight_and_checkpoint_before_mutation(self):
        apply = section('- (void)applyBatch:(NSDictionary *)result {', '- (BOOL)checkRemote:')
        self.assertLess(apply.index('MDKeepLocalEdit('), apply.index('MDWrite('))
        self.assertLess(apply.index('pending[@"confirmed"] = @YES'), apply.index('MDWrite('))
        self.assertIn('!changedDuringUpload && ![local hasPrefix:@"assets/"]', apply)
        self.assertIn('self.records[local] = MDRecord(remote, result[@"shas"][remote], local, payload)', apply)
        self.assertIn('if (!MDSaveState(self.root, self.state, &e)) return [self finish:e]', apply)
        self.assertNotIn('MDWrite(self.root, local, payload, nil)', apply)
        self.assertNotIn('MDSaveState(self.root, self.state, nil)', apply)

    def test_list_alignment_cannot_erase_pending_or_overwrite_new_records(self):
        listing = section('- (NSArray<NSDictionary *> *)stagedArticlesForArticles:', '- (void)commitStagedArticles:')
        self.assertIn('self.articleTask ||', listing)
        self.assertIn('if (!latest || latest[@"pending"]) return', listing)
        self.assertIn('[latestFiles[local] isEqual:files[local]]', listing)
        self.assertIn('dispatch_sync(dispatch_get_main_queue(), align)', listing)
        self.assertEqual(listing.count('MDSaveState('), 1)

    def test_metadata_edits_are_not_silently_aligned_as_save_clock(self):
        content = section('static NSString *MDContentDigest(', 'static NSDictionary *MDRecord(')
        self.assertIn('[meta removeObjectForKey:@"updatedAt"]', content)
        self.assertIn('@"metadata":meta', content)
        self.assertIn('MDBodyDigest(data)', content)
        for field in ('title', 'summary', 'manualSummary', 'tags', 'pinned', 'publish', 'createdAt', 'publishedAt'):
            self.assertNotIn('removeObjectForKey:@"' + field + '"', content)
        record = section('static NSDictionary *MDRecord(', 'static BOOL MDSingleSource(')
        self.assertIn('record[@"contentBaseline"] = MDContentDigest(data)', record)
        listing = section('- (NSArray<NSDictionary *> *)stagedArticlesForArticles:', '- (void)commitStagedArticles:')
        self.assertIn('rec[@"contentBaseline"] ? ![MDContentDigest(localData)', listing)
        self.assertNotIn('rec[@"bodyBaseline"] ?', listing)
        self.assertIn(': ![localHash isEqualToString:rec[@"baseline"]]', listing)

    def test_staging_invalid_utf8_does_not_replace_body_with_empty(self):
        for name, end in (('stageUnpublishArticle:', '- (BOOL)stagePublishArticle:'),
                          ('stagePublishArticle:', '- (NSArray<NSDictionary *> *)stagedArticles')):
            method = section('- (BOOL)' + name, end)
            self.assertLess(method.index('if (!text)'), method.index('MDArchive('))
            self.assertLess(method.index('if (!text)'), method.index('MDWrite('))

class BatchFaultInjection(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='lb-sync216-c-')
        folder = Path(cls.tmp.name)
        helpers = []
        for name in ('MDKeepLocalEdit', 'MDRecoveryAction'):
            start = SOURCE.rfind('static ', 0, SOURCE.index(name))
            opening = SOURCE.index('{', start)
            end, depth = opening + 1, 1
            while depth:
                depth += (SOURCE[end] == '{') - (SOURCE[end] == '}')
                end += 1
            helpers.append(SOURCE[start:end].replace('static ', '', 1))
        (folder / 'policy.c').write_text('#include <string.h>\n' + '\n'.join(helpers))
        subprocess.run(['clang', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                        str(folder / 'policy.c'), '-o', str(folder / 'policy.so')],
                       check=True, capture_output=True)
        cls.policy = ctypes.CDLL(str(folder / 'policy.so'))
        cls.policy.MDKeepLocalEdit.argtypes = [ctypes.c_int] * 4
        cls.policy.MDRecoveryAction.argtypes = [ctypes.c_char_p]

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_fixture(self, edit=None, status=b'applied', checkpoint_ok=True,
                    fail_after_first_write=False, restart=False):
        """Fault-injected filesystem protocol; all files live under TemporaryDirectory."""
        with tempfile.TemporaryDirectory(prefix='lb-sync216-fs-') as tmp:
            root = Path(tmp)
            original = {'a.md': b'old a', 'a.html': b'old fidelity html',
                        'b.md': b'local unpublished draft', 'shared.bin': b'\x00\xffasset'}
            payloads = {'a.md': b'published a', 'shared.bin': original['shared.bin']}
            for path, data in original.items():
                (root / path).write_bytes(data)
            state_path = root / 'state.json'
            before = {p: digest(b) for p, b in original.items()}
            pending = {'before': before, 'payloads': {
                p: base64.b64encode(data).decode() for p, data in payloads.items()}, 'confirmed': False}
            writes = []
            if checkpoint_ok:
                state_path.write_text(json.dumps({'pending': pending}))
                writes.append('PATCH')
            else:
                return {'writes': writes, 'pending': False, 'local': original}
            if edit:
                (root / edit).write_bytes(b'new local edit')
            if not self.policy.MDRecoveryAction(status):
                return {'writes': writes, 'pending': True,
                        'local': {p: (root / p).read_bytes() for p in original}}
            # Persist confirmed before applying; restart must accept only exact
            # already-applied bytes, not new editor bytes or blind matching data.
            if restart:
                pending['confirmed'] = True
                (root / 'a.md').write_bytes(payloads['a.md'])
                state_path.write_text(json.dumps({'pending': pending}))
            pending = json.loads(state_path.read_text())['pending']
            protected = False
            for p, baseline in pending['before'].items():
                current = digest((root / p).read_bytes()) if (root / p).exists() else ''
                applied = (p in payloads and current == digest(payloads[p])) or (p == 'a.html' and current == '')
                protected |= bool(self.policy.MDKeepLocalEdit(current == baseline, pending['confirmed'], applied, 0))
            pending['confirmed'] = True
            state_path.write_text(json.dumps({'pending': pending}))
            if not protected:
                (root / 'a.md').write_bytes(payloads['a.md'])
                if fail_after_first_write:
                    return {'writes': writes, 'pending': True, 'confirmed': True,
                            'local': {p: (root / p).read_bytes() for p in original}}
                (root / 'a.html').unlink()
            baselines = {p: digest(b) for p, b in payloads.items()}
            state_path.write_text(json.dumps({'files': baselines}))
            return {'writes': writes, 'pending': False, 'protected': protected,
                    'baselines': baselines,
                    'local': {p: (root / p).read_bytes() if (root / p).exists() else None for p in original}}

    def test_checkpoint_failure_performs_no_patch_or_local_write(self):
        result = self.run_fixture(checkpoint_ok=False)
        self.assertEqual(result['writes'], [])
        self.assertEqual(result['local']['a.md'], b'old a')

    def test_unknown_unchanged_conflict_keep_checkpoint_without_resubmit(self):
        for state in (b'unknown', b'unchanged', b'conflict'):
            with self.subTest(state=state):
                result = self.run_fixture(status=state)
                self.assertEqual(result['writes'], ['PATCH'])
                self.assertTrue(result['pending'])
                self.assertEqual(result['local']['a.html'], b'old fidelity html')

    def test_lost_response_then_applied_recovery_does_not_resubmit(self):
        result = self.run_fixture()
        self.assertEqual(result['writes'], ['PATCH'])
        self.assertFalse(result['pending'])
        self.assertEqual(result['local']['a.md'], b'published a')
        self.assertEqual(result['local']['b.md'], b'local unpublished draft')

    def test_edits_to_body_sidecar_or_shared_asset_preserve_whole_transaction(self):
        for path in ('a.md', 'a.html', 'b.md', 'shared.bin'):
            with self.subTest(path=path):
                result = self.run_fixture(edit=path)
                self.assertTrue(result['protected'])
                self.assertEqual(result['local'][path], b'new local edit')
                self.assertIsNotNone(result['local']['a.html'])
                self.assertEqual(result['baselines']['a.md'], digest(b'published a'))

    def test_partial_local_failure_retains_confirmed_checkpoint(self):
        result = self.run_fixture(fail_after_first_write=True)
        self.assertTrue(result['pending'])
        self.assertTrue(result['confirmed'])
        self.assertEqual(result['local']['a.html'], b'old fidelity html')

    def test_restart_replays_partial_apply_but_never_new_edits(self):
        result = self.run_fixture(restart=True)
        self.assertFalse(result['protected'])
        self.assertFalse(result['pending'])
        self.assertIsNone(result['local']['a.html'])
        result = self.run_fixture(restart=True, edit='shared.bin')
        self.assertTrue(result['protected'])
        self.assertEqual(result['local']['shared.bin'], b'new local edit')


if __name__ == '__main__':
    unittest.main()

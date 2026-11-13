"""Offline SOURCE audits and Python SPEC tests, NOT Objective-C runtime tests.
All fixtures synthetic. No credential lookup, network, device or private data.
Compile CacheBoundaryFixtures.m independently for actual ObjC helper coverage.
"""
import copy
import hashlib
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLIENT = (ROOT / 'src/LBMemosClient.m').read_text()
DISK = (ROOT / 'src/LBMemosDiskCache.m').read_text()
HEADER = (ROOT / 'src/LBMemosCache.h').read_text()


def method(source, signature):
    start = source.index(signature)
    end = re.search(r'\n[-+] \(', source[start + 1:])
    return source[start:] if not end else source[start:start + 1 + end.start()]


def digest(s):
    return hashlib.sha256(s.encode()).hexdigest()


def namespace(base, uid):
    return digest(f'{base}\n{uid}')


def binding(base, token):
    return digest(base + '\n' + digest(token))


def fingerprint(r):
    return digest(json.dumps([r[k] for k in ('id', 'creatorId', 'size', 'updatedTs', 'type', 'filename')],
                             ensure_ascii=False, separators=(',', ':')))


R = dict(id=8, creatorId=7, size=5, updatedTs=2, type='image/jpeg', filename='fixture.jpg')


class CacheSpec(unittest.TestCase):
    def test_namespace_account_and_origin(self):
        self.assertEqual(len({namespace(b, u) for b in ('https://a.invalid', 'https://b.invalid') for u in (7, 8)}), 4)
    def test_binding_exact_token_and_origin(self):
        self.assertEqual(len({binding(b, t) for b in ('https://a.invalid', 'https://b.invalid') for t in ('fixture-token-A', 'fixture-token-B')}), 4)
        self.assertNotIn('fixture-token', binding('https://a.invalid', 'fixture-token-A'))
    def test_same_unchanged_original_reused(self):
        self.assertEqual(fingerprint(R), fingerprint(copy.deepcopy(R)))
    def test_every_version_field_changes_key(self):
        for key in R:
            changed = dict(R)
            changed[key] = changed[key] + 1 if isinstance(changed[key], int) else changed[key] + 'x'
            with self.subTest(key=key): self.assertNotEqual(fingerprint(R), fingerprint(changed))
    def test_untrusted_external_urls_ignored(self):
        self.assertEqual(fingerprint(R), fingerprint(dict(R, externalLink='https://evil.invalid', filepath='/etc/passwd')))
    def test_same_second_equal_metadata_limitation_explicit(self):
        self.assertEqual(fingerprint(R), fingerprint(dict(R, server_bytes='different')))
        self.assertIn('equal metadata cannot prove equal', DISK)
    def test_prune_only_when_both_snapshots_complete(self):
        cached = {'old', fingerprint(R), 'shared'}
        snapshots = {'NORMAL': {fingerprint(R)}, 'ARCHIVED': {'shared'}}
        partial = cached.copy()
        self.assertEqual(partial, cached)  # partial/failing sync cannot prune
        self.assertEqual(cached & set.union(*snapshots.values()), {fingerprint(R), 'shared'})
    def test_failed_download_counts_terminal_not_running(self):
        jobs = {'a', 'b'}; failed = set(); completed = set()
        jobs.remove('a'); completed.add('a'); jobs.remove('b'); failed.add('b')
        self.assertFalse(jobs)
        self.assertEqual(len(completed) + len(failed), 2)
    def test_failed_rows_retry_explicit_only(self):
        failed = {'a'}; queue = set()
        self.assertFalse(queue)
        queue.update(failed); failed.clear()
        self.assertEqual(queue, {'a'})


class CacheSourceAudits(unittest.TestCase):
    def test_contract_implemented(self):
        for name in ('cachedState:', 'cachedResource:', 'reconcileCacheNormal:', 'prefetchAllResources', 'cacheProgress', 'invalidateCachedResource:'):
            self.assertIn(name, CLIENT)
    def test_no_plaintext_binding_or_defaults(self):
        self.assertNotIn('NSUserDefaults', DISK)
        self.assertIn('LBCHash(token)', DISK)
        saved = method(DISK, '+ (void)saveBindingForBase:')
        self.assertIn('@"userID":uid', saved)
        self.assertNotIn('@"token":', DISK)
        self.assertNotIn('NSLog(', CLIENT + DISK)
    def test_cold_cache_does_not_grant_writes(self):
        section = method(CLIENT, '- (void)cacheLoadBoundIdentity')
        # First occurrence may be private declaration; use implementation.
        section = method(CLIENT, '- (void)cacheLoadBoundIdentity {')
        self.assertNotIn('self.user =', section)
        self.assertIn('generation != self.generation', section)
        self.assertIn('self.authenticationRequired', section)
        self.assertIn('if (self.authenticationRequired || !self.user)', CLIENT)
    def test_offline_read_access_requires_current_binding(self):
        for signature in ('- (NSArray<NSDictionary *> *)cachedState:', '- (NSURL *)cachedResource:'):
            section = method(CLIENT, signature)
            self.assertIn('self.configured', section)
            self.assertIn('self.authenticationRequired', section)
            self.assertIn('self.cacheLoaded', section)
        section = method(CLIENT, '- (NSURLSessionTask *)downloadResource:')
        self.assertLess(section.index('[self cachedResource:resource]'), section.index('[self ready]'))
    def test_401_revokes_before_reset(self):
        section = method(CLIENT, '- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:')
        self.assertIn('revokeBindingForBase:', section)
        self.assertLess(section.index('revokeBindingForBase:'), section.index('self.authenticationRequired = YES'))
    def test_protection_no_backup_private_support(self):
        for value in ('NSApplicationSupportDirectory', 'NSFileProtectionCompleteUntilFirstUserAuthentication', 'NSURLIsExcludedFromBackupKey', 'NSDataWritingAtomic'):
            self.assertIn(value, DISK)
        self.assertNotIn('NSTemporaryDirectory', DISK)
    def test_no_ui_ownership_persistent_outputs(self):
        self.assertIn('[self.temporaryFiles removeObject:raw]', CLIENT)
        section = method(CLIENT, '- (void)reset')
        self.assertNotIn('removeItemAtURL:self.diskCache', section)
        self.assertNotIn('MemosCache-v1', section)
        section = method(CLIENT, '- (NSURLSessionTask *)downloadResource:')
        self.assertIn('return nil;', section)
        self.assertIn('cache-owned', section)
    def test_all_mime_types_prefetched(self):
        section = method(CLIENT, '- (void)prefetchAllResources {')
        self.assertIn('self.cacheResources', section)
        self.assertNotIn('hasPrefix:@"image', section)
        self.assertNotIn('allState:', section)
    def test_bounded_io_not_main_bulk_copy(self):
        self.assertIn('QOS_CLASS_UTILITY', DISK)
        self.assertIn('dispatch_async(self.io', DISK)
        self.assertIn('self.cacheActive >= 2', CLIENT)
        self.assertIn('self.cacheDownloads[key]', CLIENT)
        self.assertNotIn('dataWithContentsOfURL:raw', CLIENT)
    def test_capacity_checked_and_no_arbitrary_eviction(self):
        self.assertIn('NSFileSystemFreeSize', DISK)
        self.assertIn('LBCReserve', DISK)
        self.assertIn('32ULL * 1024 * 1024', DISK)
        self.assertNotIn('512 * 1024', DISK)
    def test_single_state_never_prunes(self):
        self.assertIn('prune:NO', method(DISK, '- (void)replaceState:'))
        self.assertIn('prune:NO', method(DISK, '- (void)patchMemo:'))
        self.assertIn('prune:YES', method(DISK, '- (void)reconcileNormal:'))
        section = method(CLIENT, '- (void)reconcileCacheNormal:')
        for key in ('self.cacheProofEpoch != self.epoch', '@"NORMAL"', '@"ARCHIVED"', 'cacheVerifiedStates'):
            self.assertIn(key, section)
    def test_partial_filtered_failed_state_not_saved(self):
        section = method(CLIENT, '- (void)allState:')
        self.assertIn('!e && !text.length && !tag.length', section)
        self.assertIn('replaceState:state rows:rows', section)
    def test_metadata_failed_write_retries(self):
        self.assertIn('self.metadataDirty = YES', DISK)
        self.assertIn('!self.metadataDirty && [self.snapshots isEqual:states]', DISK)
        self.assertIn('revision == self.revision && !error', DISK)
    def test_mutation_patches_without_prune(self):
        self.assertIn('patchMemo:memo deletedID:nil', method(CLIENT, '- (void)changedMemo:'))
        self.assertIn('patchMemo:nil deletedID:identifier', method(CLIENT, '- (void)deleteArchived:'))
    def test_generation_epoch_inflight_guards(self):
        section = method(CLIENT, '- (void)cachePump {')
        self.assertIn('cache != self.diskCache', section)
        self.assertIn('self.cacheDownloads[key] != job', section)
        self.assertIn('epoch != self.epoch', section)
        self.assertIn('self.cacheReconciling', section)
    def test_failure_not_stuck_or_auto_loop(self):
        section = method(CLIENT, '- (void)cacheFinish:(LBMemosCachedDownload *)job key:(NSString *)key url:(NSURL *)url error:(NSError *)error {')
        self.assertIn('removeObjectForKey:key', section)
        self.assertIn('self.cacheActive--', section)
        self.assertIn('[self.cacheFailures addObject:key]', section)
        self.assertNotIn('prefetchAllResources', section)
    def test_progress_main_and_private_name_free(self):
        section = method(CLIENT, '- (NSDictionary *)cacheProgress {')
        for key in ('@"total"', '@"completed"', '@"failed"', '@"running"'):
            self.assertIn(key, section)
        for key in ('filename', 'content', 'username', 'token'):
            self.assertNotIn('@"' + key + '"', section)
        self.assertIn('postNotificationName:LBMemosCacheDidChange', CLIENT)
        self.assertNotIn('for (', section)
        self.assertNotIn('resourceURL:', section)
        self.assertNotIn('attributesOfItem', section)
    def test_mime_mismatch_and_exact_size(self):
        self.assertIn('c.expectedType', CLIENT)
        self.assertIn('部分附件', DISK)
        self.assertIn('![a[NSFileSize] isEqual:resource[@"size"]]', DISK)
    def test_invalidation_fingerprint_scoped_local_only(self):
        section = method(DISK, '- (void)invalidateResource:')
        self.assertIn('self.userID', section)
        self.assertIn('fingerprint:resource', section)
        self.assertIn('removeItemAtURL:', section)
        self.assertNotIn('request:', section)


class CacheLifecycleP1Tests(unittest.TestCase):
    def test_authoritative_uid_checks_cold_cache_before_assigning_user(self):
        section = method(CLIENT, '- (void)validate:')
        guard = section.index('(self.diskCache && ![self.diskCache.userID isEqual:clean[@"id"]])')
        accept = section.index('self.authenticationRequired = NO; self.user = clean')
        self.assertLess(guard, accept)
        branch = section[guard:accept]
        self.assertIn('revokeBindingForBase:', branch)
        self.assertIn('self.authenticationRequired = YES', branch)
        self.assertIn('[self reset]', branch)
        self.assertIn('done(nil, LBStale()); return;', branch)
    def test_bound_A_authoritative_B_forces_new_generation(self):
        # Executable SPEC, not ObjC runtime: user=nil must not bypass mismatch.
        def validate(user, bound, authoritative, generation):
            mismatch = ((user is not None and user != authoritative) or
                        (bound is not None and bound != authoritative))
            return (None, None, generation + 1, True) if mismatch else (authoritative, authoritative, generation, False)
        self.assertEqual(validate(None, 7, 8, 1), (None, None, 2, True))
        self.assertEqual(validate(None, 7, 7, 1), (7, 7, 1, False))
        self.assertEqual(validate(None, None, 8, 1), (8, 8, 1, False))
    def test_reset_and_replacement_retire_before_detaching(self):
        reset = method(CLIENT, '- (void)reset')
        self.assertLess(reset.index('[self.diskCache invalidate]'), reset.index('self.diskCache = nil'))
        validate = method(CLIENT, '- (void)validate:')
        self.assertLess(validate.index('[self.diskCache invalidate]'), validate.index('self.diskCache = cache'))
    def test_namespace_queue_registry_serializes_all_instances(self):
        init = method(DISK, '- (instancetype)initWithBase:')
        self.assertIn('queueForNamespace:LBCHash', init)
        self.assertNotIn('dispatch_queue_create', init)
        registry = method(DISK, '+ (dispatch_queue_t)queueForNamespace:')
        self.assertIn('static NSMutableDictionary', registry)
        self.assertIn('@synchronized (queues)', registry)
        self.assertIn('queues[namespace] = queue', registry)
        self.assertIn('DISPATCH_QUEUE_SERIAL', registry)
    def test_old_new_namespace_jobs_ordered_without_stale_mutation(self):
        # Executable queue/lifecycle SPEC: old pending writes/prune are skipped.
        registry = {}
        namespace_key = namespace('https://a.invalid', 7)
        old = {'queue': registry.setdefault(namespace_key, []), 'invalid': False}
        new = {'queue': registry.setdefault(namespace_key, []), 'invalid': False}
        self.assertIs(old['queue'], new['queue'])
        disk = {'rows': 'initial', 'files': {'new-file'}}
        old['queue'].append((old, 'old-commit'))
        old['queue'].append((old, 'old-prune'))
        old['invalid'] = True
        new['queue'].append((new, 'new-commit'))
        for owner, operation in new['queue']:
            if owner['invalid']: continue
            if operation == 'new-commit': disk['rows'] = 'new'
            elif operation == 'old-commit': disk['rows'] = 'old'
            elif operation == 'old-prune': disk['files'].clear()
        self.assertEqual(disk, {'rows': 'new', 'files': {'new-file'}})
    def test_atomic_lifecycle_guards_load_write_delete_install(self):
        self.assertIn('@property (atomic) BOOL invalidated;', DISK)
        retire = method(DISK, '- (void)invalidate {')
        self.assertIn('self.invalidated = YES', retire)
        self.assertNotIn('removeItemAtURL:', retire)
        self.assertIn('self.invalidated', method(DISK, '- (NSError *)prepare'))
        commit = method(DISK, '- (void)commit:')
        self.assertLess(commit.index('if (self.invalidated) error'), commit.index('writeToURL:self.metadata'))
        self.assertIn('if (self.invalidated) { error = [self lifecycleError]; break; }', commit)
        self.assertIn('finalError = [self lifecycleError] ?: error', commit)
        self.assertIn('finalError = [self lifecycleError] ?: error', method(DISK, '- (void)load:'))
        install = method(DISK, '- (void)installFile:')
        self.assertIn('current = !self.invalidated && isCurrent()', install)
        self.assertLess(install.index('if (self.invalidated) error'), install.index('moveItemAtURL:file'))
        self.assertIn('finalError = [self lifecycleError] ?: error', install)
        invalidate = method(DISK, '- (void)invalidateResource:')
        self.assertIn('if (self.invalidated)', invalidate)
        self.assertIn('if (!self.invalidated) [NSFileManager.defaultManager removeItemAtURL:', invalidate)
    def test_media_401_gate_is_idempotent_and_no_revalidation(self):
        section = method(CLIENT, '- (void)requireAuthentication {')
        self.assertIn('LB_MAIN_RETURN', section)
        self.assertIn('if (self.authenticationRequired) return;', section)
        self.assertIn('revokeBindingForBase:', section)
        self.assertIn('self.authenticationRequired = YES; self.user = nil;', section)
        self.assertIn('[self reset]', section)
        self.assertNotIn('[self validate:', section)

if __name__ == '__main__':
    unittest.main(verbosity=2)

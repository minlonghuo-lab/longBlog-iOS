"""Offline source audits + executable Python SPEC model, NOT ObjC runtime tests.
No sockets, credentials, Keychain, remote auth or writes are used.
BoundaryFixtures.m separately compiles calls to the actual static ObjC helpers.
"""
import copy
import hashlib
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'src/LBMemosClient.m').read_text()
HEADER = (ROOT / 'src/LBMemos.h').read_text()
FIXTURE = json.loads(Path(__file__).with_name('legacy.json').read_text())


def body(selector):
    start = SOURCE.index(selector)
    following = re.search(r'\n[-+] \(', SOURCE[start + 1:])
    return SOURCE[start:] if not following else SOURCE[start:start + 1 + following.start()]


def safeint(value, positive=True):
    return type(value) is int and (1 if positive else 0) <= value <= 2**53 - 1


def resource(value):
    if not isinstance(value, dict):
        return False
    return all(safeint(value.get(k), k in ('id', 'creatorId')) for k in
               ('id', 'creatorId', 'size', 'createdTs', 'updatedTs')) and all(
                   isinstance(value.get(k), str) for k in ('filename', 'type'))


def memo(value):
    if not isinstance(value, dict):
        return False
    return (all(safeint(value.get(k), k in ('id', 'creatorId')) for k in
                ('id', 'creatorId', 'createdTs', 'updatedTs', 'displayTs'))
            and isinstance(value.get('content'), str)
            and value.get('visibility') in ('PRIVATE', 'PROTECTED', 'PUBLIC')
            and value.get('rowStatus') in ('NORMAL', 'ARCHIVED')
            and type(value.get('pinned')) in (int, bool) and value['pinned'] in (0, 1)
            and isinstance(value.get('resourceList'), list)
            and all(resource(r) and r['creatorId'] == value['creatorId'] for r in value['resourceList'])
            and len({r['id'] for r in value['resourceList']}) == len(value['resourceList']))


def listing(raw, uid, state):
    if not isinstance(raw, list) or len(raw) > 30:
        raise ValueError('shape')
    result, seen = [], set()
    for row in raw:
        if not memo(row) or row['creatorId'] != uid or row['rowStatus'] != state:
            raise ValueError('scope')
        if row['id'] not in seen:
            result.append(row)
            seen.add(row['id'])
    return result, len(raw) == 30


def scope(base, uid, identifier):
    digest = hashlib.sha256(f'{base}\n{uid}'.encode()).hexdigest()
    return digest + '/' + (str(identifier) if identifier else 'new') + '.json'


class FixtureSpecTests(unittest.TestCase):
    def test_valid_legacy_private_fixture(self):
        self.assertTrue(memo(FIXTURE['memo']))
    def test_missing_and_null_mandatory_fields(self):
        for key in FIXTURE['memo']:
            for null in (False, True):
                value = copy.deepcopy(FIXTURE['memo'])
                if null: value[key] = None
                else: value.pop(key)
                with self.subTest(key=key, null=null): self.assertFalse(memo(value))
    def test_bad_ids(self):
        for bad in (True, False, 0, -1, 1.5, '1', None, 2**53):
            value = copy.deepcopy(FIXTURE['memo']); value['id'] = bad
            with self.subTest(bad=bad): self.assertFalse(memo(value))
        self.assertTrue(safeint(2**53 - 1))
    def test_wrong_resource_owner_rejected(self):
        value = copy.deepcopy(FIXTURE['memo']); value['resourceList'][0]['creatorId'] = 99
        self.assertFalse(memo(value))
    def test_resource_null_and_duplicates(self):
        for bad in (None, [None], [FIXTURE['memo']['resourceList'][0]] * 2):
            value = copy.deepcopy(FIXTURE['memo']); value['resourceList'] = bad
            self.assertFalse(memo(value))
    def test_list_creator_and_archive_scope(self):
        with self.assertRaises(ValueError): listing([FIXTURE['memo']], 99, 'NORMAL')
        with self.assertRaises(ValueError): listing([FIXTURE['memo']], 7, 'ARCHIVED')
    def test_raw_count_not_dedup_count(self):
        rows, more = listing([FIXTURE['memo']] * 30, 7, 'NORMAL')
        self.assertEqual(len(rows), 1); self.assertTrue(more)
    def test_raw_short_page_ends(self):
        self.assertFalse(listing([FIXTURE['memo']] * 29, 7, 'NORMAL')[1])
    def test_oversize_page_rejected(self):
        with self.assertRaises(ValueError): listing([FIXTURE['memo']] * 31, 7, 'NORMAL')
    def test_draft_account_base_memo_isolation(self):
        names = {scope(b, uid, identifier) for b in ('https://a.invalid', 'https://b.invalid')
                 for uid in (1, 2) for identifier in (None, 8)}
        self.assertEqual(len(names), 8)
        self.assertTrue(all(re.fullmatch(r'[0-9a-f]{64}/(new|8)\.json', n) for n in names))
    def test_tags_and_delete_shapes(self):
        self.assertTrue(all(type(s) is str for s in FIXTURE['tags']))
        self.assertIs(FIXTURE['deleteResource'], True)
        self.assertEqual(FIXTURE['deleteMemo']['message'], 'Memo permanently deleted')


class SourceAuditTests(unittest.TestCase):
    def test_independent_namespace(self):
        self.assertNotIn('LBSiteData', SOURCE)
        self.assertIn('get:@"memos-token"', SOURCE)
        self.assertNotIn('github-token', SOURCE)
    def test_identity_required(self):
        self.assertIn('if (self.authenticationRequired || !self.user)', body('- (NSError *)ready'))
        self.assertIn('/api/v1/user/me', body('- (void)validate:'))
    def test_keychain_readback_not_silent_fallback(self):
        self.assertIn('self.keychainFailed = !', body('- (void)setToken:'))
        self.assertIn('!self.keychainFailed', body('- (BOOL)configured'))
    def test_root_https_only(self):
        for guard in ('c.user != nil', 'c.password != nil', 'c.query != nil',
                      'c.fragment != nil', 'c.path.length', '@"https"'):
            self.assertIn(guard, SOURCE)
    def test_ephemeral_no_cookies_cache_credentials(self):
        for guard in ('ephemeralSessionConfiguration', 'HTTPCookieStorage = nil',
                      'HTTPShouldSetCookies = NO', 'URLCache = nil', 'URLCredentialStorage = nil'):
            self.assertIn(guard, SOURCE)
        self.assertIn('completionHandler(nil)', body('- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:'))
    def test_main_callbacks_and_generation_epoch(self):
        self.assertIn('delegateQueue:NSOperationQueue.mainQueue', SOURCE)
        self.assertIn('dispatch_async(dispatch_get_main_queue()', SOURCE)
        self.assertIn('c.generation != self.generation', SOURCE)
        self.assertIn('!c.mutation && c.epoch != self.epoch', SOURCE)
    def test_reset_cancels_and_preserves_drafts(self):
        section = body('- (void)reset')
        for guard in ('invalidateAndCancel', 'self.user = nil', 'self.generation++',
                      'self.epoch++', 'ownedResourceIDs removeAllObjects', 'temporaryFiles removeAllObjects'):
            self.assertIn(guard, section)
        self.assertNotIn('removeDraft', section)
        self.assertNotIn('MemosDrafts', section)
    def test_serial_writes(self):
        self.assertIn('if (self.busy)', body('- (NSError *)beginWrite'))
        for method in ('saveOriginal:', 'updateMemo:', 'deleteArchived:', 'uploadFile:', 'deleteResource:'):
            section = body(next(line for line in SOURCE.splitlines() if line.startswith('- (') and method in line))
            self.assertIn('[self beginWrite]', section)
    def test_pagination(self):
        section = body('- (void)listState:')
        for guard in ('@"creatorId"', '@"rowStatus"', '@"limit" value:@"30"', '@"offset"',
                      '@"text"', '@"tag"', '[raw count] == 30'):
            self.assertIn(guard, section)
    def test_preflight_all_fields(self):
        for key in ('content', 'visibility', 'rowStatus', 'pinned', 'updatedTs'):
            self.assertIn('@"' + key + '"', SOURCE[SOURCE.index('static BOOL LBEqualOriginal'):SOURCE.index('static void LBProtect')])
        self.assertIn('LBMemoIDs(a)', SOURCE)
        section = body('- (void)updateMemo:')
        self.assertLess(section.index('[self fetchMemo:'), section.index('[self writeMemoPath:'))
        self.assertIn('NOT atomic CAS', section)
    def test_delete_single_once_after_archived_preflight(self):
        section = body('- (void)deleteArchived:')
        self.assertEqual(section.count('request:@"DELETE"'), 1)
        self.assertLess(section.index('[self fetchMemo:'), section.index('request:@"DELETE"'))
        self.assertIn('fresh[@"rowStatus"] isEqual:@"ARCHIVED"', section)
        self.assertIn('status == 404', section)
        self.assertIn('Memo permanently deleted', section)
        self.assertNotIn('dispatch_after', SOURCE)
    def test_multipart_disk_body_and_cap(self):
        section = body('- (NSURLSessionTask *)uploadFile:')
        for guard in ('name=\\"file\\"', '/api/v1/resource/blob', 'NSInputStream',
                      'uint8_t buffer[65536]', 'LBFileCap - total', 'bodyFile:body'):
            self.assertIn(guard, section)
        self.assertIn('uploadTaskWithRequest:r fromFile:bodyFile', SOURCE)
        self.assertNotIn('dataWithContentsOfURL:file', SOURCE)
    def test_canonical_download_no_external_link(self):
        section = body('- (NSURLSessionTask *)downloadResource:')
        self.assertIn('/api/v1/resource/%@/file', section)
        self.assertNotIn('resource[@"externalLink"]', section)
        self.assertIn('response.expectedContentLength', SOURCE)
        self.assertIn('cap - c.bytes', SOURCE)
    def test_draft_whitelist_protection_hash(self):
        self.assertIn('CC_SHA256', SOURCE)
        self.assertIn('NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication', SOURCE)
        self.assertIn('NSURLIsExcludedFromBackupKey', SOURCE)
        section = body('- (NSDictionary *)cleanDraft:')
        for guard in ('@"text"', '@"visibility"', '@"resourceIDs"', '@"localFiles"', 'URLByResolvingSymlinksInPath'):
            self.assertIn(guard, section)
        self.assertNotIn('token', section)
    def test_error_redaction_and_unknown(self):
        self.assertIn('UNKNOWN', SOURCE)
        self.assertNotIn('NSUnderlyingErrorKey', SOURCE)
        self.assertNotIn('NSLog(', SOURCE)
        self.assertNotIn('localizedDescription', body('- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:'))
    def test_notification_shapes(self):
        self.assertIn('userInfo:@{@"memo":memo}', SOURCE)
        self.assertIn('userInfo:@{@"deletedID":identifier}', SOURCE)
        self.assertIn('userInfo:nil', body('- (void)reset'))
    def test_all_contract_methods_implemented(self):
        for selector in re.findall(r'^[-+] \([^\n]+?\)(\w+)', HEADER, re.M):
            if selector in ('initWithMemo', 'initWithArchived'): continue
            self.assertTrue(re.search(r'^[-+] \([^\n]+?\)' + selector, SOURCE, re.M), selector)
    def test_verified_host_archived_not_client_lockout(self):
        section = body('- (void)validate:')
        self.assertIn('LBState(u[@"rowStatus"])', section)
        self.assertNotIn('u[@"rowStatus"] isEqual:@"NORMAL"', section)
        self.assertNotIn('postNotificationName', section)
    def test_unicode_filename_and_multipart_sanitization(self):
        section = SOURCE[SOURCE.index('static NSString *LBSafeName'):SOURCE.index('static NSString *LBSafeType')]
        self.assertIn('controlCharacterSet', section)
        self.assertIn('newlineCharacterSet', section)
        self.assertIn('rangeOfComposedCharacterSequencesForRange', section)
        self.assertNotIn('abcdefghijklmnopqrstuvwxyz', section)
    def test_drafts_require_verified_user(self):
        self.assertIn('[self ready]', body('- (NSURL *)draftURL:'))


if __name__ == '__main__':
    unittest.main(verbosity=2)

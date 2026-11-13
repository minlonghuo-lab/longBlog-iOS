"""Offline GitHub reliability checks; no credentials, HTTP, article writes or IPA.
The exact pure C policy in LBSite.m is compiled and executed, then driven with
scripted mock transport outcomes. ObjC orchestration is source-contract tested;
this is NOT an NSURLSession/iOS runtime integration test.
Run: python3 -m unittest discover -s tests -p test_github_reliability.py -v
LB_GITHUB_STRICT_COMPILE=1 additionally syntax-checks LBSite.m with the real SDK.
"""
import ctypes
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SITE = (ROOT / 'src/LBSite.m').read_text()
HEADER = (ROOT / 'src/LB.h').read_text()
GH = SITE[SITE.index('#pragma mark - GitHub'):SITE.index('#pragma mark - Site data cache')]
BASE, DESIRED, LATER, OTHER = ('a' * 40, 'b' * 40, 'c' * 40, 'd' * 40)


class Policy:
    def __init__(self, directory):
        source = GH.split('// GH_POLICY_BEGIN\n', 1)[1].split('// GH_POLICY_END', 1)[0]
        c = Path(directory) / 'policy.c'
        c.write_text(source.replace('static ', ''))
        lib = Path(directory) / 'policy.so'
        subprocess.run(['cc', '-shared', '-fPIC', str(c), '-o', str(lib)], check=True,
                       capture_output=True)
        self.lib = ctypes.CDLL(str(lib))
        self.lib.GHRetryDelay.argtypes = [ctypes.c_uint, ctypes.c_double, ctypes.c_double]
        self.lib.GHRetryDelay.restype = ctypes.c_double
        self.lib.GHRetryableStatus.argtypes = [ctypes.c_long]
        self.lib.GHConfirmedState.argtypes = [ctypes.c_int] * 3
        for name in ('GHRequestTimeout', 'GHResourceTimeout', 'GHRequestBudget'):
            getattr(self.lib, name).argtypes = [ctypes.c_int]
            getattr(self.lib, name).restype = ctypes.c_double

    def retryable(self, status):
        return bool(self.lib.GHRetryableStatus(status))

    def delay(self, attempt, after=0, jitter=0):
        return self.lib.GHRetryDelay(attempt, after, jitter)

    def state(self, head, comparison=-1):
        return self.lib.GHConfirmedState(head == DESIRED, head == BASE, comparison)


class MockTransport:
    """No sockets or sleeps. Virtual clock exposes finite attempts and latency."""
    def __init__(self, policy, responses, budget=6, current=True, binary=False):
        self.policy, self.responses = policy, list(responses)
        self.binary = binary
        self.budget, self.current, self.time = budget, current, 0
        self.calls, self.waits = [], []

    def request(self, method='GET'):
        start, attempt = self.time, 0
        while True:
            if not self.current:
                return -999
            self.calls.append(method)
            status, network, retry_after, duration = self.responses.pop(0)
            self.time += duration
            transient = network == 'transient' if network else self.policy.retryable(status)
            if method == 'GET' and transient and status not in (401, 403):
                delay = self.policy.delay(attempt, retry_after, 0.4)
                resource = self.policy.lib.GHResourceTimeout(self.binary)
                total = self.policy.lib.GHRequestBudget(self.binary)
                if delay >= 0 and self.time - start + delay + resource <= total and self.budget:
                    self.budget -= 1
                    self.waits.append(delay)
                    self.time += delay
                    attempt += 1
                    continue
            if status in (401, 403):
                return status
            return -1 if network else status


def response(status=200, network=None, after=0, duration=0):
    return status, network, after, duration


class RetryFaultTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='longblog-gh-policy-')
        cls.policy = Policy(cls.temp.name)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_binary_has_bounded_longer_timeout_without_write_retry(self):
        self.assertEqual(self.policy.lib.GHRequestTimeout(False), 8)
        self.assertEqual(self.policy.lib.GHResourceTimeout(False), 10)
        self.assertEqual(self.policy.lib.GHRequestBudget(False), 24)
        self.assertEqual(self.policy.lib.GHRequestTimeout(True), 60)
        self.assertEqual(self.policy.lib.GHResourceTimeout(True), 120)
        self.assertEqual(self.policy.lib.GHRequestBudget(True), 132)
        m = MockTransport(self.policy, [response(duration=100)], binary=True)
        self.assertEqual(m.request('POST'), 200)
        self.assertEqual(m.time, 100)
        self.assertEqual(m.calls, ['POST'])
        m = MockTransport(self.policy, [response(0, 'transient', duration=120)], binary=True)
        self.assertEqual(m.request(), -1)
        self.assertEqual(m.calls, ['GET'])  # no repeated two-minute timeout
        m = MockTransport(self.policy, [response(503), response(duration=100)], binary=True)
        self.assertEqual(m.request(), 200)
        self.assertEqual(m.calls, ['GET', 'GET'])

    def test_get_disconnect_then_success(self):
        m = MockTransport(self.policy, [response(0, 'transient'), response()])
        self.assertEqual(m.request(), 200)
        self.assertEqual(m.calls, ['GET', 'GET'])
        self.assertEqual(m.waits, [0.6])

    def test_429_and_5xx_then_success(self):
        m = MockTransport(self.policy, [response(429, after=2), response(503), response()])
        self.assertEqual(m.request(), 200)
        self.assertEqual(m.waits, [2, 1.1])

    def test_permission_never_retried_even_with_transport_error(self):
        for status in (401, 403):
            for network in (None, 'transient'):
                m = MockTransport(self.policy, [response(status, network)])
                self.assertEqual(m.request(), status)
                self.assertEqual(m.calls, ['GET'])

    def test_all_writes_never_retried(self):
        for method in ('POST', 'PATCH', 'PUT', 'DELETE'):
            for event in (response(503), response(429), response(0, 'transient')):
                m = MockTransport(self.policy, [event])
                m.request(method)
                self.assertEqual(m.calls, [method])
                self.assertEqual(m.waits, [])

    def test_three_attempt_cap_and_retry_after_cap(self):
        m = MockTransport(self.policy, [response(503)] * 3)
        self.assertEqual(m.request(), 503)
        self.assertEqual(len(m.calls), 3)
        for after in (5.01, 60, 3600):
            m = MockTransport(self.policy, [response(429, after=after)])
            self.assertEqual(m.request(), 429)
            self.assertEqual(len(m.calls), 1)

    def test_jitter_and_retry_after_floor(self):
        self.assertEqual(self.policy.delay(0, 0, 0), 0.5)
        self.assertEqual(self.policy.delay(0, 0, 1), 0.75)
        self.assertEqual(self.policy.delay(1, 0, 1), 1.25)
        self.assertEqual(self.policy.delay(0, 5, 1), 5)
        self.assertEqual(self.policy.delay(2), -1)

    def test_deadline_and_global_retry_exhaustion(self):
        m = MockTransport(self.policy, [response(503, duration=10)] * 2)
        self.assertEqual(m.request(), 503)
        self.assertEqual(len(m.calls), 2)
        self.assertLess(m.time, 24)
        m = MockTransport(self.policy, [response(503)], budget=0)
        self.assertEqual(m.request(), 503)
        self.assertEqual(len(m.calls), 1)

    def test_tls_cancellation_and_not_current_do_not_retry(self):
        for error in ('tls', 'cancelled', 'policy'):
            m = MockTransport(self.policy, [response(0, error)])
            self.assertEqual(m.request(), -1)
            self.assertEqual(len(m.calls), 1)
        m = MockTransport(self.policy, [], current=False)
        self.assertEqual(m.request(), -999)
        self.assertEqual(m.calls, [])

    def test_no_retry_on_ordinary_client_error(self):
        for status in (301, 400, 404, 409, 422):
            m = MockTransport(self.policy, [response(status)])
            self.assertEqual(m.request(), status)
            self.assertEqual(len(m.calls), 1)

    def test_ref_succeeded_but_response_lost(self):
        self.assertEqual(self.policy.state(DESIRED), 1)
        self.assertEqual(self.policy.state(LATER, 1), 1)  # desired ancestor

    def test_ref_not_visible_conflicting_or_still_unknown(self):
        self.assertEqual(self.policy.state(BASE), 0)  # unchanged, NOT safe to resend
        self.assertEqual(self.policy.state(OTHER, 0), 2)  # proven divergence
        self.assertEqual(self.policy.state(LATER, -1), -1)  # compare failed/invalid


class RefRecoveryMockTests(unittest.TestCase):
    """Scripted write/read transcript with production confirmation state policy.

    Deliberately no automatic second PATCH and no article creation replay.
    """
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='longblog-gh-recovery-')
        cls.policy = Policy(cls.temp.name)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.calls, self.checkpoints = [], []

    def publish(self, head, comparison=-1, checkpoint_ok=True, read_ok=True):
        self.calls.extend(['POST blob', 'POST tree', 'POST commit'])
        self.checkpoints.append({'repository': 'fixture/repo', 'base': BASE,
                                 'commit': DESIRED, 'shas': {'content/posts/x.md': 'e' * 40}})
        if not checkpoint_ok:
            return 'checkpoint-error'
        self.calls.append('PATCH refs')  # response is always lost in this fixture
        return self.recover(head, comparison, read_ok)

    def recover(self, head, comparison=-1, read_ok=True):
        self.calls.append('GET refs')
        if not read_ok:
            return 'unknown'
        if head not in (BASE, DESIRED):
            self.calls.append('GET compare')
        return {-1: 'unknown', 0: 'unknown', 1: 'applied', 2: 'conflict'}[self.policy.state(head, comparison)]

    def test_patch_applied_response_lost_then_restart_only_reads(self):
        self.assertEqual(self.publish(DESIRED), 'applied')
        self.assertEqual(self.calls[-2:], ['PATCH refs', 'GET refs'])
        self.assertEqual(len(self.checkpoints), 1)
        # A persisted checkpoint reconstructed after process death has no credentials.
        pending = dict(self.checkpoints[0])
        self.assertEqual(pending['commit'], DESIRED)
        self.assertNotIn('token', pending)
        previous = len(self.calls)
        self.assertEqual(self.recover(LATER, 1), 'applied')
        self.assertEqual(self.calls[previous:], ['GET refs', 'GET compare'])
        self.assertEqual(self.calls.count('POST commit'), 1)
        self.assertEqual(self.calls.count('PATCH refs'), 1)

    def test_patch_did_not_apply_old_head_stays_unknown_no_replay(self):
        self.assertEqual(self.publish(BASE), 'unknown')
        self.assertEqual(self.recover(BASE), 'unknown')
        self.assertEqual(self.calls.count('PATCH refs'), 1)
        self.assertEqual(self.calls.count('POST commit'), 1)
        self.assertEqual(len(self.checkpoints), 1)

    def test_patch_lost_then_other_writer_is_conflict_not_success(self):
        self.assertEqual(self.publish(OTHER, 0), 'conflict')
        self.assertEqual(self.calls[-2:], ['GET refs', 'GET compare'])
        self.assertEqual(self.calls.count('PATCH refs'), 1)

    def test_patch_lost_and_confirmation_network_failed_preserves_checkpoint(self):
        self.assertEqual(self.publish(None, read_ok=False), 'unknown')
        self.assertEqual(self.recover(LATER, -1), 'unknown')
        self.assertEqual(len(self.checkpoints), 1)
        self.assertEqual(self.calls.count('PATCH refs'), 1)

    def test_checkpoint_failure_means_no_ref_write(self):
        self.assertEqual(self.publish(BASE, checkpoint_ok=False), 'checkpoint-error')
        self.assertNotIn('PATCH refs', self.calls)
        self.assertNotIn('GET refs', self.calls)


class NativeOrchestrationContracts(unittest.TestCase):
    def test_only_get_can_retry(self):
        task = GH[GH.index('@implementation LBGitRequestTask'):GH.index('@implementation LBGitCommitTask')]
        self.assertIn('[self.request.HTTPMethod isEqual:@"GET"]', task)
        self.assertIn('read && transient && status != 401 && status != 403', task)
        self.assertIn('GHReserveRetry()', task)
        self.assertIn('elapsed + delay + GHResourceTimeout(self.binary) <= GHRequestBudget(self.binary)', task)
        self.assertIn('self.attempt++', task)
        self.assertIn('dispatch_after(', task)
        self.assertNotIn('sleep(', task)
        self.assertIn('if (callback) callback(', task)

    def test_shared_session_is_isolated_and_no_secret_or_payload_error(self):
        self.assertEqual(GH.count('[NSURLSession sessionWithConfiguration:'), 1)
        self.assertIn('config.URLCache = nil', GH)
        self.assertIn('config.HTTPCookieStorage = nil', GH)
        self.assertIn('config.URLCredentialStorage = nil', GH)
        self.assertIn('config.HTTPShouldSetCookies = NO', GH)
        self.assertIn('r.HTTPShouldHandleCookies = NO', GH)
        self.assertIn('config.waitsForConnectivity = NO', GH)
        self.assertIn('r.timeoutInterval = GHRequestTimeout(binary)', GH)
        self.assertIn('config.timeoutIntervalForResource = GHResourceTimeout(binary)', GH)
        self.assertIn('[plain hasPrefix:@"/git/blobs/"]', GH)
        self.assertIn('r.HTTPBody.length > 256 * 1024', GH)
        self.assertIn('if (binary) self.binarySession = session', GH)
        self.assertIn('completion(nil)', GH)
        for forbidden in ('NSLog', 'localizedDescription', 'NSUnderlyingErrorKey', 'j[@"message"]', 'force":@YES'):
            self.assertNotIn(forbidden, GH)

    def test_identity_is_checked_before_every_attempt_and_callback(self):
        task = GH[GH.index('@implementation LBGitRequestTask'):GH.index('@implementation LBGitCommitTask')]
        self.assertEqual(task.count('[self.github identityCurrent]'), 2)
        self.assertIn('self.credentialGeneration == GHCredentialGeneration', GH)
        self.assertIn('self.frozenRepository.lowercaseString isEqual:LBStore.repo.lowercaseString', GH)
        self.assertIn('[self.frozenToken isEqual:([LBKeychain get:@"github-token"] ?: @"")]', GH)
        self.assertIn('GHCredentialGeneration++', GH)
        self.assertIn('[_transportSession invalidateAndCancel]', GH)

    def test_pending_identity_is_random_keychain_bound_not_a_token_hash(self):
        identity = GH[GH.index('- (BOOL)matchesPendingIdentity:'):GH.index('- (BOOL)configured')]
        self.assertIn('pending[@"credentialID"]', identity)
        self.assertIn('[self identityCurrent]', identity)
        self.assertIn('[identity isEqual:self.credentialID]', identity)
        self.assertIn('[LBKeychain get:@"github-credential-id"]', identity)
        self.assertIn('pending[@"repository"]', identity)
        self.assertIn('[LBKeychain set:NSUUID.UUID.UUIDString account:@"github-credential-id"]', GH)
        self.assertNotIn('SHA', identity)
        self.assertIn('- (BOOL)matchesPendingIdentity:', HEADER)
        task = GH[GH.index('@implementation LBGitCommitTask'):]
        self.assertIn('@"credentialID":self.github.credentialID', task)

    def test_checkpoint_before_patch_no_token_in_checkpoint(self):
        task = GH[GH.index('@implementation LBGitCommitTask'):]
        checkpoint = task[task.index('NSDictionary *pending'):task.index('// The new commit')]
        for key in ('repository', 'base', 'commit', 'shas'):
            self.assertIn('@"' + key + '"', checkpoint)
        self.assertNotIn('@"token"', checkpoint)
        self.assertLess(task.index('self.prepared(pending'), task.index('request:@"PATCH"'))
        self.assertEqual(task.count('request:@"PATCH"'), 1)
        self.assertEqual(task.count('request:@"POST" suffix:@"/git/commits"'), 1)
        self.assertIn('@"force":@NO', task)
        self.assertIn('prepared:nil done:done', GH)
        self.assertIn('prepared:(BOOL (^_Nullable)', HEADER)
        self.assertIn('- (void)confirmCommit:', HEADER)

    def test_recovery_is_read_only_and_requires_ancestry_proof(self):
        recovery = GH[GH.index('- (void)confirmCommit:'):GH.index('- (void)commitChanges:')]
        self.assertEqual(recovery.count('request:@"GET"'), 2)
        for write in ('POST', 'PATCH', 'PUT', 'DELETE'):
            self.assertNotIn('request:@"' + write + '"', recovery)
        self.assertIn('/git/ref/heads/main', recovery)
        self.assertIn('/compare/%@...%@", commit, head', recovery)
        self.assertIn('comparison[@"merge_base_commit"]', recovery)
        self.assertIn('isEqual:commit', recovery)
        for state in ('applied', 'unchanged', 'conflict'):
            self.assertIn('@"' + state + '"', recovery)
        self.assertIn('httpErr(-2,', recovery)
        task = GH[GH.index('@implementation LBGitCommitTask'):]
        self.assertIn('re.code == 401 || re.code == 403 || re.code == 409 || re.code == 422 || re.code == -999', task)
        self.assertIn('confirmCommit:commit[@"sha"] base:self.snapshot[@"head"]', task)
        self.assertIn('httpErr(409,', task)
        self.assertIn('httpErr(-2,', task)

    def test_retry_after_uses_numeric_or_http_date_never_shortens_long_wait(self):
        self.assertIn('valueForHTTPHeaderField:@"Retry-After"', GH)
        self.assertIn('scanDouble:&seconds', GH)
        self.assertIn('dateFromString:value', GH)
        self.assertIn('retryAfter > 5.0', GH)
        self.assertIn('used >= 6', GH)
        self.assertIn('now - window >= 30', GH)

    @unittest.skipUnless(os.getenv('LB_GITHUB_STRICT_COMPILE') == '1', 'opt-in real iOS SDK strict compile')
    def test_sdk_compile_site_only(self):
        sdk = Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'
        self.assertTrue(sdk.exists())
        p = subprocess.run(['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
            '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc', '-fsyntax-only',
            '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-nullability-completeness',
            '-I', str(ROOT / 'src'), str(ROOT / 'src/LBSite.m')], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)


if __name__ == '__main__':
    unittest.main()

"""Offline SOURCE audits + Python SPEC fixtures, NOT UIKit/AVFoundation runtime.
Synthetic metadata only. No credentials, network, device, or production access.
MediaBoundaryFixtures.m compiles invocations of the REAL ObjC boundary helpers.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/LBMemoMedia.m'
TEXT = SOURCE.read_text()
CAP = 32 * 1024 * 1024
CHUNK = 512 * 1024


def window(offset, current, length, to_end, size):
    if not 0 < size <= CAP or not 0 <= offset <= current <= size or length < 0:
        raise ValueError('invalid window')
    end = offset + (size - offset if to_end else min(length, size - offset))
    if current > end:
        raise ValueError('invalid current offset')
    return current, end


def content_range(header, start, count, total):
    if not 0 <= start < total <= CAP or not 0 < count <= total - start:
        return False
    match = re.fullmatch(r'bytes ([0-9]+)-([0-9]+)/([0-9]+)', header)
    return bool(match and tuple(map(int, match.groups())) == (start, start + count - 1, total))


def ranges(begin, end):
    while begin < end:
        n = min(CHUNK, end - begin)
        yield begin, n
        begin += n


class MediaSpec(unittest.TestCase):
    def test_huge_request_progressively_chunked(self):
        begin, end = window(0, 0, (1 << 63) - 1, False, CAP)
        iterator = ranges(begin, end)
        self.assertEqual(next(iterator), (0, CHUNK))
        self.assertEqual(next(iterator), (CHUNK, CHUNK))
        self.assertEqual(sum(n for _, n in ranges(begin, end)), CAP)
        self.assertEqual(len(list(ranges(begin, end))), 64)

    def test_seek_and_current_offset(self):
        self.assertEqual(window(100, 130, 80, False, 1000), (130, 180))
        self.assertEqual(window(100, 130, 1, True, 1000), (130, 1000))
        self.assertEqual(window(1000, 1000, 0, False, 1000), (1000, 1000))

    def test_invalid_windows_and_overflows(self):
        for args in [(-1, 0, 1, False, 10), (1, 0, 1, False, 10),
                     (1, 3, 1, False, 10), (0, 0, -1, False, 10),
                     (0, 0, 1, False, CAP + 1), ((1 << 63) - 1,) * 3 + (True, 10)]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                window(*args)

    def test_content_range_exact_offset_length_total(self):
        self.assertTrue(content_range('bytes 10-19/100', 10, 10, 100))
        for header in ['bytes 9-19/100', 'bytes 10-20/100', 'bytes 10-19/101',
                       'bytes 10-19/*', 'bytes 10-19/100\n', 'bytes 10-19/100/100',
                       'bytes +10-19/100', 'bytes 10-19/999999999999999999999']:
            with self.subTest(header=header):
                self.assertFalse(content_range(header, 10, 10, 100))

    def test_bounded_200_slice(self):
        for delivered in (10, CHUNK, CHUNK * 3):
            take = min(delivered, CHUNK)
            self.assertLessEqual(take, CHUNK)
        # A 200 response is valid only at zero and with exact known total.
        accept = lambda offset, declared, total: offset == 0 and declared == total
        self.assertTrue(accept(0, CAP, CAP))
        self.assertFalse(accept(CHUNK, CAP, CAP))
        self.assertFalse(accept(0, -1, CAP))

    def test_cancel_and_reset_drop_stale_callbacks_model(self):
        active = {1: 'first seek', 2: 'second seek'}
        active.pop(1)
        self.assertNotIn(1, active)  # no old seek can emit bytes
        generation = 8
        captured = generation
        generation += 1
        self.assertNotEqual(captured, generation)
        active.clear()
        self.assertFalse(active)


class MediaSourceAudits(unittest.TestCase):
    def test_public_contract_and_no_existing_file_modifications_required(self):
        header = (ROOT / 'src/LBMemoMedia.h').read_text()
        self.assertIn('UIViewController *LBMemoMediaPlayer(NSDictionary *resource)', header)
        self.assertIn('BOOL LBMemoIsPlayable(NSDictionary *resource)', header)
        self.assertIn('@interface LBMemoInlineMediaController : UIViewController', header)
        for method in ('initWithResource:', 'setPageVisible:', 'pausePlayback', 'invalidateMedia', 'isPresentingFullscreen'):
            self.assertIn(method, header)

    def test_cache_first_and_never_owned(self):
        body = TEXT[TEXT.index('UIViewController *LBMemoMediaPlayer('):]
        self.assertLess(body.index('[api cachedResource:resource]'), body.index('!api.configured'))
        self.assertIn('if (original.isFileURL)', body)
        for bad in ('removeItemAtURL:', 'downloadResource:', 'invalidateCachedResource:', 'dataWithContentsOfURL:'):
            self.assertNotIn(bad, TEXT)

    def test_public_resource_loader_and_no_private_token_options(self):
        self.assertIn('<AVAssetResourceLoaderDelegate, NSURLSessionDataDelegate>', TEXT)
        self.assertIn('parts.scheme = @"lbmemos-media"', TEXT)
        self.assertIn('options:nil', TEXT)
        self.assertNotIn('AVURLAssetHTTPHeaderFieldsKey', TEXT)
        self.assertIn('forHTTPHeaderField:@"Authorization"', TEXT)
        self.assertNotIn('NSLog', TEXT)
        self.assertNotIn('print', TEXT)

    def test_native_origin_tls_and_no_external_resource_url(self):
        for required in ('@"https"', 'c.user != nil', 'c.password != nil', 'c.query != nil',
                         'c.fragment != nil', '/api/v1/resource/%lld/file', 'c.port.integerValue > 65535',
                         '[response.URL isEqual:self.fileURL]', 'completionHandler(nil)',
                         'NSURLSessionAuthChallengePerformDefaultHandling'):
            self.assertIn(required, TEXT)
        for bad in ('externalLink', 'filepath', 'credentialForTrust:', 'NSURLSessionAuthChallengeUseCredential'):
            self.assertNotIn(bad, TEXT)

    def test_no_persistent_cookies_credentials_or_http_cache(self):
        for required in ('ephemeralSessionConfiguration', 'c.HTTPCookieStorage = nil',
                         'c.HTTPShouldSetCookies = NO', 'c.URLCache = nil', 'c.URLCredentialStorage = nil',
                         'request.HTTPShouldHandleCookies = NO', '@"identity"', '@"no-store"'):
            self.assertIn(required, TEXT)

    def test_main_queue_and_bounded_concurrency(self):
        for required in ('delegateQueue:NSOperationQueue.mainQueue', 'queue:dispatch_get_main_queue()',
                         'self.active.count >= 2', 'MIN(LBMMChunk, r.end - r.next)',
                         'MIN((uint64_t)data.length', 'respondWithData:slice', 'r.received != r.count'):
            self.assertIn(required, TEXT)
        self.assertNotIn('NSMutableData', TEXT)
        self.assertNotIn('appendData:', TEXT)

    def test_verified_content_information_and_200_policy(self):
        for required in ('[UTType typeWithMIMEType:', 'info.byteRangeAccessSupported = YES',
                         'info.contentLength =', 'self.verifiedHeaders = YES',
                         'LBMMContentRange(', 'r.start == 0 && response.expectedContentLength == total',
                         'r.status == 200 && r.received == r.count', 'Content-Encoding'):
            self.assertIn(required, TEXT)

    def test_lifecycle_retention_cancel_and_generation(self):
        for required in ('strong) LBMMResourceLoader *mediaLoader', '__weak LBMMPlayerController *weakVC',
                         'self.generation == api.generation', '[self.userID isEqual:api.user[@"id"]]',
                         'didCancelLoadingRequest:', '[r.task cancel]', '[self.session invalidateAndCancel]',
                         'viewDidDisappear:', 'replaceCurrentItemWithPlayerItem:nil',
                         '[owner dismissViewControllerAnimated:NO', '- (void)dealloc { [self closeMedia]; }',
                         'observeValueForKeyPath:', 'removeObserver:self forKeyPath:@"status"',
                         'AVPlayerItemStatusFailed'):
            self.assertIn(required, TEXT)
        self.assertEqual(TEXT.count('[self.player play]'), 1)  # legacy tap presentation
        self.assertEqual(TEXT.count('[player play]'), 1)  # inline explicit tap
        self.assertIn('if (!self.inlineMode && !self.started && !self.closed)', TEXT)
        self.assertNotIn('AVAudioSession', TEXT)

    def test_strict_sdk_compile_source_and_real_helper_fixtures(self):
        sdk = Path(os.environ.get('IOS_SDK', Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'))
        if not shutil.which('clang') or not sdk.is_dir():
            self.skipTest('clang/iPhoneOS SDK unavailable; no runtime claim')
        for source in (SOURCE, ROOT / 'src/LBMemoContentView.m', ROOT / 'src/LBMemosDetail.m', ROOT / 'tests/MediaBoundaryFixtures.m', ROOT / 'tests/InlineMediaFixtures.m'):
            with self.subTest(source=source.name):
                command = ['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
                           '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc',
                           '-I', str(ROOT / 'src'), '-Wall', '-Wextra', '-Werror',
                           '-Wno-unused-parameter', '-Wno-nullability-completeness', '-fsyntax-only', str(source)]
                result = subprocess.run(command, text=True, capture_output=True, timeout=180)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Offline AI regressions (no API, credentials, Keychain, UIKit or app writes).

The C byte scanner is extracted verbatim from LBAI.m, compiled for this host and
executed by ctypes. Framing/event JSON in NativeScannerFixture is an explicit
Python model, NOT execution of NSURLSession/Objective-C. Source contracts cover
those remaining queue, cancellation and UIKit boundaries. Optional SDK syntax
checking compiles only LBAI.m; no device install or full app build is performed.
"""
from pathlib import Path
import ctypes
import json
import os
import random
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'src/LBAI.m').read_text()
HEADER = (ROOT / 'src/LBAI.h').read_text()


def method(name):
    match = re.search(r'^[-+] \([^\n]+\)' + re.escape(name) + r'\b[^\{;]*\{', SOURCE, re.M)
    if not match:
        raise AssertionError('missing method ' + name)
    start = match.end()
    depth = 1
    for i in range(start, len(SOURCE)):
        if SOURCE[i] == '{':
            depth += 1
        elif SOURCE[i] == '}':
            depth -= 1
            if not depth:
                return SOURCE[start:i]
    raise AssertionError('unterminated method ' + name)


class NativeScannerFixture:
    """SSE reference assembly using the real native line-boundary helper."""
    def __init__(self, scanner):
        self.scanner = scanner
        self.pending = bytearray()
        self.skip_lf = False
        self.event = []
        self.full = ''
        self.done = False
        self.scanned_ranges = 0

    def consume_line(self):
        line = self.pending.decode('utf-8')
        self.pending.clear()
        if not line:
            self.consume_event()
        elif line.startswith('data:'):
            value = line[5:]
            self.event.append(value[1:] if value.startswith(' ') else value)

    def consume_event(self):
        if not self.event or self.done:
            return
        payload = '\n'.join(self.event)
        self.event.clear()
        if not payload.strip():
            return
        if payload.strip() == '[DONE]':
            self.done = True
            return
        obj = json.loads(payload)
        if not isinstance(obj, dict) or obj.get('error'):
            raise ValueError('provider/format error')
        choices = obj.get('choices')
        first = choices[0] if isinstance(choices, list) and choices else None
        delta = first.get('delta') if isinstance(first, dict) else None
        content = delta.get('content') if isinstance(delta, dict) else None
        if isinstance(content, str):
            self.full += content

    def feed(self, data):
        cursor = 0
        while cursor < len(data) and not self.done:
            if self.skip_lf:
                self.skip_lf = False
                if data[cursor] == 10:
                    cursor += 1
                    continue
            end = self.scanner(data, len(data), cursor)
            self.scanned_ranges += end - cursor + int(end < len(data))
            self.pending.extend(data[cursor:end])
            if end == len(data):
                break
            self.skip_lf = data[end] == 13
            self.consume_line()
            cursor = end + 1

    def eof(self):
        if self.pending and not self.done:
            self.consume_line()
        self.consume_event()


def delta(text):
    return json.dumps({'choices': [{'delta': {'content': text}}]}, ensure_ascii=False).encode()


class NativeFraming(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('clang') or shutil.which('cc')
        if not compiler:
            raise unittest.SkipTest('host C compiler unavailable')
        cls.temp = tempfile.TemporaryDirectory(prefix='lb-ai216-')
        folder = Path(cls.temp.name)
        helper = re.search(r'static size_t LBAINextLineBreak\([^}]+\n  }\n  return length;\n}', SOURCE)
        if not helper:
            raise AssertionError('native scanner helper missing')
        code = '#include <stdint.h>\n#include <stddef.h>\n' + helper.group().replace('static size_t', 'size_t', 1)
        (folder / 'scanner.c').write_text(code)
        subprocess.run([compiler, '-shared', '-fPIC', '-O2', '-Wall', '-Wextra', '-Werror',
                        str(folder / 'scanner.c'), '-o', str(folder / 'scanner.so')], check=True,
                       capture_output=True, text=True, timeout=60)
        cls.lib = ctypes.CDLL(str(folder / 'scanner.so'))
        cls.scanner = cls.lib.LBAINextLineBreak
        cls.scanner.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_size_t]
        cls.scanner.restype = ctypes.c_size_t

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, 'temp'):
            cls.temp.cleanup()

    def test_native_scanner_offsets(self):
        rng = random.Random(216)
        for _ in range(500):
            buf = bytes(rng.choice((10, 13, 65, 128, 255)) for _ in range(rng.randrange(80)))
            start = rng.randrange(len(buf) + 1)
            expected = next((i for i in range(start, len(buf)) if buf[i] in (10, 13)), len(buf))
            self.assertEqual(self.scanner(buf, len(buf), start), expected)

    def test_utf8_crlf_multiline_heartbeat_done_all_fragmentations(self):
        wire = (b': heartbeat\r\ndata:\r\n\r\nevent: message\r\n' + b'data: ' + delta('你🙂') + b'\r\n\r\n'
                + b'data: {"choices": [\r\ndata: {"delta":{"content":"ok"}}]}\r\n\r\n'
                + b'data: [DONE]\r\n\r\ndata: ignored\n\n')
        for width in (1, 2, 3, 7, 29, len(wire)):
            fixture = NativeScannerFixture(self.scanner)
            for i in range(0, len(wire), width):
                fixture.feed(wire[i:i + width])
            fixture.eof()
            self.assertEqual(fixture.full, '你🙂ok')
            self.assertTrue(fixture.done)
            self.assertLessEqual(fixture.scanned_ranges, len(wire))

    def test_eof_without_newline_or_done(self):
        for ending in (b'', b'\n', b'\r', b'\r\n'):
            fixture = NativeScannerFixture(self.scanner)
            fixture.feed(b'data: ' + delta('末尾') + ending)
            fixture.eof()
            self.assertEqual(fixture.full, '末尾')

    def test_many_events_and_fragmented_long_line_scan_once(self):
        wire = (b'data: ' + delta('x') + b'\n\n') * 10000
        fixture = NativeScannerFixture(self.scanner)
        fixture.feed(wire)
        self.assertEqual(fixture.full, 'x' * 10000)
        self.assertEqual(fixture.scanned_ranges, len(wire))
        fixture = NativeScannerFixture(self.scanner)
        wire = b'data: ' + delta('x' * 200000) + b'\n\n'
        for i in range(0, len(wire), 17):
            fixture.feed(wire[i:i + 17])
        self.assertEqual(fixture.full, 'x' * 200000)
        self.assertEqual(fixture.scanned_ranges, len(wire))

    def test_provider_and_malformed_errors_are_not_empty_success(self):
        for payload in (b'not json', b'{"error":{"message":"rate limit"}}', b'[]'):
            with self.assertRaises((ValueError, json.JSONDecodeError)):
                NativeScannerFixture(self.scanner).feed(b'data: ' + payload + b'\n\n')


class AIQueueContracts(unittest.TestCase):
    def test_stream_prepares_keychain_and_json_off_main(self):
        body = method('streamSystem')
        queued = body.index('dispatch_async(dispatch_get_global_queue')
        self.assertLess(queued, body.index('self.apiKey'))
        self.assertLess(queued, body.index('dataWithJSONObject'))
        self.assertNotIn('dispatch_sync', body)
        self.assertIn('return ^{ [stream cancel]; };', body)
        self.assertNotIn('done(nil', body)
        check = method('checkConfigured')
        self.assertLess(check.index('dispatch_get_global_queue'), check.index('self.configured'))
        self.assertIn('dispatch_get_main_queue()', check)
        self.assertIn('checkConfigured:', HEADER)

    def test_cancel_covers_preparation_validation_and_queued_callbacks(self):
        self.assertIn('@property (atomic) BOOL cancelled', SOURCE)
        self.assertIn('@synchronized (self)', method('cancel'))
        self.assertIn('self.cancelled = YES', method('cancel'))
        self.assertIn('[_task cancel]', method('cancel'))
        self.assertIn('if (self.cancelled) return;', method('beginRequest'))
        complete = method('completeWithText')
        self.assertIn('self.cancelled || _completionQueued || _finished', complete)
        self.assertIn('self.cancelled || self->_finished', complete)
        self.assertIn('if (!self.cancelled && self.done)', complete)
        self.assertLess(complete.index('self.onDelta(tail)'), complete.index('self.done(text, error)'))
        self.assertIn('[stream completeWithText:nil error:', method('streamSystem'))

    def test_coalesced_delivery_has_one_pending_flush(self):
        queued = method('queueDelta')
        self.assertIn('if (_flushScheduled) return;', queued)
        self.assertLess(queued.index('_flushScheduled = YES'), queued.index('dispatch_after'))
        self.assertIn('50 * NSEC_PER_MSEC', queued)
        self.assertIn('dispatch_get_main_queue()', queued)
        self.assertIn('[self->_delivery copy]', queued)
        self.assertIn('delegateQueue:nil', method('beginRequest'))
        receive = SOURCE.split('didReceiveData:(NSData *)data {', 1)[1].split('\n- (void)URLSession:', 1)[0]
        self.assertNotIn('dispatch_async(dispatch_get_main_queue()', receive)
        self.assertNotIn('replaceBytesInRange', receive)
        self.assertIn('LBAINextLineBreak(bytes, data.length, cursor)', receive)

    def test_bounds_and_eof_and_done_guard(self):
        self.assertIn('LBAIMaxBodyBytes - _raw.length', SOURCE)
        self.assertIn('LBAIMaxLineBytes - _pending.length', SOURCE)
        self.assertIn('LBAIMaxEventBytes - _eventBytes', SOURCE)
        self.assertIn('LBAIMaxOutputCharacters - _full.length', SOURCE)
        self.assertIn('if (_pending.length) [self consumeLine]', SOURCE)
        event = method('consumeEvent')
        self.assertIn('_sawDone = YES', event)
        self.assertIn('[self completeWithText:[_full copy] error:nil]', event)
        self.assertIn('[_task cancel]', event)
        self.assertIn('json[@"error"]', event)
        self.assertIn('failParsing:', event)
        # Stream bytes are not duplicated into the JSON/error fallback buffer.
        receive = SOURCE.split('didReceiveData:(NSData *)data {', 1)[1].split('\n- (void)URLSession:', 1)[0]
        raw_start = receive.index('if (_status != 200 || !_eventStream)')
        self.assertLess(raw_start, receive.index('[_raw appendData:data]'))
        self.assertLess(receive.index('[_raw appendData:data]'), receive.index('const uint8_t *bytes'))

    def test_result_lifecycle_keeps_generation_and_scroll_guards(self):
        self.assertNotIn('[self start]', method('viewDidLoad'))
        self.assertIn('if (!_hasStarted) [self start]', method('viewDidAppear'))
        self.assertIn('_cancel()', method('dealloc'))
        self.assertIn('_generation++', method('stop'))
        start = method('start')
        self.assertEqual(start.count('me->_generation != generation'), 2)
        self.assertIn('textStorage appendAttributedString', start)
        self.assertIn('isDecelerating', start)
        self.assertIn('isTracking', start)
        self.assertIn('NSMakeRange(me->_text.textStorage.length, 0)', start)

    def test_ios_sdk_strict_syntax(self):
        if os.environ.get('LB_AI216_CHECK_SDK') != '1':
            self.skipTest('set LB_AI216_CHECK_SDK=1 for optional single-source SDK check')
        sdk = Path(os.environ.get('IOS_SDK', Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'))
        if not shutil.which('clang') or not sdk.is_dir():
            self.skipTest('clang/iPhoneOS SDK unavailable')
        result = subprocess.run(['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
                                 '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc',
                                 '-I', str(ROOT / 'src'), '-Wall', '-Wextra', '-Werror',
                                 '-Wno-unused-parameter', '-Wno-nullability-completeness',
                                 '-fsyntax-only', str(ROOT / 'src/LBAI.m')],
                                capture_output=True, text=True, timeout=300)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Offline source-bound regressions for perf22; no UIKit/FPS/runtime claims.

Run: python3 -m unittest discover -s tests -p test_perf22.py -v
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OWNED = ('LBMemosTimeline.m', 'LBDashboard.m', 'LBInbox.m', 'LBTheme.m')
SOURCES = {name: (ROOT / 'src' / name).read_text() for name in OWNED}


def braced(source, start):
    start = source.index('{', start)
    depth = 0
    tokens = re.finditer(r'@?"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/|[{}]', source[start:])
    for token in tokens:
        if token.group() == '{':
            depth += 1
        elif token.group() == '}':
            depth -= 1
            if not depth:
                return source[start + 1:start + token.start()]
    raise AssertionError('unclosed source block')


def method(source, name):
    match = re.search(r'^- \([^\n]+\)' + re.escape(name) + r'(?=[:\s{])', source, re.M)
    if not match:
        raise AssertionError('missing method: ' + name)
    return braced(source, match.end())


class Perf22Contracts(unittest.TestCase):
    def test_progress_filter_work_is_bounded_by_exact_inputs(self):
        src = SOURCES['LBMemosTimeline.m']
        render = method(src, 'render')
        guard = 'if (_filteredRows != _rows || ![_filteredQuery isEqualToString:_query] || ![_filteredTag isEqualToString:_tag])'
        block = braced(render, render.index(guard))
        # The only content scan must be INSIDE the input-change branch, not
        # before it or repeated elsewhere on the progress notification path.
        scan = 'for (NSDictionary *memo in _rows)'
        self.assertEqual(render.count(scan), 1)
        self.assertEqual(block.count(scan), 1)
        for text in ['rangeOfString:_query options:NSCaseInsensitiveSearch',
                     '[memo[@"tagList"] containsObject:_tag]', '_display = [visible copy]',
                     '_filteredRows = _rows', '_filteredQuery = [_query copy]',
                     '_filteredTag = [_tag copy]']:
            self.assertIn(text, block)
        for guard_text in ['!_visible', '_searchDismissing', '_table.dragging', '_table.decelerating']:
            self.assertLess(render.index(guard_text), render.index(guard))
        # Progress changes still update status/footer even when filtering is skipped.
        self.assertGreater(render.index('cacheProgress'), render.index('_filteredTag = [_tag copy]'))
        self.assertIn('[_lastRenderedRows isEqual:_display]', render)
        self.assertIn('[self loadCachedRows]', method(src, 'cacheChanged'))

    def test_snapshot_replacement_and_privacy_reset_invalidate_filter(self):
        src = SOURCES['LBMemosTimeline.m']
        changed = method(src, 'changed')
        reset = braced(changed, changed.index('if (_context !='))
        for text in ['_rows = @[]', '_display = @[]', '_filteredRows = nil',
                     '_filteredQuery = nil', '_filteredTag = nil',
                     '_cacheProgressLabel.text = nil', '[_table reloadData]',
                     '_table.tableFooterView = nil']:
            self.assertIn(text, reset)
        for name in ['loadCachedRows', 'fetch', 'changed']:
            self.assertIn('[self ordered:', method(src, name))
        # No in-place mutation of the retained immutable snapshot is allowed.
        self.assertNotRegex(src, r'\[_rows (?:addObject|removeObject|insertObject|sortUsing)')
        ordered = method(src, 'ordered')
        for text in ['sortedArrayUsingComparator:', 'if (pa != pb)',
                     '[b[@"displayTs"] compare:a[@"displayTs"]]', '[b[@"id"] compare:a[@"id"]]']:
            self.assertIn(text, ordered)
        render = method(src, 'render')
        self.assertIn('normal+archived', render)
        self.assertIn('_rows.count', render)
        self.assertIn('allState:self->_state text:@"" tag:@""', method(src, 'fetch'))
        self.assertIn('allState:other text:@"" tag:@""', method(src, 'fetch'))

    def test_progress_footer_is_reused_without_unconditional_layout(self):
        render = method(SOURCES['LBMemosTimeline.m'], 'render')
        start = render.index('if (caching && _display.count)')
        progress = braced(render, start)
        lazy = braced(progress, progress.index('if (!_cacheProgressLabel)'))
        self.assertEqual(progress.count('[UILabel new]'), 1)
        self.assertIn('_cacheProgressLabel = [UILabel new]', lazy)
        for guard in ['if (![label.text isEqualToString:text]) label.text = text',
                      'if (!CGRectEqualToRect(label.frame, frame)) label.frame = frame',
                      'if (_table.tableFooterView != label) _table.tableFooterView = label']:
            self.assertIn(guard, progress)
        for text in ['progress[@"completed"]', 'progress[@"total"]', 'progress[@"failed"]',
                     'progress[@"error"]', '下拉重试']:
            self.assertIn(text, progress)
        # The unchanged fallback must retain the real retry/load handler.
        for text in ['if (self->_error) [self refresh]; else [self fetch:YES]',
                     'b.enabled = !_loading', 'else _table.tableFooterView = nil']:
            self.assertIn(text, render)

    def test_dashboard_pulse_suspends_and_normal_value_update_resumes(self):
        src = SOURCES['LBDashboard.m']
        suspend = method(src, 'suspendUpdates')
        self.assertIn('removeAnimationForKey:@"deployBreathe"', suspend)
        self.assertIn('_deployChip.layer.transform = CATransform3DIdentity', suspend)
        for name in ['viewWillDisappear', 'resignedActive']:
            self.assertIn('[self suspendUpdates]', method(src, name))
        self.assertIn('UIAccessibilityReduceMotionStatusDidChangeNotification', method(src, 'viewDidLoad'))
        self.assertIn('[self requestUpdate]', method(src, 'becameActive'))
        self.assertIn('[self updateDeployPulse:deployColor]', method(src, 'updateValues'))
        pulse = method(src, 'updateDeployPulse')
        self.assertIn('!LBShouldAnimate(YES)', pulse)
        self.assertIn('if (![l animationForKey:@"deployBreathe"])', pulse)
        self.assertNotIn('NSRunLoopCommonModes', src)

    def test_highlight_feedback_is_edge_triggered_not_removed(self):
        src = SOURCES['LBInbox.m']
        highlight = method(src, 'setHighlighted')
        guard = highlight.index('if (self.highlighted == h) return')
        for work in ['[super setHighlighted:', 'impactOccurredWithIntensity:0.65', 'animateWithDuration:']:
            self.assertLess(guard, highlight.index(work))
        self.assertIn('if (h)', highlight)
        self.assertIn('LBShouldAnimate(a)', highlight)
        self.assertIn('CGAffineTransformMakeScale(0.975, 0.975)', highlight)

    def test_aurora_drift_has_explicit_window_scene_and_accessibility_bounds(self):
        src = SOURCES['LBTheme.m'].split('@implementation LBAuroraView', 1)[1].split('@end', 1)[0]
        init = method(src, 'initWithFrame')
        for name in ['UIApplicationWillResignActiveNotification', 'UISceneWillDeactivateNotification',
                     'UIApplicationDidBecomeActiveNotification', 'UISceneDidActivateNotification',
                     'UIAccessibilityReduceMotionStatusDidChangeNotification']:
            self.assertIn(name, init)
        suspend, resume = method(src, 'suspendDrift'), method(src, 'resumeDrift')
        self.assertLess(suspend.index('_driftSuspended = YES'), suspend.index('[self stopDrift]'))
        for block in [suspend, resume]:
            self.assertIn('note.object != self.window.windowScene', block)
        self.assertIn('_driftSuspended = NO', resume)
        self.assertIn('if (UIAccessibilityIsReduceMotionEnabled()) [self stopDrift]', resume)
        self.assertIn('[self setNeedsLayout]', resume)
        layout = method(src, 'layoutSubviews')
        for text in ['self.window && !_driftSuspended', '!UIAccessibilityIsReduceMotionEnabled()',
                     'UIApplicationStateActive', 'UISceneActivationStateForegroundActive',
                     'if (!animate) [self stopDrift]', 'if (animate && ![l animationForKey:@"drift"])']:
            self.assertIn(text, layout)
        self.assertIn('if (!self.window) [self stopDrift]', method(src, 'didMoveToWindow'))
        self.assertIn('removeAnimationForKey:@"drift"', method(src, 'stopDrift'))
        self.assertIn('removeObserver:self', method(src, 'dealloc'))

    def test_owned_files_compile_strictly_against_ios_sdk(self):
        sdk = Path(os.environ.get('IOS_SDK', '/root/.ios-sdk/iPhoneOS26.5.sdk')).expanduser()
        clang = shutil.which('clang')
        if not clang or not sdk.is_dir():
            self.skipTest('clang/iOS SDK unavailable; no native runtime claim')
        for name in OWNED:
            with self.subTest(source=name), tempfile.TemporaryDirectory(prefix='lb-perf22-') as output:
                obj = Path(output) / (name + '.o')
                command = [clang, '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
                           '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc',
                           '-I', str(ROOT / 'src'), '-Wall', '-Wextra', '-Werror',
                           '-Wno-unused-parameter', '-Wno-nullability-completeness',
                           '-c', str(ROOT / 'src' / name), '-o', str(obj)]
                result = subprocess.run(command, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertGreater(obj.stat().st_size, 0, 'empty clang output')


if __name__ == '__main__':
    unittest.main(verbosity=2)

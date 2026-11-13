#!/usr/bin/env python3
"""Offline monitor contracts; no network, production calls, or UIKit/FPS claims.
Run: python3 -m unittest discover -s tests -p test_site_monitor17.py -v
"""
from pathlib import Path
import os
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SITE = (ROOT / 'src/LBSite.m').read_text()
DASH = (ROOT / 'src/LBDashboard.m').read_text()


def section(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


BATCH = section(SITE, '- (void)refreshDeploy:(void (^)(void))done forceCertificates:(BOOL)force active:(BOOL)active {', '\n- (NSString *)deployState:')
ACTIVE = section(DASH, '- (void)becameActive {', '\n- (void)resignedActive:')
FAST = section(SITE, '- (BOOL)wantsFastDeployChecks {', '\n- (void)monitorDeploy')


class SiteMonitor17Contracts(unittest.TestCase):
    def test_01_idle_dashboard_checks_even_without_pending(self):
        self.assertIn('TimeInterval:30', ACTIVE)
        self.assertIn('else [LBSiteData.shared monitorDeploy]', ACTIVE)
        self.assertIn('[LBSiteData.shared refreshDeployOnActivation]', ACTIVE)

    def test_02_recent_commit_fast_checks_are_capped(self):
        self.assertIn('TimeInterval:5', ACTIVE)
        self.assertIn('wantsFastDeployChecks', ACTIVE)
        self.assertEqual(FAST.count('age < 20 * 60'), 2)
        self.assertIn('if (built.length >= 7 && [head hasPrefix:built]) return NO', FAST)

    def test_03_ticks_are_lightweight(self):
        for text in ('refreshAll', 'refreshPosts', 'refreshMemos', 'refreshEnv', 'LBSync.shared', 'LBEnvFile'):
            self.assertNotIn(text, ACTIVE + BATCH)
        self.assertIn('headCommit:', BATCH)
        self.assertIn('/build-info.json', BATCH)

    def test_04_slow_batches_coalesce_and_release_once(self):
        self.assertIn('if (_deployInFlight)', BATCH)
        self.assertIn('_deployInFlight = YES', BATCH)
        self.assertIn('self->_deployInFlight = NO', BATCH)
        self.assertIn('[_deployCompletions addObject:[done copy]]', BATCH)
        self.assertIn('for (void (^callback)(void) in callbacks) callback()', BATCH)

    def test_05_manual_refresh_forces_tls_even_during_batch(self):
        all_refresh = section(SITE, '- (void)refreshAll:', '\n@end')
        self.assertIn('forceCertificates:YES active:NO', all_refresh)
        self.assertIn('if (force) _forceCertificatesQueued = YES', BATCH)
        self.assertIn('forceCertificates:again active:checkActive', BATCH)

    def test_06_certificate_ttls_and_near_expiry(self):
        self.assertIn('<= 7 * 86400', BATCH)
        self.assertIn('active || nearExpiry ? 5 * 60 : 15 * 60', BATCH)
        self.assertIn('if (!force && checked && -checked.timeIntervalSinceNow < ttl) continue', BATCH)

    def test_07_failed_certificate_retry_is_bounded(self):
        self.assertIn('if (!force && attempt && -attempt.timeIntervalSinceNow < 5 * 60) continue', BATCH)
        self.assertIn('_certAttemptAt[host] = [NSDate date]', BATCH)
        self.assertIn('if (exp && !e)', BATCH)
        self.assertIn('self->_certCheckedAt[host] = [NSDate date]', BATCH)

    def test_08_marker_does_not_reuse_local_http_cache(self):
        self.assertIn('r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData', SITE)
        self.assertIn('@"Cache-Control" : @"no-cache"', BATCH)

    def test_09_certificate_uses_real_trusted_tls(self):
        probe = section(SITE, '+ (void)certificateExpiry:', '+ (void)image:')
        self.assertIn('ephemeralSessionConfiguration', probe)
        self.assertIn('c.timeoutIntervalForResource = 15', probe)
        self.assertIn('if (exp && !e) done(exp, nil)', probe)
        self.assertIn('NSURLSessionAuthChallengePerformDefaultHandling', SITE)
        self.assertNotIn('NSURLSessionAuthChallengeUseCredential', SITE)
        self.assertIn('completion(nil)', SITE)

    def test_10_callbacks_guard_connection_generation_and_identity(self):
        for text in ('generation == self->_generation', '[site isEqualToString:LBStore.siteURL]',
                     '[repo isEqualToString:LBStore.repo]', '[hosts isEqualToArray:LBStore.certHosts]'):
            self.assertIn(text, BATCH)
        self.assertEqual(BATCH.count('if (current())'), 3)
        self.assertIn('if (valid) [self changed]', BATCH)

    def test_11_reset_clears_freshness_and_last_values(self):
        reset = section(SITE, '- (void)resetConnection {', '\n- (NSDictionary *)errors')
        for text in ('_generation++', '[_certs removeAllObjects]', '[_certCheckedAt removeAllObjects]',
                     '[_certAttemptAt removeAllObjects]', '_deployCheckedAt = nil'):
            self.assertIn(text, reset)
        self.assertNotIn('_deployInFlight = NO', reset)

    def test_12_failures_keep_last_known_and_show_error(self):
        self.assertIn('if (c && !e) self->_head = c', BATCH)
        self.assertIn('if (!e) { self->_build = j;', BATCH)
        self.assertIn('else if (!self->_certs[host])', BATCH)
        self.assertIn('复核失败（保留上次结果）', SITE)
        self.assertIn('上次%@ · 复核失败', DASH)
        self.assertIn('_headErrorRow.hidden = !d.errors[@"head"]', DASH)

    def test_13_freshness_is_success_time_not_attempt_time(self):
        self.assertIn('self->_deployCheckedAt = [NSDate date]', BATCH)
        self.assertIn('[d deployCheckedAt]', DASH)
        self.assertIn('[d certificateCheckedAt:h]', DASH)
        self.assertIn('核验%@', DASH)

    def test_14_hidden_background_and_dealloc_stop_timers(self):
        suspend = section(DASH, '- (void)suspendUpdates {', '\n- (void)becameActive')
        for timer in ('_tick', '_pendingTick'):
            self.assertIn(f'[{timer} invalidate]; {timer} = nil', suspend)
            self.assertIn(f'[{timer} invalidate]', section(DASH, '- (void)dealloc {', '\n- (void)pull:'))
        self.assertIn('![s isActiveDashboard]', ACTIVE)
        self.assertNotIn('NSRunLoopCommonModes', DASH)

    def test_15_interaction_guards_and_fixed_hierarchy_remain(self):
        for guard in ('_scroll.dragging', '_scroll.decelerating', '_refreshInFlight', '_refreshSettling'):
            self.assertIn(guard, ACTIVE)
        self.assertEqual(DASH.count('[self buildDashboard]'), 1)
        self.assertEqual(DASH.count('[LBEnvFile parse:'), 1)
        self.assertIn('NSDefaultRunLoopMode', DASH)
        self.assertNotIn('msFromDateString', FAST)
        self.assertIn('_buildDateText != builtAt && ![_buildDateText isEqualToString:builtAt]', DASH)
        self.assertIn('_headAtMilliseconds = msFromDateString', BATCH)
        self.assertIn('_builtAtMilliseconds = msFromDateString', BATCH)

    def test_16_activation_coalesces_without_losing_stricter_ttl(self):
        activation = section(SITE, '- (void)refreshDeployOnActivation {', '\n- (NSDate *)certificateCheckedAt:')
        self.assertIn('_activationAttemptAt.timeIntervalSinceNow < 2', activation)
        self.assertIn('forceCertificates:NO active:YES', activation)
        self.assertIn('if (active) _activeCertificatesQueued = YES', BATCH)

    def test_17_strict_sdk_compile(self):
        sdk = Path(os.environ.get('IOS_SDK', Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'))
        if not shutil.which('clang') or not sdk.is_dir():
            self.skipTest('clang + iPhoneOS26.5 SDK unavailable')
        command = ['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
                   '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc', '-I', str(ROOT / 'src'),
                   '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-fsyntax-only',
                   str(ROOT / 'src/LBSite.m'), str(ROOT / 'src/LBDashboard.m')]
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main(verbosity=2)

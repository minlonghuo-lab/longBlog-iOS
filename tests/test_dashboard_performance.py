#!/usr/bin/env python3
"""Offline dashboard source contracts, not UIKit/device timing or FPS evidence.

Run: python3 -m unittest discover -s tests -p test_dashboard_performance.py -v
These deliberately separate one-time construction, value-only updates, and the
host-configuration-only reconciliation exception. No API/network is exercised.
"""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'src' / 'LBDashboard.m').read_text()


def method(name, source=SOURCE):
    """Extract one Objective-C method without confusing inner block braces."""
    pattern = r'^- \([^\n]+\)' + re.escape(name) + r'(?=[:\s{])'
    match = re.search(pattern, source, re.M)
    if not match:
        raise AssertionError(f'missing method: {name}')
    start = source.index('{', match.end())
    # Ignore string/comment braces so assertions can contain readable comments.
    tokens = re.finditer(r'@?"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/|[{}]', source[start:])
    depth = 0
    for token in tokens:
        if token.group() == '{':
            depth += 1
        elif token.group() == '}':
            depth -= 1
            if depth == 0:
                return source[start + 1:start + token.start()]
    raise AssertionError(f'unclosed method: {name}')


class DashboardPerformanceContracts(unittest.TestCase):
    def test_notification_callbacks_invalidate_instead_of_building(self):
        load = method('viewDidLoad')
        self.assertIn('@[ LBSiteDataDidChange, LBSyncDidChange ]', load)
        self.assertIn('selector:@selector(requestUpdate)', load)
        self.assertEqual(SOURCE.count('[self buildDashboard]'), 1)
        self.assertIn('[self buildDashboard]', load)
        self.assertNotIn('@selector(render)', SOURCE)
        request = method('requestUpdate')
        for text in ['NSThread.isMainThread', 'dispatch_get_main_queue()',
                     '_needsUpdate = YES', '[self scheduleUpdate]']:
            self.assertIn(text, request)
        for forbidden in ['updateValues', 'buildDashboard', 'addArrangedSubview']:
            self.assertNotIn(forbidden, request)

    def test_value_updates_do_not_rebuild_hierarchy(self):
        values = method('updateValues')
        # Catches the original tear-down and accidental new section/card/label
        # creation even when the developer also introduces a one-time builder.
        for forbidden in ['removeFromSuperview', 'addArrangedSubview:',
                          'initWithArrangedSubviews:', 'activateConstraints:',
                          '[self card:', '[self stat:', '[self line:',
                          '[self label:', '[self sectionTitle:', 'LBNotice(',
                          '[UIStackView new]', '[UILabel new]', 'glassWithTint:']:
            self.assertNotIn(forbidden, values)
        self.assertIn('[self reconcileCertificateHosts]', values)
        self.assertNotIn('for (UIView *v in _stack.arrangedSubviews)', SOURCE)
        # All additions to the root stack belong to construction, not updates.
        self.assertEqual(SOURCE.count('[_stack addArrangedSubview:'),
                         method('buildDashboard').count('[_stack addArrangedSubview:'))

    def test_existing_labels_stats_and_optional_rows_are_reused(self):
        values = method('updateValues')
        for field in ['_prompt', '_name', '_subtitle', '_deployChip', '_commitMessage']:
            self.assertIn('label:' + field, values)
        for index in range(4):
            self.assertIn(f'[self updateStat:{index} ', values)
        for field in ['_commitRow', '_commitMessage', '_headErrorRow', '_heartbeatRow', '_setupNotice']:
            self.assertIn(field + '.hidden =', values)
        self.assertIn('if (![label.text isEqualToString:text])', method('setText'))
        line = method('updateLine')
        self.assertIn('objc_getAssociatedObject(iv, "symbol")', line)
        self.assertIn('if (![iv.tintColor isEqual:color])', line)
        # The only glass effect change is the inbox's unread-color transition.
        guard = values.index('if (![_statIcons[2].tintColor isEqual:inboxColor])')
        self.assertGreater(values.index('_statCards[2].effect = effect'), guard)
        self.assertEqual(values.count('effectWithStyle:'), 1)

    def test_certificate_hierarchy_changes_only_for_host_configuration(self):
        reconcile = method('reconcileCertificateHosts')
        guard = reconcile.index('if ([_certHosts isEqualToArray:hosts]) return')
        for operation in ['removeFromSuperview', '[self certificateRow:', 'insertArrangedSubview:']:
            self.assertGreater(reconcile.index(operation), guard)
        self.assertIn('UIStackView *row = _certRows[host]', reconcile)
        self.assertIn('if (!row)', reconcile)
        self.assertIn('[_certRows removeObjectForKey:host]', reconcile)
        self.assertIn('_certHosts = [hosts copy]', reconcile)
        values = method('updateValues')
        for text in ['[v isKindOfClass:NSDate.class]', 'floor(', 'left < 14',
                     '@"lock.slash.fill"', '@"exclamationmark.lock.fill"', '@"检查中…"']:
            self.assertIn(text, values)

    def test_coalescing_uses_one_default_mode_job_not_a_display_link(self):
        schedule = method('scheduleUpdate')
        self.assertIn('_updateScheduled || ![self isActiveDashboard]', schedule)
        self.assertEqual(schedule.count('performSelector:'), 1)
        self.assertIn('_updateScheduled = YES', schedule)
        self.assertIn('afterDelay:0.1', schedule)
        self.assertIn('NSDefaultRunLoopMode', schedule)
        self.assertNotIn('CADisplayLink', SOURCE)
        self.assertNotIn('NSRunLoopCommonModes', SOURCE)
        flush = method('flushPendingUpdates')
        self.assertIn('_updateScheduled = NO', flush)
        self.assertLess(flush.index('_needsUpdate = NO'), flush.index('[self updateValues]'))
        self.assertEqual(SOURCE.count('[self updateValues]'), 1)

    def test_busy_or_hidden_dashboard_defers_values_without_clearing_dirty(self):
        flush = method('flushPendingUpdates')
        update = flush.index('_needsUpdate = NO')
        for guard in ['![self isActiveDashboard]', '_scroll.tracking', '_scroll.dragging',
                      '_scroll.decelerating', '_refreshInFlight', '_scroll.refreshControl.refreshing']:
            self.assertLess(flush.index(guard), update)
        self.assertLess(flush.index('self.navigationController.transitionCoordinator'), update)
        self.assertIn('animateAlongsideTransition:nil completion:', flush)
        self.assertIn('[w scheduleUpdate]', flush)
        active = method('isActiveDashboard')
        for text in ['_visible', '!_transitioning', 'self.viewIfLoaded.window',
                     'UIApplicationStateActive', 'UISceneActivationStateForegroundActive']:
            self.assertIn(text, active)
        self.assertIn('_transitioning = YES', method('viewWillAppear'))
        self.assertIn('_transitioning = NO', method('viewDidAppear'))
        self.assertIn('_visible = NO', method('viewWillDisappear'))
        self.assertIn('[self suspendUpdates]', method('viewWillDisappear'))

    def test_interaction_end_and_foreground_resume_pending_values(self):
        for name in ['scrollViewDidEndDragging', 'scrollViewDidEndDecelerating',
                     'scrollViewDidEndScrollingAnimation']:
            self.assertIn('[self scheduleUpdate]', method(name))
        self.assertIn('if (!decelerate)', method('scrollViewDidEndDragging'))
        self.assertIn('[self becameActive]', method('viewDidAppear'))
        self.assertIn('[self requestUpdate]', method('becameActive'))
        for notification in ['UIApplicationDidBecomeActiveNotification', 'UISceneDidActivateNotification',
                             'UIApplicationWillResignActiveNotification', 'UISceneWillDeactivateNotification']:
            self.assertIn(notification, method('viewDidLoad'))

    def test_refresh_finishes_before_values_and_waits_for_visual_settling(self):
        pull = method('pull')
        for text in ['if (_refreshInFlight) return', '_refreshInFlight = YES',
                     '[LBSync.shared refresh:nil]', '[LBSiteData.shared refreshAll:',
                     '__weak typeof(self) w', 's->_refreshNeedsEnding = YES', '[s requestUpdate]']:
            self.assertIn(text, pull)
        self.assertNotIn('endRefreshing', pull)
        self.assertNotIn('updateValues', pull)
        flush = method('flushPendingUpdates')
        for text in ['_refreshNeedsEnding', '_refreshSettling = YES', 'endRefreshing',
                     '_scroll.adjustedContentInset', '_scroll.layer.presentationLayer',
                     'UIEdgeInsetsEqualToEdgeInsets', 'CGPointEqualToPoint',
                     'CACurrentMediaTime() < _settleNotBefore', '_refreshSettling = NO']:
            self.assertIn(text, flush)
        self.assertLess(flush.index('endRefreshing'), flush.index('[self updateValues]'))
        self.assertIn('UIAccessibilityIsReduceMotionEnabled() ? 0.1 : 0.5', flush)
        self.assertIn('[UIView performWithoutAnimation:', flush)

    def test_environment_is_parsed_once_per_content_version(self):
        cache = method('updateEnvCache')
        self.assertEqual(SOURCE.count('[LBEnvFile parse:'), 1)
        self.assertIn('if (_envText == text || [_envText isEqualToString:text]) return', cache)
        self.assertIn('_envText = [text copy]', cache)
        self.assertIn('text ? [LBEnvFile parse:text] : nil', cache)
        self.assertIn('_env = [file values]', cache)
        self.assertIn('_friendIndexes = [file friendIndexes]', cache)
        self.assertIn('_enabledFriends = 0', cache)
        self.assertIn('isEqualToString:@"false"', cache)
        self.assertIn('_launchDate = launch.length ?', cache)
        self.assertIn('[self updateEnvCache:d]', method('updateValues'))
        # An SHA-only cache would miss local edits and reset-to-nil semantics.
        self.assertNotIn('data.envSha', cache)

    def test_feature_data_semantics_and_navigation_are_preserved(self):
        build, values = method('buildDashboard'), method('updateValues')
        for tab in ['posts', 'memos', 'inbox', 'config']:
            self.assertIn(f'[w selectTab:@"{tab}"]', build)
        for text in ['PUBLIC_SITE_TITLE', 'deployState:&deployColor pending:NULL',
                     '@max.publishedAt', '@"displayTs"', '@"createdTs"',
                     '[LBSync.shared unreadCount]', 'LBSync.shared.sessions.count',
                     '10 * 60 * 1000', '_setupNotice.hidden = LBGitHub.shared.configured',
                     '_deployCard.userInteractionEnabled = d.head[@"url"] != nil']:
            self.assertIn(text, values)
        self.assertIn('@selector(openCommit)', build)
        self.assertIn('LBSiteData.shared.head[@"url"]', method('openCommit'))
        self.assertIn('LBStore.siteURL', method('openSite'))
        self.assertIn('LBPresentSettings(self)', method('openSettings'))
        self.assertIn('LBNotice(', build)
        self.assertIn('[w openSettings]', build)

    def test_polling_is_visible_foreground_only_and_weak(self):
        timer = method('becameActive')
        for text in ['if (![self isActiveDashboard]) return', 'if (!_tick)',
                     '__weak typeof(self) w', 'TimeInterval:30',
                     'if (!s || ![s isActiveDashboard]) return',
                     'if (pending) [LBSiteData.shared refreshDeploy:nil]']:
            self.assertIn(text, timer)
        for text in ['[_tick invalidate]', '_tick = nil', 'cancelPreviousPerformRequestsWithTarget:self',
                     '_updateScheduled = NO']:
            self.assertIn(text, method('suspendUpdates'))
        self.assertIn('[self suspendUpdates]', method('resignedActive'))
        self.assertIn('note.object != self.viewIfLoaded.window.windowScene', method('resignedActive'))
        self.assertIn('[_tick invalidate]', method('dealloc'))
        self.assertIn('removeObserver:self', method('dealloc'))


if __name__ == '__main__':
    unittest.main(verbosity=2)

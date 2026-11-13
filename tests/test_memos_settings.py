"""Offline source contracts for inline Memos settings; never uses real credentials.
Run: python3 -m unittest discover -s tests -p 'test_memos_settings.py'
UIKit/Keychain/network behavior still requires device testing. SDK compilation is
strict when clang + IOS_SDK (or the standard local 26.5 SDK) are available.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/LBSettings.m'
CODE = SOURCE.read_text()


def method(name):
    match = re.search(r'^- \([^\n]+\)' + re.escape(name) + r'(?=[:\s{])', CODE, re.M)
    if not match:
        raise AssertionError('Missing settings method: ' + name)
    start = CODE.index('{', match.start())
    end = re.search(r'^- \(', CODE[start + 1:], re.M)
    return CODE[start:start + 1 + end.start()] if end else CODE[start:]


def function(name):
    match = re.search(r'^static [^\n]+\b' + re.escape(name) + r'\(', CODE, re.M)
    if not match:
        raise AssertionError('Missing settings helper: ' + name)
    start = CODE.index('{', match.start())
    end = re.search(r'^}', CODE[start + 1:], re.M)
    return CODE[start:start + 2 + end.start()]


class MemosSettingsContracts(unittest.TestCase):
    def test_memos_fields_are_a_peer_card_not_a_drilldown(self):
        load = method('viewDidLoad')
        self.assertIn('UIView *memos = card(vstack(@[', load)
        self.assertIn('heading(@"Memos 根地址"), _memosBase', load)
        self.assertIn('heading(@"Memos 访问令牌"), _memosToken', load)
        self.assertIn('@[ _resultCard, github, workspace, memos, chat, ai, site, notes ]', load)
        self.assertNotIn('LBMemosPresentConnection', CODE)
        self.assertNotIn('memosConfig', CODE)

    def test_client_defaults_and_keychain_backed_secure_field(self):
        load = method('viewDidLoad')
        self.assertIn('_memosBase = [self field:LBMemosClient.shared.baseURL secure:NO url:YES]', load)
        self.assertIn('_memosBase.text = LBMemosClient.shared.baseURL', load)
        self.assertIn('_memosToken = [self field:@"Memos 访问令牌（留空断开连接）" secure:YES url:NO]', load)
        self.assertIn('_memosToken.text = LBMemosClient.shared.token', load)
        self.assertIn('f.secureTextEntry = secure', method('field'))
        self.assertNotIn('NSUserDefaults', CODE)
        self.assertNotIn('setObject:', CODE)
        for logging in ('NSLog(', 'printf(', 'os_log(', 'printenv'):
            self.assertNotIn(logging, CODE)

    def test_root_only_https_and_no_embedded_credentials(self):
        root = function('memosRoot')
        for fragment in ('trim(value)', 'whitespaceAndNewlineCharacterSet', 'controlCharacterSet',
                         'c.scheme.lowercaseString', '@"https"', '!c.host.length',
                         'c.user != nil', 'c.password != nil', 'c.query != nil',
                         'c.fragment != nil', 'c.path.length', '@"/"',
                         'c.port.integerValue < 1', 'c.port.integerValue > 65535'):
            self.assertIn(fragment, root)
        save = method('saveAndTest')
        self.assertLess(save.index('if (!memosBase)'), save.index('configureBaseURL:'))
        self.assertLess(save.index('controlCharacterSet'), save.index('configureBaseURL:'))

    def test_normalize_equivalent_origins_and_trim_before_comparing(self):
        root = function('memosRoot')
        for fragment in ('c.scheme = @"https"', 'c.host = c.host.lowercaseString',
                         'c.path = @""', '[c.port isEqual:@443]', 'c.port = nil'):
            self.assertIn(fragment, root)
        save = method('saveAndTest')
        self.assertIn('*memosToken = trim(_memosToken.text)', save)
        self.assertIn('![memosBase isEqualToString:memosRoot(memos.baseURL)]', save)
        self.assertIn('![memosToken isEqualToString:trim(memos.token)]', save)

    def test_only_atomic_configuration_and_only_when_changed(self):
        save = method('saveAndTest')
        self.assertEqual(save.count('configureBaseURL:'), 1)
        self.assertIn('if (memosChanged && ![memos configureBaseURL:memosBase token:memosToken])', save)
        self.assertNotRegex(CODE, r'(?:memos|LBMemosClient\.shared)\.(?:baseURL|token)\s*=')
        self.assertNotIn('[memos reset]', CODE)
        self.assertLess(save.index('configureBaseURL:'), save.index('NSUInteger memosGeneration = memos.generation'))
        failure = save.split('if (memosChanged &&')[1].split('NSUInteger memosGeneration')[0]
        self.assertIn('钥匙串保存失败', failure)
        self.assertIn('return;', failure)

    def test_empty_token_disconnects_without_identity_request(self):
        save = method('saveAndTest')
        self.assertLess(save.index('configureBaseURL:'), save.index('if (memosToken.length)'))
        branch = save.split('if (memosToken.length)')[1].split('dispatch_group_notify')[0]
        self.assertEqual(branch.count('[memos validate:'), 1)
        self.assertIn('else [lines addObject:@"– Memos：未填写令牌（已断开连接）"]', branch)
        self.assertNotIn('removeDraft', CODE)
        self.assertNotIn('deleteArchived', CODE)

    def test_one_identity_branch_balanced_even_if_generation_stale(self):
        save = method('saveAndTest')
        branch = save.split('if (memosToken.length)')[1].split('dispatch_group_notify')[0]
        self.assertEqual(branch.count('dispatch_group_enter(g)'), 1)
        self.assertEqual(branch.count('dispatch_group_leave(g)'), 1)
        self.assertEqual(CODE.count('[memos validate:'), 1)
        self.assertIn('revision == self->_saveGeneration && memosGeneration == memos.generation', branch)
        self.assertLess(branch.index('}\n        // Balance'), branch.index('dispatch_group_leave(g)'))
        for forbidden in ('addObserver', 'LBMemosPresentConnection', 'authenticationRequired =', '[memos reset]'):
            self.assertNotIn(forbidden, CODE)

    def test_only_sanitized_memos_result_no_names_tokens_or_raw_errors(self):
        save = method('saveAndTest')
        branch = save.split('if (memosToken.length)')[1].split('dispatch_group_notify')[0]
        self.assertIn('memosFailure(error)', branch)
        self.assertIn('@"✓ Memos：身份已验证"', branch)
        for fragment in ('localizedDescription', 'user[@', 'memosToken]', 'memos.baseURL', 'stringWithFormat:'):
            self.assertNotIn(fragment, branch)
        safe = function('memosFailure')
        self.assertIn('error.domain', safe)
        self.assertIn('switch (error.code)', safe)
        for forbidden in ('localizedDescription', 'userInfo', 'underlyingError', 'stringWithFormat:'):
            self.assertNotIn(forbidden, safe)

    def test_edits_and_close_invalidate_old_results(self):
        self.assertIn('UIControlEventEditingChanged', method('field'))
        edited = method('settingsEdited')
        self.assertIn('_saveGeneration++', edited)
        self.assertIn('[self setTesting:NO]', edited)
        self.assertIn('_saveGeneration++', method('close'))
        self.assertIn('_saveGeneration++', method('viewDidDisappear'))
        self.assertIn('self.navigationController.isBeingDismissed', method('viewDidDisappear'))
        save = method('saveAndTest')
        self.assertIn('if (_testing) return;', save)
        self.assertIn('NSUInteger revision = ++_saveGeneration', save)
        notify = save.split('dispatch_group_notify')[1]
        self.assertLess(notify.index('revision != self->_saveGeneration'), notify.index('[self setTesting:NO]'))
        self.assertLess(notify.index('memosGeneration != memos.generation'), notify.index('componentsJoinedByString:'))
        self.assertIn('请检查后重新测试', notify)

    def test_main_queue_confinement_for_callbacks_and_group_collection(self):
        save = method('saveAndTest')
        self.assertIn('if (!NSThread.isMainThread)', save)
        for callback in ('[LBSync.shared refresh:', '[LBMdStore.shared syncFromGitHub:', '[memos validate:'):
            body = save.split(callback)[1].split('dispatch_group_leave(g)')[0]
            self.assertIn('dispatch_async(dispatch_get_main_queue()', body)
        self.assertIn('dispatch_group_notify(g, dispatch_get_main_queue()', save)

    def test_existing_chat_github_and_site_validation_preserved(self):
        save = method('saveAndTest')
        for fragment in ('^[a-f0-9]{64}$', 'if (!https(trim(_base.text)))', 'if (!https(site))',
                         'owner/name', '[LBSync.shared resetBaseline]',
                         '[LBMdStore.shared syncFromGitHub:', '[LBSync.shared refresh:',
                         'LBStore.repo = repo', 'LBStore.siteURL = site',
                         'LBStore.certHosts = _hosts.text', '[LBSiteData.shared resetConnection]',
                         '[LBSiteData.shared refreshAll:nil]'):
            self.assertIn(fragment, save)
        load = method('viewDidLoad')
        self.assertIn('_base.text = LBAPI.shared.baseURL', load)
        self.assertIn('_site.text = LBStore.siteURL', load)
        self.assertNotIn('shuoshuo.ssaw.top', CODE)  # No independent hardcoded Memos default.

    def test_native_scroll_keyboard_and_weak_button_capture(self):
        load = method('viewDidLoad')
        for fragment in ('scroll.contentLayoutGuide', 'scroll.frameLayoutGuide',
                         'self.view.keyboardLayoutGuide.topAnchor',
                         'UIScrollViewKeyboardDismissModeInteractive',
                         '__weak typeof(self) weakSelf = self', '[weakSelf saveAndTest]'):
            self.assertIn(fragment, load)
        self.assertNotIn('WKWebView', CODE)

    def test_strict_sdk_26_compilation(self):
        sdk = Path(os.environ.get('IOS_SDK', Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'))
        if not shutil.which('clang') or not sdk.is_dir():
            self.skipTest('clang/iPhoneOS SDK not installed; source contracts still run')
        command = ['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
                   '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc',
                   '-I', str(ROOT / 'src'), '-Wall', '-Wextra', '-Werror',
                   '-Wno-unused-parameter', '-Wno-nullability-completeness',
                   '-fsyntax-only', str(SOURCE)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=180)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()

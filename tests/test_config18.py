"""v1.8 config hierarchy: source contracts + strict real-SDK syntax check.

Run: python3 -m unittest discover -s tests -p 'test_config18.py' -v
No dotenv values, credentials, git operations or network requests are used.
Source contracts are not a substitute for native navigation/pixel QA.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'src/LBConfig.m').read_text()
CONFIG = SOURCE.split('@implementation LBSiteConfigViewController {', 1)[1]


def method(signature):
    """Extract one implementation method, including nested block bodies."""
    tail = CONFIG.split(signature, 1)[1]
    return re.split(r'\n[-+] \(', tail, maxsplit=1)[0]


class Config18Contracts(unittest.TestCase):
    def test_root_is_categories_not_flat_editable_fields(self):
        self.assertIn('return _selectedSection ? _sections.count : 1;', CONFIG)
        rows = method('- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:')
        self.assertIn('if (!_selectedSection) return _sections.count;', rows)
        cell = method('- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:')
        self.assertLess(cell.index('if (!_selectedSection) return [self categoryCell:'),
                        cell.index('UISwitch *sw'))
        card = method('- (UITableViewCell *)categoryCell:')
        for text in ('section[@"title"]', 'keys.count', 'friendIndexes',
                     'labelFor:item[@"key"]', 'labels.count == 3', 'chevron.right',
                     '[c finishConfiguration]'):
            self.assertIn(text, card)
        for text in ('valueFor:', 'updateValue:', 'UISwitch', 'addFriend', 'edit:'):
            self.assertNotIn(text, card)

    def test_push_has_explicit_section_and_no_draft_copy(self):
        select = method('- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:')
        root = select.split('NSArray *keys', 1)[0]
        for text in ('if (!_selectedSection)', 'initWithOwner:self selectedSection:_sections[ip.row]',
                     '_activeDetail = detail', 'pushViewController:detail animated:YES', 'return;'):
            self.assertIn(text, root)
        for text in ('parse:', 'serialize', 'addFriend', 'LBValueEditor'):
            self.assertNotIn(text, root)
        init = method('- (instancetype)initWithOwner:')
        self.assertIn('_owner = owner; _selectedSection = section;', init)
        self.assertNotIn('_file =', init)
        self.assertNotIn('LBEnvFile parse:', init)

    def test_same_env_instance_and_baseline_not_child_caches(self):
        self.assertIn('- (LBEnvFile *)file { return _selectedSection ? [_owner file] : _file; }', CONFIG)
        self.assertIn('return _selectedSection ? [_owner baseline] : _baseText;', CONFIG)
        details = CONFIG.split('#pragma mark Table:', 1)[1]
        self.assertNotIn('self->_file', details)
        self.assertNotIn('[_file ', details)
        self.assertIn('initWithFile:[self file]', details)
        self.assertIn('parse:[self baseline]', details)

    def test_dirty_state_stays_root_owned_across_push_pop(self):
        dirty = method('- (BOOL)dirty')
        self.assertIn('if (_selectedSection) return _owner.dirty;', dirty)
        self.assertIn('![[_file serialize] isEqualToString:_baseText]', dirty)
        appeared = method('- (void)viewDidAppear:')
        self.assertIn('[self dataChanged]', appeared)
        changed = method('- (void)dataChanged')
        self.assertIn('if (_selectedSection) { [_owner dataChanged]; [self rebuild]; return; }', changed)
        self.assertIn('(!self.dirty || !_file ||', changed)
        self.assertIn('BOOL keepEdits = _file && !_baseSha', changed)
        self.assertIn('if (!keepEdits) _file = [LBEnvFile parse:_baseText]', changed)
        refresh = method('- (void)pull:')
        self.assertIn('if (_selectedSection) { [_owner pull:rc]; return; }', refresh)
        self.assertLess(refresh.index('if (self.dirty)'), refresh.index('refreshEnv:'))

    def test_background_refresh_cannot_detach_open_value_editor(self):
        guard = method('- (BOOL)hasActiveEditor')
        self.assertIn('self.presentedViewController != nil', guard)
        self.assertIn('_activeDetail.presentedViewController != nil', guard)
        changed = method('- (void)dataChanged')
        self.assertLess(changed.index('![self hasActiveEditor]'),
                        changed.index('if (!keepEdits) _file ='))
        self.assertIn('_baseRepo && ![_baseRepo isEqualToString:LBStore.repo]', changed)

    def test_detail_uses_latest_file_sections_after_refresh_or_friend_edits(self):
        rebuild = method('- (void)rebuild')
        detail = rebuild.split('LBSiteData *data', 1)[0]
        for text in ('if (_selectedSection)', '[[self file] sections]',
                     '_selectedSection[@"friends"]', 'section[@"title"]',
                     '_sections = current ? @[ current ] : @[]', 'self.dirty',
                     '[_table reloadData]'):
            self.assertIn(text, detail)
        self.assertNotIn('parse:', detail)
        self.assertIn('[_activeDetail rebuild]', rebuild)
        changed = method('- (void)draftChanged')
        self.assertIn('[_owner rebuild]; [self rebuild]', changed)

    def test_no_owner_cycle_and_weak_editor_callback(self):
        self.assertIn('__weak LBSiteConfigViewController *_owner;', CONFIG)
        self.assertIn('__weak LBSiteConfigViewController *_activeDetail;', CONFIG)
        edit = method('- (void)edit:')
        self.assertIn('__weak typeof(self) w = self;', edit)
        self.assertIn('done:^{ [w draftChanged]; }', edit)
        cell = method('- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:')
        self.assertIn('UISwitch *sender = (UISwitch *)a.sender;', cell)
        self.assertIn('[[w file] updateValue:sender.on', cell)
        self.assertIn('[w draftChanged]', cell)

    def test_friend_mutations_are_detail_only_and_share_draft(self):
        select = method('- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:')
        self.assertLess(select.index('if (![self isFriends:ip.section]) return;'),
                        select.index('[[self file] addFriend]'))
        menu = method('- (void)friendMenu:')
        self.assertIn('if (!_selectedSection || ![self isFriends:0]) return;', menu)
        for text in ('[[self file] updateValue:', '[[self file] removeFriend:', '[self draftChanged]'):
            self.assertIn(text, menu)
        edit = method('- (void)edit:')
        self.assertIn('if (!_selectedSection || ![self file]) return;', edit)
        self.assertIn('_selectedSection && s >= 0 && s < (NSInteger)_sections.count', CONFIG)
        self.assertIn('[_sections[s][@"friends"] boolValue]', CONFIG)

    def test_root_alone_observes_and_installs_review(self):
        load = method('- (void)viewDidLoad')
        boundary = load.index('if (_selectedSection) { [self rebuild]; return; }')
        self.assertLess(boundary, load.index('_review ='))
        self.assertLess(boundary, load.index('addObserver:self'))
        self.assertIn('initWithTitle:@"保存预览"', load)
        self.assertIn('dirty ? @[ _review, _revert ] : @[]', CONFIG)
        self.assertEqual(CONFIG.count('initWithOriginal:'), 1)
        self.assertEqual(CONFIG.count('didCommitEnv:'), 1)
        review = method('- (void)review')
        for text in ('initWithOriginal:_baseText edited:edited sha:_baseSha',
                     '[_file validate]', 's->_baseText = edited', 's->_baseSha = nil',
                     'didCommitEnv:edited commit:commit'):
            self.assertIn(text, review)
        self.assertIn('putFile:@".env" text:_edited sha:_sha message:msg', SOURCE)
        self.assertEqual(SOURCE.count('putFile:'), 1)

    def test_native_glass_and_self_sizing_card_finish(self):
        load = method('- (void)viewDidLoad')
        self.assertIn('LBGlassTable(self, self)', load)
        self.assertIn('UINavigationItemLargeTitleDisplayModeNever', load)
        self.assertIn('_selectedSection[@"title"] : @"站点配置"', load)
        for text in ('titleView =', 'viewForHeaderInSection:', 'titleForHeaderInSection:',
                     'willDisplayHeaderView:', 'LBPresentSettings'):
            self.assertNotIn(text, load)
        for before in CONFIG.split('return c;')[:-1]:
            self.assertTrue(before.rstrip().endswith('[c finishConfiguration];'))

    def test_no_connection_settings_or_new_public_interface(self):
        self.assertNotIn('LBMemosClient', CONFIG)
        self.assertNotIn('configureBaseURL:', CONFIG)
        self.assertNotIn('apiKey', CONFIG)
        public = (ROOT / 'src/LB.h').read_text().split('@interface LBSiteConfigViewController', 1)[1].split('@end', 1)[0]
        self.assertNotIn('initWithOwner:', public)
        self.assertNotIn('selectedSection:', public)

    def test_real_sdk_strict_syntax_compile(self):
        sdk = Path(os.environ.get('LB_IOS_SDK', '~/.ios-sdk/iPhoneOS26.5.sdk')).expanduser()
        clang = shutil.which('clang')
        if not clang or not sdk.is_dir():
            self.skipTest('clang/iOS SDK unavailable; source contracts still run')
        command = [clang, '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk),
                   '-F', str(sdk / 'System/Library/SubFrameworks'), '-fobjc-arc',
                   '-I', str(ROOT / 'src'), '-Wall', '-Wextra', '-Werror',
                   '-Wno-unused-parameter', '-Wno-nullability-completeness',
                   '-fsyntax-only', str(ROOT / 'src/LBConfig.m')]
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)

# Review button must not retain the controller and the full configuration text.
class ConfigReviewLifetime(unittest.TestCase):
    def test_review_action_weakly_captures_controller(self):
        review = SOURCE.split('@implementation LBReviewViewController', 1)[1].split('#pragma mark - Config screen', 1)[0]
        self.assertIn('__weak typeof(self) weakSelf = self;', review)
        self.assertIn('[weakSelf commit]', review)
        self.assertNotIn('handler:^(UIAction *a) { [self commit]; }', review)

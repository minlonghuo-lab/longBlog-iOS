"""Offline editor contracts. Run: python3 -m unittest discover -s tests -p 'test_memos_editor.py'.
These tests inspect production ObjC and optionally compile against the installed
SDK. They do not pretend to execute UIKit, PhotosUI, networking or Keychain.
"""
from pathlib import Path
import os
import re
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/LBMemosEditor.m'
CODE = SOURCE.read_text()


def method(name):
    """Return one ObjC implementation, including nested blocks."""
    match = re.search(r'^- \([^\n]+\)' + re.escape(name) + r'(?=[:\s{])', CODE, re.M)
    if not match:
        raise AssertionError('Missing editor method: ' + name)
    start = CODE.index('{', match.start())
    # Next method starts in column zero, never inside a block or string.
    end = re.search(r'^- \(', CODE[start + 1:], re.M)
    return CODE[start: start + 1 + end.start()] if end else CODE[start:]


class MemosEditorContracts(unittest.TestCase):
    def test_only_independent_native_editor_class(self):
        self.assertIn('@implementation LBMemosEditor', CODE)
        self.assertIn('UITextViewDelegate', CODE)
        self.assertNotIn('WKWebView', CODE)
        self.assertNotIn('SwiftUI', CODE)

    def test_default_private_and_preserve_original(self):
        self.assertIn('value : @"PRIVATE"', CODE)
        self.assertIn('_initialVisibility = LBEditorVisibility(_original[@"visibility"])', CODE)
        self.assertIn('@[@"仅自己", @"登录可见", @"公开"]', CODE)
        self.assertIn('@[@"PRIVATE", @"PROTECTED", @"PUBLIC"]', method('visibilityChanged'))

    def test_original_is_deep_snapshot(self):
        init = method('initWithMemo')
        self.assertIn('dataWithJSONObject:memo', init)
        self.assertIn('JSONObjectWithData:data', init)
        self.assertIn('saveOriginal:_original', method('uploadNext'))
        self.assertNotRegex(CODE, r'_original\s*\[[^\]\n]+\]\s*=')

    def test_all_seven_markdown_actions_and_undo(self):
        self.assertIn('@[@"粗体", @"标题", @"列表", @"待办", @"代码", @"链接", @"标签", @"收起"]', CODE)
        action = method('formatPressed')
        for part in ('lineRangeForRange:', '@"## "', '@"- "', '@"- [ ] "', 'https://', '#%@', 'beginUndoGrouping', 'replaceRange:'):
            self.assertIn(part, action)

    def test_chinese_ime_is_committed_before_save(self):
        body = method('savePressed')
        self.assertLess(body.index('unmarkText'), body.index('[self beginSave]'))
        self.assertIn('_text.markedTextRange', method('persistDraft'))

    def test_photos_picker_without_broad_permission(self):
        self.assertIn('config.selectionLimit = 10', CODE)
        self.assertIn('PHPickerFilter.imagesFilter', CODE)
        self.assertIn('PHPickerFilter.videosFilter', CODE)
        for forbidden in ('requestAuthorization', 'UIImagePickerController', 'AVCaptureDevice', 'PHPhotoLibrary authorizationStatus'):
            self.assertNotIn(forbidden, CODE)

    def test_files_include_all_types_and_reject_whole_oversize_batch(self):
        self.assertIn('initForOpeningContentTypes:@[UTTypeItem]', CODE)
        self.assertIn('picker.allowsMultipleSelection = YES', CODE)
        self.assertIn('urls.count > 10', method('documentPicker'))
        self.assertIn('此次没有导入任何文件', CODE)
        self.assertNotIn('subarrayWithRange:', CODE)

    def test_provider_temporary_url_is_copied_inside_callback(self):
        body = method('picker')
        callback = body[body.index('loadFileRepresentationForTypeIdentifier:'):]
        self.assertLess(callback.index('LBEditorCopy(url'), callback.index('dispatch_async(dispatch_get_main_queue()'))

    def test_security_scope_and_bounded_protected_copy(self):
        for fragment in ('startAccessingSecurityScopedResource', 'stopAccessingSecurityScopedResource', 'coordinateReadingItemAtURL:',
                         '32ULL * 1024ULL * 1024ULL', 'NSFileProtectionCompleteUntilFirstUserAuthentication', 'NSURLIsExcludedFromBackupKey'):
            self.assertIn(fragment, CODE)
        self.assertIn('NSFileTypeRegular', CODE)
        self.assertIn('UTType typeWithFilenameExtension:', CODE)
        self.assertIn('type.preferredMIMEType', CODE)

    def test_safe_paths_not_arbitrary_draft_urls(self):
        self.assertIn('MemosEditorFiles', CODE)
        self.assertIn('URLByResolvingSymlinksInPath', CODE)
        self.assertIn('URLByDeletingLastPathComponent.URLByDeletingLastPathComponent', CODE)
        self.assertIn('NSUUID.UUID.UUIDString', CODE)
        self.assertIn('LBEditorFilename(filename)', CODE)

    def test_concurrent_import_cancel_guards(self):
        complete = method('completeImport')
        for fragment in ('epoch != _importEpoch', '![_attachments containsObject:a]', 'LBEditorRemoveFile(file)', '_pendingImports - 1'):
            self.assertIn(fragment, complete)
        self.assertIn('_pendingImports++', method('beginImport'))
        self.assertIn('[a.importProgress cancel]', method('removeAttachment'))

    def test_native_horizontal_attachment_states(self):
        for fragment in ('UILayoutConstraintAxisHorizontal', 'UIProgressView', 'CGImageSourceCreateThumbnailAtIndex', 'waveform', 'filename', '重试此文件上传'):
            self.assertIn(fragment, CODE)

    def test_remove_only_unlinks_not_remote_delete(self):
        self.assertIn('[_attachments removeObject:a]', method('removeAttachment'))
        self.assertNotIn('deleteResource:', CODE)
        self.assertNotIn('deleteArchived:', CODE)

    def test_no_save_until_imports_and_files_ready(self):
        body = method('savePressed')
        self.assertIn('_saving || _pendingImports || ![self accountCurrent]', body)
        self.assertIn('!a.resourceID && (!a.file || !LBEditorOwnFile(a.file))', body)
        self.assertIn('!_text.text.length && !_attachments.count', body)

    def test_sequential_upload_and_no_reupload_known_ids(self):
        body = method('uploadNext')
        self.assertIn('if (!a.resourceID)', body)
        self.assertIn('[self uploadNext]; }]; return;', body)
        upload = method('uploadAttachment')
        self.assertIn('a.resourceID = identifier', upload)
        self.assertLess(upload.index('a.resourceID = identifier'), upload.index('if (completion) completion()'))

    def test_cancel_waits_for_completion_and_does_not_publish(self):
        self.assertIn('_cancelingUpload = YES', method('stopUpload'))
        self.assertIn('[_uploadTask cancel]', method('stopUpload'))
        self.assertNotIn('_saving = NO', method('stopUpload'))
        self.assertIn('if (canceled) { self->_saving = NO;', method('uploadAttachment'))

    def test_save_is_single_call_and_unknown_requires_confirmation(self):
        self.assertEqual(CODE.count('saveOriginal:_original'), 1)
        self.assertIn('我已检查，仍要保存', method('savePressed'))
        self.assertIn('failure.code == 1010', method('uploadNext'))
        self.assertNotIn('savePressed', method('uploadAttachment'))

    def test_account_generation_pinned_and_every_draft_guarded(self):
        self.assertIn('_generation = LBMemosClient.shared.generation', method('initWithMemo'))
        self.assertIn('_generation == LBMemosClient.shared.generation', method('accountCurrent'))
        self.assertIn('![self accountCurrent]', method('persistDraft'))
        self.assertIn('_importEpoch++', method('connectionChanged'))

    def test_debounced_private_draft_and_pending_metadata(self):
        self.assertIn('afterDelay:1.0', method('changed'))
        draft = method('persistDraft')
        for key in ('@"text"', '@"visibility"', '@"resourceIDs"', '@"localFiles"', '@"resourceList"'):
            self.assertIn(key, draft)
        self.assertIn('[stored[@"localFiles"] isEqual:files]', draft)
        self.assertNotIn('@"token"', draft)
        self.assertIn('本地附件已丢失', method('restoreDraft'))

    def test_busy_controls_and_modal_exit_protected(self):
        self.assertIn('self.modalInPresentation = YES', CODE)
        controls = method('refreshControls')
        for fragment in ('_text.editable = !_saving', '_saveButton.enabled = !_saving', '_closeButton.enabled = !_saving'):
            self.assertIn(fragment, controls)
        close = method('closeEditor')
        for label in ('保存草稿并关闭', '丢弃并关闭', '继续编辑'):
            self.assertIn(label, close)
        self.assertNotIn('saveOriginal:', close)
        self.assertNotIn('[self beginSave]', close)

    def test_preview_synthetic_memo_no_credentials(self):
        preview = method('showPreview')
        self.assertIn('LBMemoMarkdownPreview(memo)', preview)
        self.assertIn('@"resourceList"', preview)
        self.assertNotIn('token', preview)
        self.assertIn('memo[@"createdTs"] = _original[@"createdTs"]', preview)
        self.assertIn('_saving || ![self accountCurrent]', preview)
        self.assertNotIn('dateWithTimeIntervalSinceNow', preview)

    def test_callbacks_use_main_queue(self):
        for name in ('picker', 'documentPicker', 'uploadAttachment', 'uploadNext'):
            self.assertIn('dispatch_get_main_queue()', method(name))

    def test_canvas_dock_constraint_chain_has_one_keyboard_owner(self):
        """Inspect production anchors, not a parallel screen-size/pixel model."""
        load = method('viewDidLoad')
        links = re.findall(
            r'\[(_\w+)\.(\w+Anchor) constraintEqualToAnchor:([^\]\n]+)\]', load)
        chain = {(view, anchor): target for view, anchor, target in links}
        self.assertEqual(chain[('_text', 'topAnchor')], '_visibilityButton.bottomAnchor')
        self.assertEqual(chain[('_text', 'bottomAnchor')], '_dock.topAnchor constant:-8')
        self.assertEqual(chain[('_dock', 'bottomAnchor')],
                         'self.view.keyboardLayoutGuide.topAnchor constant:-8')
        for anchor in ('leadingAnchor', 'trailingAnchor'):
            self.assertEqual(chain[('_text', anchor)], 'safe.' + anchor)
            self.assertIn('safe.' + anchor, chain[('_dock', anchor)])
        self.assertEqual(CODE.count('self.view.keyboardLayoutGuide.topAnchor'), 1)
        for duplicate_owner in ('inputAccessoryView =', 'UIKeyboardWillChangeFrameNotification',
                                'UIKeyboardWillShowNotification', 'keyboardFrameEndUserInfoKey'):
            self.assertNotIn(duplicate_owner, CODE)
        self.assertIn('UIScrollViewContentInsetAdjustmentNever', load)

    def test_bottom_attachments_are_conditional_arranged_content(self):
        load = method('viewDidLoad')
        items = re.findall(r'\[_dock addArrangedSubview:([^;]+)\];', load)
        self.assertEqual(items, ['_status', '_strip', '[self writingToolbar]'])
        self.assertIn('_strip.hidden = !_attachments.count', method('renderAttachments'))
        self.assertIn('if (!_attachments.count) return', method('renderAttachments'))
        self.assertIn('stripHeight.priority = UILayoutPriorityDefaultHigh', load)
        self.assertIn('_status.hidden = !_status.text.length', method('refreshControls'))
        # Existing failure/progress states remain in the horizontally scrolling strip.
        self.assertIn('_strip.contentLayoutGuide.leadingAnchor', load)
        self.assertIn('_strip.contentLayoutGuide.trailingAnchor', load)
        self.assertIn('_strip.frameLayoutGuide.heightAnchor', load)

    def test_single_scrollable_glass_toolbar_and_accessible_targets(self):
        toolbar = method('writingToolbar')
        self.assertEqual(toolbar.count('UIGlassEffect effectWithStyle:'), 1)
        self.assertIn('LBEditorToolbarGlass alloc', toolbar)
        self.assertIn('capsule.cornerConfiguration = [UICornerConfiguration capsuleConfiguration]', toolbar)
        glass = CODE.split('@implementation LBEditorToolbarGlass', 1)[1].split('@end', 1)[0]
        self.assertIn('[super layoutSubviews]', glass)
        self.assertIn('CGFloat radius = size.height / 2.0', glass)
        self.assertIn('self.layer.cornerRadius = radius', glass)
        self.assertIn('self.clipsToBounds = YES', glass)
        self.assertIn('[CATransaction setDisableActions:YES]', glass)
        self.assertNotIn('maskView', glass)
        self.assertIn('[_toolbar layoutIfNeeded]', method('viewDidLayoutSubviews'))
        self.assertIn('[_toolbar setNeedsLayout]', method('viewWillAppear'))
        self.assertIn('stack.widthAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.widthAnchor', toolbar)
        self.assertIn('stack.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor', toolbar)
        self.assertIn('@[_stop, _attach, _files, tag, format, _preview, dismiss]', toolbar)
        button = method('toolButton')
        self.assertIn('button.accessibilityLabel = title', button)
        self.assertIn('constraintGreaterThanOrEqualToConstant:44', button)
        self.assertIn('width.priority = 999', button)  # UIStackView hidden = width 0.
        self.assertIn('heightAnchor constraintEqualToConstant:44', button)
        for destination in ('choosePhotos', 'chooseFiles', 'showPreview', 'stopUpload'):
            self.assertIn('@selector(' + destination + ')', toolbar)
        self.assertIn('format.showsMenuAsPrimaryAction = YES', toolbar)
        self.assertIn('i < symbols.count', toolbar)
        self.assertIn('[weakSelf formatPressed:sender]', toolbar)
        self.assertIn('tag.tag = 6', toolbar)
        self.assertIn('dismiss.tag = 7', toolbar)
        for picker in ('choosePhotos', 'chooseFiles'):
            self.assertIn('_saving || ![self accountCurrent]', method(picker))

    def test_compact_privacy_menu_has_checked_state_and_restores_draft(self):
        self.assertNotIn('UISegmentedControl', CODE)
        self.assertIn('_visibilityButton.showsMenuAsPrimaryAction = YES', method('viewDidLoad'))
        privacy = method('visibilityChanged')
        self.assertIn('action.state = i == selected ? UIMenuElementStateOn', privacy)
        self.assertIn('self->_visibility = values[i]', privacy)
        self.assertIn('self->_saving || ![self accountCurrent]', privacy)
        self.assertIn('[self visibilityChanged]', method('restoreDraft'))
        self.assertIn('_visibilityButton.enabled = !_saving && current', method('refreshControls'))

    def test_canvas_insets_and_viewport_scroll_do_not_interrupt_ime(self):
        load = method('viewDidLoad')
        self.assertIn('_text.textContainer.lineFragmentPadding = 0', load)
        self.assertIn('_text.contentLayoutGuide.topAnchor', load)
        self.assertIn('_text.frameLayoutGuide.widthAnchor', load)
        self.assertIn('UIScrollViewKeyboardDismissModeInteractive', load)
        layout = method('viewDidLayoutSubviews')
        self.assertIn('!CGSizeEqualToSize(_lastTextSize, _text.bounds.size)', layout)
        self.assertIn('_text.isFirstResponder && !_text.markedTextRange', layout)
        self.assertIn('scrollRangeToVisible:_text.selectedRange', layout)
        self.assertIn('if (!_requestedFocus)', method('viewDidAppear'))

    def test_strict_sdk_26_compilation(self):
        sdk = Path(os.environ.get('IOS_SDK', Path.home() / '.ios-sdk/iPhoneOS26.5.sdk'))
        if not shutil.which('clang') or not sdk.is_dir():
            self.skipTest('clang/iPhoneOS26.5.sdk not installed; source contracts still run')
        command = ['clang', '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk), '-F', str(sdk / 'System/Library/SubFrameworks'),
                   '-fobjc-arc', '-I', str(ROOT / 'src'), '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                   '-Wno-nullability-completeness', '-fsyntax-only', str(SOURCE)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=180)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()

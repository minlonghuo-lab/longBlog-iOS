"""JPEG upload source contracts and real-SDK compile checks.
These tests do not execute PhotosUI/ImageIO; JPEG23Fixtures.m is runnable only in an iOS host.
"""
from pathlib import Path
import os, shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/LBMemosEditor.m'
FIXTURE = ROOT / 'tests/JPEG23Fixtures.m'
CODE = SOURCE.read_text()
def section(start, end): return CODE.split(start, 1)[1].split(end, 1)[0]
class JPEG23Contracts(unittest.TestCase):
    def test_photo_provider_prefers_jpeg_not_heif(self):
        helper = section('static NSString *LBEditorProviderIdentifier', 'static NSError *LBEditorError')
        self.assertIn('isEqual:UTTypeJPEG.identifier', helper)
        self.assertNotIn('if (LBEditorHEIFExtension(candidate)) return candidate;', helper)
        self.assertIn('conformsToType:UTTypeMovie', helper)
        self.assertIn('return fallback ?: generic', helper)
        # Current avoids system video transcoding; actual still-image conversion is explicit.
        self.assertIn('PHPickerConfigurationAssetRepresentationModeCurrent', CODE)
    def test_real_jpeg_primary_full_resolution_and_orientation(self):
        helper = section('static NSURL *LBEditorPrepareCopy', 'static UIImage *LBEditorThumbnail')
        for value in ['CGImageSourceGetPrimaryImageIndex(source)', 'CGImageDestinationCreateWithURL',
                      'CGImageDestinationAddImageFromSource(destination, source, index',
                      'kCGImageDestinationLossyCompressionQuality:@1.0', 'CGImageDestinationFinalize',
                      'UTTypeJPEG.identifier', 'kCGImagePropertyPixelWidth', 'kCGImagePropertyPixelHeight',
                      'kCGImagePropertyOrientation', 'LBEditorImportMetadata(result']:
            self.assertIn(value, helper)
        for forbidden in ['ThumbnailMaxPixelSize', 'UIGraphics', 'resize', 'UIImageJPEGRepresentation']:
            self.assertNotIn(forbidden, helper)
    def test_no_repeat_encoding_or_unrelated_file_conversion(self):
        helper = section('static NSURL *LBEditorPrepareCopy', 'static UIImage *LBEditorThumbnail')
        self.assertIn('!animated && ![actual isEqual:UTTypeJPEG.identifier]', helper)
        self.assertIn('BOOL convert = heif || hintedHEIF || (photo', helper)
        self.assertIn('UTTypeGIF.identifier', helper)
        upload = section('- (void)uploadAttachment:', '- (void)retryAttachment:')
        self.assertIn('uploadFile:a.file filename:a.filename type:a.type', upload)
        self.assertNotIn('LBEditorPrepareCopy', upload)
        self.assertNotIn('LBEditorPrepareCopy', section('- (void)restoreDraft', '- (BOOL)persistDraft'))
    def test_jpeg_filename_and_mime_follow_actual_payload(self):
        helper = section('static NSDictionary *LBEditorImportMetadata', 'static NSString *LBEditorProviderIdentifier')
        self.assertIn('if (actual.length) identifier = actual', helper)
        self.assertIn('jpeg ? @"jpg"', helper)
        self.assertIn('120 - ext.length - 1', helper)
        self.assertIn('type.preferredMIMEType', helper)
    def test_copy_provider_url_before_queued_preparation(self):
        picker = section('- (void)picker:', '- (void)documentPicker:')
        self.assertLess(picker.index('LBEditorCopy(url'), picker.index('dispatch_async(LBEditorPreparationQueue()'))
        self.assertIn('LBEditorPrepareCopy(copy, name, identifier, photo, progress', picker)
        self.assertIn('a.providerProgress = [provider loadFileRepresentation', picker)
        self.assertIn('@autoreleasepool', picker)
        self.assertIn('DISPATCH_QUEUE_SERIAL', CODE)
    def test_files_and_cancelled_imports_have_no_bypass_or_resurrection(self):
        picker = section('- (void)documentPicker:', '- (void)documentPickerWasCancelled:')
        self.assertIn('LBEditorPrepareCopy(copy, url.lastPathComponent, identifier, NO, progress', picker)
        self.assertLess(picker.index('LBEditorCopy(url'), picker.index('stopAccessingSecurityScopedResource'))
        for value in ['epoch != _importEpoch', '![_attachments containsObject:a]',
                      '[a.importProgress cancel]; [a.providerProgress cancel]', 'progress.cancelled']:
            self.assertIn(value, CODE)
    def test_size_private_files_and_drafts_preserved(self):
        for value in ['32ULL * 1024ULL * 1024ULL', 'NSFileTypeRegular',
                      'NSFileProtectionCompleteUntilFirstUserAuthentication', 'NSURLIsExcludedFromBackupKey',
                      'coordinateReadingItemAtURL:', 'URLByResolvingSymlinksInPath',
                      'JPEG 转换后超过 32 MiB', 'LBEditorRemoveFile(copy)']:
            self.assertIn(value, CODE)
    def test_fixture_uses_real_production_helpers(self):
        fixture = FIXTURE.read_text()
        for value in ['#import "../src/LBMemosEditor.m"', 'LBEditorPrepareCopy(',
                      'CGImageSourceGetPrimaryImageIndex', 'isEqual:before', 'progress cancel']:
            self.assertIn(value, fixture)
    def test_strict_sdk_compile_production_and_fixture(self):
        sdk = Path(os.environ.get('IOS_SDK', Path.home()/'.ios-sdk/iPhoneOS26.5.sdk'))
        clang = shutil.which('clang')
        if not clang or not sdk.is_dir(): self.skipTest('SDK unavailable; no runtime claim')
        flags = [clang, '-target', 'arm64-apple-ios26.0', '-isysroot', str(sdk), '-F',
                 str(sdk/'System/Library/SubFrameworks'), '-fobjc-arc', '-I', str(ROOT/'src'),
                 '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-Wno-nullability-completeness']
        with tempfile.TemporaryDirectory() as temp:
            for source in (SOURCE,FIXTURE):
                obj=Path(temp)/(source.stem+'.o')
                for attempt in range(3):
                    result=subprocess.run(flags+['-c',str(source),'-o',str(obj)],capture_output=True,text=True,timeout=240)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    if obj.stat().st_size: break
                self.assertGreater(obj.stat().st_size,0)
if __name__=='__main__': unittest.main()

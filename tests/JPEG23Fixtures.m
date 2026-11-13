// Compile-only on Linux; invoke these actual production helpers in an iOS test host.
#import "../src/LBMemosEditor.m"
#import <assert.h>
@interface LBJPEG23Provider : NSItemProvider
@property(nonatomic, copy) NSArray<NSString *> *offeredTypes;
@end
@implementation LBJPEG23Provider
- (NSArray<NSString *> *)registeredTypeIdentifiers { return self.offeredTypes; }
@end
void LBJPEG23MetadataFixtures(void) {
  @autoreleasepool {
    LBJPEG23Provider *provider = [LBJPEG23Provider new];
    provider.offeredTypes = @[@"public.heic", @"public.jpeg"];
    assert([LBEditorProviderIdentifier(provider) isEqual:@"public.jpeg"]);
    provider.offeredTypes = @[@"public.movie"];
    assert([LBEditorProviderIdentifier(provider) isEqual:@"public.movie"]);
    assert([LBEditorImportIdentifier(@"public.data", @"HEIF") isEqual:@"public.heif"]);
    NSDictionary *metadata = LBEditorImportMetadata(nil, @"IMG_0001.HEIC", @"public.jpeg");
    assert([metadata[@"filename"] isEqual:@"IMG_0001.jpg"]);
    assert([metadata[@"type"] isEqual:@"image/jpeg"]);
    NSString *longName = [@"x" stringByPaddingToLength:150 withString:@"x" startingAtIndex:0];
    metadata = LBEditorImportMetadata(nil, longName, @"public.jpeg");
    assert([metadata[@"filename"] length] <= 120);
    assert([[metadata[@"filename"] pathExtension] isEqual:@"jpg"]);
  }
}
// Supply a licensed real HEIC/HEIF or static PNG/JPEG fixture below 32 MiB.
// photo=NO additionally checks Files HEIF conversion; other Files formats keep bytes.
void LBJPEG23PayloadFixture(NSURL *original, BOOL photo, BOOL expectJPEG, BOOL unchanged) {
  @autoreleasepool {
    NSData *before = [NSData dataWithContentsOfURL:original];
    assert(before.length && before.length <= LBEditorFileLimit);
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)original, NULL);
    size_t index = source ? CGImageSourceGetPrimaryImageIndex(source) : 0;
    NSDictionary *input = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL)) : nil;
    if (source) CFRelease(source);
    NSError *error = nil; NSDictionary *metadata = nil;
    NSURL *copy = LBEditorCopy(original, original.lastPathComponent, &error);
    assert(copy && !error);
    NSProgress *progress = [NSProgress discreteProgressWithTotalUnitCount:1];
    NSURL *file = LBEditorPrepareCopy(copy, original.lastPathComponent, @"public.data", photo, progress, &metadata, &error);
    assert(file && !error && LBEditorOwnFile(file));
    NSData *after = [NSData dataWithContentsOfURL:file];
    if (unchanged) assert([after isEqual:before]);
    if (expectJPEG) {
      assert([metadata[@"type"] isEqual:@"image/jpeg"]);
      assert([[metadata[@"filename"] pathExtension] isEqual:@"jpg"]);
      assert(after.length > 3 && ((const unsigned char *)after.bytes)[0] == 0xff && ((const unsigned char *)after.bytes)[1] == 0xd8);
      CGImageSourceRef check = CGImageSourceCreateWithURL((__bridge CFURLRef)file, NULL);
      assert(check && CFEqual(CGImageSourceGetType(check), (__bridge CFStringRef)UTTypeJPEG.identifier));
      NSDictionary *output = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(check, 0, NULL));
      for (id key in @[(id)kCGImagePropertyPixelWidth, (id)kCGImagePropertyPixelHeight]) assert([output[key] isEqual:input[key]]);
      assert([(output[(id)kCGImagePropertyOrientation] ?: @1) isEqual:(input[(id)kCGImagePropertyOrientation] ?: @1)]);
      CGImageSourceRef full = check;
      CGImageRef decoded = CGImageSourceCreateImageAtIndex(full, 0, NULL); assert(decoded); CGImageRelease(decoded);
      CFRelease(check);
    }
    LBEditorRemoveFile(file);
    copy = LBEditorCopy(original, original.lastPathComponent, &error);
    assert(copy); [progress cancel]; error = nil;
    assert(!LBEditorPrepareCopy(copy, original.lastPathComponent, @"public.data", photo, progress, &metadata, &error));
    assert(error && ![NSFileManager.defaultManager fileExistsAtPath:copy.path]);
    assert([[NSData dataWithContentsOfURL:original] isEqual:before]);
  }
}

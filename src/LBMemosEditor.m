// Independent UIKit Markdown composer; no MoeMemos source is incorporated.
#import "LBMemos.h"
#import "LBLayout.h"
#import "LBNavigationController.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>

static const unsigned long long LBEditorFileLimit = 32ULL * 1024ULL * 1024ULL;
static NSString *LBEditorString(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSNumber *LBEditorID(id value) {
  return [value isKindOfClass:NSNumber.class] && [value longLongValue] > 0 ? value : nil;
}
static NSString *LBEditorVisibility(id value) {
  return [@[@"PRIVATE", @"PROTECTED", @"PUBLIC"] containsObject:value ?: @""] ? value : @"PRIVATE";
}
static NSString *LBEditorFilename(NSString *name) {
  NSMutableString *safe = [NSMutableString new];
  NSMutableCharacterSet *allowed = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
  [allowed addCharactersInString:@"._- ()"];
  NSString *leaf = LBEditorString(name).lastPathComponent;
  for (NSUInteger i = 0; i < MIN(leaf.length, (NSUInteger)120); i++) {
    unichar c = [leaf characterAtIndex:i];
    [safe appendFormat:@"%C", (unichar)([allowed characterIsMember:c] ? c : '_')];
  }
  while ([safe hasPrefix:@"."]) [safe deleteCharactersInRange:NSMakeRange(0, 1)];
  return safe.length ? safe : @"attachment";
}
// HEIF identifiers are explicit fallbacks: some providers expose public.heif
// without a declared UTType (and extension lookups can return dynamic types).
static NSString *LBEditorHEIFExtension(NSString *identifier) {
  NSString *value = identifier.lowercaseString;
  if ([value isEqual:@"public.heic"]) return @"heic";
  if ([value isEqual:@"public.heif"]) return @"heif";
  return nil;
}
static NSString *LBEditorImportIdentifier(NSString *identifier, NSString *extension) {
  if (LBEditorHEIFExtension(identifier)) return identifier.lowercaseString;
  UTType *type = identifier.length ? [UTType typeWithIdentifier:identifier] : nil;
  if (type.isDeclared && type.preferredMIMEType.length && ![type isEqual:UTTypeItem] && ![type isEqual:UTTypeData] && ![type isEqual:UTTypeImage]) return type.identifier;
  NSString *ext = extension.lowercaseString;
  if ([ext isEqual:@"heic"] || [ext isEqual:@"heif"]) return [@"public." stringByAppendingString:ext];
  return [UTType typeWithFilenameExtension:ext].identifier ?: identifier;
}
static NSDictionary *LBEditorImportMetadata(NSURL *file, NSString *name, NSString *identifier) {
  // Inspect only our bounded private copy. ImageIO identifies the container;
  // it never writes/re-encodes the original bytes. Payload wins over hints.
  CGImageSourceRef source = file ? CGImageSourceCreateWithURL((__bridge CFURLRef)file, NULL) : NULL;
  NSString *actual = source ? (__bridge NSString *)CGImageSourceGetType(source) : nil;
  if (actual.length) identifier = actual;
  identifier = LBEditorImportIdentifier(identifier, name.pathExtension);
  UTType *type = identifier.length ? [UTType typeWithIdentifier:identifier] : nil;
  NSString *heif = LBEditorHEIFExtension(identifier);
  NSString *mime = heif ? [@"image/" stringByAppendingString:heif] : type.preferredMIMEType;
  BOOL jpeg = [identifier isEqual:UTTypeJPEG.identifier];
  NSString *ext = jpeg ? @"jpg" : (heif ?: type.preferredFilenameExtension);
  NSString *safe = LBEditorFilename(name);
  UTType *namedType = [UTType typeWithFilenameExtension:safe.pathExtension.lowercaseString];
  // Repair stale hints using the actual payload, and canonicalize JPEG to .jpg.
  // Reserve suffix space even when the sanitized name reaches 120 characters.
  if (ext.length && (jpeg || heif || !safe.pathExtension.length ||
      (actual.length && ![namedType.preferredMIMEType isEqual:mime]))) {
    NSString *stem = safe.stringByDeletingPathExtension;
    if (stem.length > 120 - ext.length - 1) stem = [stem substringToIndex:120 - ext.length - 1];
    safe = [(stem.length ? stem : @"attachment") stringByAppendingPathExtension:ext];
  }
  NSDictionary *metadata = @{@"filename":safe, @"type":mime.length ? mime : @"application/octet-stream"};
  if (source) CFRelease(source);
  return metadata;
}
static NSString *LBEditorProviderIdentifier(NSItemProvider *provider) {
  NSString *fallback = nil, *generic = nil;
  // Ask Photos for its compatible JPEG representation first; videos still
  // choose a movie representation and are never transcoded here.
  for (NSString *candidate in provider.registeredTypeIdentifiers) {
    if ([[candidate lowercaseString] isEqual:UTTypeJPEG.identifier]) return candidate;
  }
  for (NSString *candidate in provider.registeredTypeIdentifiers) {
    UTType *type = [UTType typeWithIdentifier:candidate];
    if (![type conformsToType:UTTypeImage] && ![type conformsToType:UTTypeMovie]) continue;
    if (!generic) generic = candidate;
    if (!fallback && type.isDeclared && ![type isEqual:UTTypeImage] && ![type isEqual:UTTypeMovie]) fallback = candidate;
  }
  return fallback ?: generic;
}
static NSError *LBEditorError(NSString *message) {
  return [NSError errorWithDomain:@"LBMemosEditor" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSURL *LBEditorDirectory(void) {
  NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
  return [support URLByAppendingPathComponent:@"MemosEditorFiles" isDirectory:YES];
}
// Only our private, regular, non-symlink files may be restored from a draft.
static BOOL LBEditorOwnFile(NSURL *url) {
  if (!url.isFileURL) return NO;
  NSString *root = LBEditorDirectory().URLByStandardizingPath.path;
  NSString *parent = url.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByStandardizingPath.path;
  if (![parent isEqual:root]) return NO;
  NSString *resolvedRoot = LBEditorDirectory().URLByResolvingSymlinksInPath.path;
  if (![url.URLByResolvingSymlinksInPath.path hasPrefix:[resolvedRoot stringByAppendingString:@"/"]]) return NO;
  NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
  return [attrs[NSFileType] isEqual:NSFileTypeRegular] && [attrs[NSFileSize] unsignedLongLongValue] <= LBEditorFileLimit;
}
static NSURL *LBEditorCopy(NSURL *source, NSString *filename, NSError **error) {
  BOOL scoped = [source startAccessingSecurityScopedResource];
  __block NSURL *result = nil;
  NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
  __block NSError *failure = nil;
  [coordinator coordinateReadingItemAtURL:source options:NSFileCoordinatorReadingWithoutChanges error:&failure byAccessor:^(NSURL *readURL) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:readURL.path error:&failure];
    if (!attrs) return;
    if (![attrs[NSFileType] isEqual:NSFileTypeRegular]) { failure = LBEditorError(@"请选择普通文件，不能导入文件夹或符号链接。"); return; }
    if ([attrs[NSFileSize] unsignedLongLongValue] > LBEditorFileLimit) { failure = LBEditorError(@"单个附件不能超过 32 MiB。"); return; }
    NSURL *dir = [LBEditorDirectory() URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSDictionary *protection = @{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication};
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:protection error:&failure]) return;
    NSURL *dest = [dir URLByAppendingPathComponent:LBEditorFilename(filename)];
    if (![NSFileManager.defaultManager copyItemAtURL:readURL toURL:dest error:&failure] ||
        ![NSFileManager.defaultManager setAttributes:protection ofItemAtPath:dest.path error:&failure] || !LBEditorOwnFile(dest)) {
      [NSFileManager.defaultManager removeItemAtURL:dir error:nil];
      if (!failure) failure = LBEditorError(@"附件复制后无效或超过 32 MiB。");
      return;
    }
    [dir setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    result = dest;
  }];
  if (scoped) [source stopAccessingSecurityScopedResource];
  if (!result && error) *error = failure ?: LBEditorError(@"无法读取附件，请重新选择。");
  return result;
}
static void LBEditorRemoveFile(NSURL *url) {
  if (LBEditorOwnFile(url)) [NSFileManager.defaultManager removeItemAtURL:url.URLByDeletingLastPathComponent error:nil];
}
// One process-wide lane bounds full-resolution decode/encode memory even when
// ten providers finish together or a second editor is opened. Copy provider
// URLs BEFORE entering this queue: their lifetime ends with their callback.
static dispatch_queue_t LBEditorPreparationQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ queue = dispatch_queue_create("longblog.editor.jpeg", DISPATCH_QUEUE_SERIAL); });
  return queue;
}
// Consumes our private copy on failure/cancellation. This is called only for
// NEW imports, never restored drafts, existing resource IDs or upload retries.
static NSURL *LBEditorPrepareCopy(NSURL *copy, NSString *name, NSString *identifier,
                                 BOOL photo, NSProgress *progress, NSDictionary **metadata, NSError **error) {
  if (metadata) *metadata = nil;
  if (!copy) return nil;
  NSError *failure = nil;
  NSURL *result = copy;
  NSDictionary *options = @{(id)kCGImageSourceShouldCache:@NO};
  CGImageSourceRef source = NULL;
  if (!progress.cancelled) source = CGImageSourceCreateWithURL((__bridge CFURLRef)copy, (__bridge CFDictionaryRef)options);
  NSString *actual = source ? (__bridge NSString *)CGImageSourceGetType(source) : nil;
  // For Files, only actual HEIC/HEIF is converted; other files retain bytes.
  // Do not trust a .jpg hint over HEIF bytes, nor a .heic hint over PNG bytes.
  BOOL heif = LBEditorHEIFExtension(actual) != nil;
  BOOL hintedHEIF = !actual && LBEditorHEIFExtension(LBEditorImportIdentifier(identifier, name.pathExtension)) != nil;
  BOOL animated = source && CGImageSourceGetCount(source) > 1 &&
    ([actual isEqual:UTTypeGIF.identifier] || [actual isEqual:UTTypePNG.identifier]);
  BOOL convert = heif || hintedHEIF || (photo && source && !animated && ![actual isEqual:UTTypeJPEG.identifier]);
  if (!progress.cancelled && convert) {
    if (!source || !CGImageSourceGetCount(source)) {
      failure = LBEditorError(@"无法解码照片为 JPEG，请重新选择。");
    } else {
      // Use the primary HEIF image, not an auxiliary depth/thumbnail item.
      // Carry full-resolution dimensions and EXIF orientation without resizing.
      size_t index = CGImageSourceGetPrimaryImageIndex(source);
      NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
      NSNumber *orientation = properties[(id)kCGImagePropertyOrientation] ?: @1;
      NSURL *jpeg = [copy.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"jpg"]];
      NSDictionary *protection = @{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication};
      BOOL created = [NSFileManager.defaultManager createFileAtPath:jpeg.path contents:nil attributes:protection];
      CGImageDestinationRef destination = created ? CGImageDestinationCreateWithURL((__bridge CFURLRef)jpeg, (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL) : NULL;
      BOOL encoded = NO;
      if (destination) {
        CGImageDestinationAddImageFromSource(destination, source, index, (__bridge CFDictionaryRef)@{
          (id)kCGImageDestinationLossyCompressionQuality:@1.0,
          (id)kCGImagePropertyOrientation:orientation});
        encoded = CGImageDestinationFinalize(destination);
        CFRelease(destination);
      }
      NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:jpeg.path error:nil];
      if ([attrs[NSFileSize] unsignedLongLongValue] > LBEditorFileLimit) {
        failure = LBEditorError(@"JPEG 转换后超过 32 MiB；不会缩小照片，请选择较小的原图。");
      } else if (!encoded || ![attrs[NSFileSize] unsignedLongLongValue] ||
                 ![NSFileManager.defaultManager setAttributes:protection ofItemAtPath:jpeg.path error:&failure] || !LBEditorOwnFile(jpeg)) {
        if (!failure) failure = LBEditorError(@"无法编码照片为 JPEG，请重新选择。");
      } else {
        // Validate the actual output, resolution and orientation, not merely
        // its suffix/MIME. JPEG inputs bypass this encoder entirely.
        CGImageSourceRef check = CGImageSourceCreateWithURL((__bridge CFURLRef)jpeg, (__bridge CFDictionaryRef)options);
        NSDictionary *output = check ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(check, 0, NULL)) : nil;
        BOOL valid = check && CFEqual(CGImageSourceGetType(check), (__bridge CFStringRef)UTTypeJPEG.identifier) &&
          [output[(id)kCGImagePropertyPixelWidth] isEqual:properties[(id)kCGImagePropertyPixelWidth]] &&
          [output[(id)kCGImagePropertyPixelHeight] isEqual:properties[(id)kCGImagePropertyPixelHeight]] &&
          [(output[(id)kCGImagePropertyOrientation] ?: @1) isEqual:orientation];
        if (check) CFRelease(check);
        if (!valid) failure = LBEditorError(@"JPEG 转换未保留原图尺寸或方向，请重新选择。");
        else result = jpeg;
      }
    }
  } else if (!progress.cancelled && photo && !source &&
             [[UTType typeWithIdentifier:identifier] conformsToType:UTTypeImage]) {
    failure = LBEditorError(@"无法读取照片内容，请重新选择。");
  }
  if (source) CFRelease(source);
  if (failure || progress.cancelled) {
    // Remove the directory through the original bounded copy, including any
    // partially written or oversized JPEG which is not itself an OwnFile.
    LBEditorRemoveFile(copy);
    if (error) *error = failure ?: LBEditorError(@"已取消导入。");
    return nil;
  }
  if (![result isEqual:copy]) [NSFileManager.defaultManager removeItemAtURL:copy error:nil];
  if (metadata) *metadata = LBEditorImportMetadata(result, name, identifier);
  return result;
}
static UIImage *LBEditorThumbnail(NSURL *url) {
  if (!url || !LBEditorOwnFile(url)) return nil;
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
  if (!source) return nil;
  CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
    (id)kCGImageSourceCreateThumbnailFromImageAlways:@YES, (id)kCGImageSourceThumbnailMaxPixelSize:@96,
    (id)kCGImageSourceCreateThumbnailWithTransform:@YES});
  UIImage *thumb = image ? [UIImage imageWithCGImage:image] : nil;
  if (image) CGImageRelease(image);
  CFRelease(source);
  return thumb;
}

// Own the effect view's public geometry, not a masked ancestor. UIGlassEffect
// may reconfigure its corners on keyboard/transition layouts; enforce the capsule
// after super lays out the effect, with no implicit Core Animation animations.
@interface LBEditorToolbarGlass : UIVisualEffectView
@end
@implementation LBEditorToolbarGlass {
  CGSize _lastGlassSize;
}
- (void)layoutSubviews {
  [super layoutSubviews];
  CGSize size = self.bounds.size;
  if (size.width <= 0 || size.height <= 0) return;
  CGFloat radius = size.height / 2.0;
  if (CGSizeEqualToSize(_lastGlassSize, size) && self.clipsToBounds &&
      fabs(self.layer.cornerRadius - radius) < 0.01) return;
  _lastGlassSize = size;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
  self.layer.cornerCurve = kCACornerCurveContinuous;
  self.layer.cornerRadius = radius;
  self.clipsToBounds = YES;
  [CATransaction commit];
}
@end

@interface LBEditorAttachment : NSObject
@property(nonatomic, copy) NSString *key, *filename, *type, *state, *failure;
@property(nonatomic, strong) NSURL *file;
@property(nonatomic, strong) NSNumber *resourceID;
@property(nonatomic, copy) NSDictionary *resource;
@property(nonatomic, strong) NSProgress *importProgress, *providerProgress;
@property(nonatomic, strong) UIImage *thumbnail;
@property(nonatomic) double fraction;
@end
@implementation LBEditorAttachment
- (instancetype)init {
  if ((self = [super init])) { _key = NSUUID.UUID.UUIDString; _filename = @"附件"; _type = @"application/octet-stream"; _state = @"ready"; }
  return self;
}
@end

@interface LBMemosEditor () <UITextViewDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@end
@implementation LBMemosEditor {
  NSDictionary *_original;
  void (^_saved)(NSDictionary *);
  NSUInteger _generation, _importEpoch;
  NSMutableArray<LBEditorAttachment *> *_attachments;
  UITextView *_text;
  UILabel *_placeholder, *_status;
  UIButton *_visibilityButton;
  UIScrollView *_strip;
  UIStackView *_attachmentStack, *_dock;
  LBEditorToolbarGlass *_toolbar;
  UIButton *_attach, *_files, *_preview, *_stop;
  CGSize _lastTextSize;
  BOOL _requestedFocus;
  UIBarButtonItem *_saveButton, *_closeButton;
  NSArray<UIControl *> *_formatButtons;
  NSString *_visibility, *_initialText, *_initialVisibility;
  NSArray<NSNumber *> *_initialIDs;
  NSURLSessionTask *_uploadTask;
  BOOL _saving, _finished, _ownsDraft, _draftSaved, _localFilesPersisted, _unknownOutcome, _cancelingUpload;
  NSInteger _pendingImports;
}
- (instancetype)initWithMemo:(NSDictionary *)memo saved:(void (^)(NSDictionary *))saved {
  if ((self = [super init])) {
    // JSON round trip pins nested resources too; never mutate the conflict snapshot.
    NSData *data = memo ? [NSJSONSerialization dataWithJSONObject:memo options:0 error:nil] : nil;
    _original = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    _saved = [saved copy]; _generation = LBMemosClient.shared.generation;
    _attachments = [NSMutableArray new];
    _initialText = LBEditorString(_original[@"content"]);
    _initialVisibility = LBEditorVisibility(_original[@"visibility"]);
    _visibility = _initialVisibility;
    for (id resource in _original[@"resourceList"]) {
      if (![resource isKindOfClass:NSDictionary.class] || !LBEditorID(resource[@"id"])) continue;
      LBEditorAttachment *a = [LBEditorAttachment new]; a.resource = resource; a.resourceID = resource[@"id"];
      a.filename = LBEditorString(resource[@"filename"]); if (!a.filename.length) a.filename = @"已有附件";
      a.type = LBEditorString(resource[@"type"]); [_attachments addObject:a];
    }
    _initialIDs = [self resourceIDs];
  }
  return self;
}
- (void)dealloc {
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [_uploadTask cancel];
  for (LBEditorAttachment *a in _attachments) { [a.importProgress cancel]; [a.providerProgress cancel]; }
}
- (BOOL)accountCurrent { return _generation == LBMemosClient.shared.generation; }
- (NSNumber *)memoID { return LBEditorID(_original[@"id"]); }
- (NSArray<NSNumber *> *)resourceIDs {
  NSMutableOrderedSet *ids = [NSMutableOrderedSet new];
  for (LBEditorAttachment *a in _attachments) if (a.resourceID) [ids addObject:a.resourceID];
  return ids.array;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = _original ? @"编辑 Memos" : @"写 Memos";
  self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
  self.modalInPresentation = YES;
  self.navigationController.modalInPresentation = YES;
  _closeButton = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(closeEditor)];
  _saveButton = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleProminent target:self action:@selector(savePressed)];
  self.navigationItem.leftBarButtonItem = _closeButton; self.navigationItem.rightBarButtonItem = _saveButton;
  self.view.backgroundColor = LBTheme.paper;
  LBAuroraView *background = [[LBAuroraView alloc] initWithFrame:self.view.bounds];
  background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight; [self.view addSubview:background];
  _visibilityButton = [self button:@"" icon:@"lock" action:NULL];
  _visibilityButton.translatesAutoresizingMaskIntoConstraints = NO;
  _visibilityButton.showsMenuAsPrimaryAction = YES;
  _visibilityButton.accessibilityIdentifier = @"memos.editor.visibility";
  _visibilityButton.accessibilityHint = @"选择仅自己、登录可见或公开；不会立即发布";
  [self.view addSubview:_visibilityButton];
  // One keyboard geometry owner. No inputAccessoryView or keyboard-frame offsets.
  _dock = [UIStackView new]; _dock.axis = UILayoutConstraintAxisVertical; _dock.spacing = 8;
  _dock.translatesAutoresizingMaskIntoConstraints = NO; _dock.accessibilityIdentifier = @"memos.editor.dock";
  [self.view addSubview:_dock];
  _status = [UILabel new]; _status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  _status.adjustsFontForContentSizeCategory = YES; _status.textColor = LBTheme.muted;
  _status.numberOfLines = 2; _status.accessibilityIdentifier = @"memos.editor.status";
  [_dock addArrangedSubview:_status];
  _strip = [UIScrollView new]; _strip.translatesAutoresizingMaskIntoConstraints = NO; _strip.showsHorizontalScrollIndicator = NO;
  _strip.accessibilityIdentifier = @"memos.editor.attachments";
  [_dock addArrangedSubview:_strip];
  NSLayoutConstraint *stripHeight = [_strip.heightAnchor constraintEqualToConstant:104];
  stripHeight.priority = UILayoutPriorityDefaultHigh; stripHeight.active = YES;
  [_dock addArrangedSubview:[self writingToolbar]];
  _attachmentStack = [UIStackView new]; _attachmentStack.axis = UILayoutConstraintAxisHorizontal; _attachmentStack.spacing = 8;
  _attachmentStack.translatesAutoresizingMaskIntoConstraints = NO; [_strip addSubview:_attachmentStack];
  _text = [UITextView new]; _text.translatesAutoresizingMaskIntoConstraints = NO; _text.backgroundColor = UIColor.clearColor;
  _text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; _text.adjustsFontForContentSizeCategory = YES;
  _text.textColor = LBTheme.ink; _text.tintColor = LBTheme.accent; _text.delegate = self;
  _text.textContainerInset = UIEdgeInsetsMake(12, 16, 16, 16); _text.textContainer.lineFragmentPadding = 0;
  _text.contentInset = UIEdgeInsetsMake(0, 0, 72, 0); _text.automaticallyAdjustsScrollIndicatorInsets = NO;
  _text.scrollIndicatorInsets = UIEdgeInsetsZero;
  _text.alwaysBounceVertical = YES; _text.showsVerticalScrollIndicator = YES;
  _text.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  _text.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive; _text.accessibilityLabel = @"Markdown 正文";
  _text.accessibilityIdentifier = @"memos.editor.content";
  _text.text = _initialText; [self.view addSubview:_text];
  _placeholder = [UILabel new]; _placeholder.text = @"记录此刻… 支持 Markdown 和 #标签";
  _placeholder.font = _text.font; _placeholder.textColor = LBTheme.muted; _placeholder.numberOfLines = 0;
  _placeholder.userInteractionEnabled = NO; _placeholder.translatesAutoresizingMaskIntoConstraints = NO; [_text addSubview:_placeholder];
  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [_visibilityButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
    [_visibilityButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [_visibilityButton.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16],
    [_visibilityButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    [_dock.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [_dock.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    [_dock.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-8],
    [_attachmentStack.topAnchor constraintEqualToAnchor:_strip.contentLayoutGuide.topAnchor], [_attachmentStack.bottomAnchor constraintEqualToAnchor:_strip.contentLayoutGuide.bottomAnchor],
    [_attachmentStack.leadingAnchor constraintEqualToAnchor:_strip.contentLayoutGuide.leadingAnchor], [_attachmentStack.trailingAnchor constraintEqualToAnchor:_strip.contentLayoutGuide.trailingAnchor],
    [_attachmentStack.heightAnchor constraintEqualToAnchor:_strip.frameLayoutGuide.heightAnchor],
    [_text.topAnchor constraintEqualToAnchor:_visibilityButton.bottomAnchor], [_text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [_text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor], [_text.bottomAnchor constraintEqualToAnchor:_dock.topAnchor constant:-8],
    [_placeholder.topAnchor constraintEqualToAnchor:_text.contentLayoutGuide.topAnchor constant:12],
    [_placeholder.leadingAnchor constraintEqualToAnchor:_text.frameLayoutGuide.leadingAnchor constant:16],
    [_placeholder.widthAnchor constraintEqualToAnchor:_text.frameLayoutGuide.widthAnchor constant:-32]
  ]];
  [self restoreDraft]; [self visibilityChanged]; [self renderAttachments]; [self refreshControls];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(connectionChanged:) name:LBMemosDidChange object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgrounding:) name:UIApplicationWillResignActiveNotification object:nil];
}
- (UIButton *)button:(NSString *)title icon:(NSString *)icon action:(SEL)action {
  UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration]; config.title = title;
  config.image = [UIImage systemImageNamed:icon]; config.imagePadding = 5; config.baseForegroundColor = LBTheme.accent;
  UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
  if (action) [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside]; return button;
}
- (UIButton *)toolButton:(NSString *)title icon:(NSString *)icon action:(SEL)action {
  UIButton *button = [self button:@"" icon:icon action:action];
  button.accessibilityLabel = title; button.toolTip = title;
  NSLayoutConstraint *width = [button.widthAnchor constraintGreaterThanOrEqualToConstant:44];
  width.priority = 999; width.active = YES; // Hidden arranged buttons must be allowed to collapse.
  [button.heightAnchor constraintEqualToConstant:44].active = YES;
  return button;
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (!_requestedFocus) { _requestedFocus = YES; if (!_saving && [self accountCurrent]) [_text becomeFirstResponder]; }
}
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  [_toolbar setNeedsLayout]; [_toolbar layoutIfNeeded];
  // Preserve a scrolled reading position; reveal the caret only on viewport changes.
  if (!CGSizeEqualToSize(_lastTextSize, _text.bounds.size)) {
    _lastTextSize = _text.bounds.size;
    if (_text.isFirstResponder && !_text.markedTextRange) [_text scrollRangeToVisible:_text.selectedRange];
  }
}
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated]; self.presentationController.delegate = self; self.navigationController.presentationController.delegate = self;
  [self refreshControls];
  // Preview return uses the same effect instance and keyboard-guide constraints.
  [_toolbar setNeedsLayout]; [self.view setNeedsLayout];
}
- (void)presentationControllerDidAttemptToDismiss:(UIPresentationController *)presentationController { [self closeEditor]; }
- (void)backgrounding:(NSNotification *)note { if (!_finished && [self accountCurrent]) [self persistDraft]; }
- (void)connectionChanged:(NSNotification *)note {
  if (![self accountCurrent]) {
    _importEpoch++; _pendingImports = 0; [_uploadTask cancel]; _uploadTask = nil; _saving = NO;
    for (LBEditorAttachment *a in _attachments) { [a.importProgress cancel]; [a.providerProgress cancel]; if ([a.state isEqual:@"importing"] || [a.state isEqual:@"uploading"]) { a.state = @"failed"; a.failure = @"连接已变更"; } }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(persistDraft) object:nil];
    [self renderAttachments];
  }
  [self refreshControls];
}
- (void)refreshControls {
  BOOL current = [self accountCurrent];
  _text.editable = !_saving; _visibilityButton.enabled = !_saving && current;
  _attach.enabled = !_saving && current; _files.enabled = !_saving && current;
  _preview.enabled = !_saving && current; _closeButton.enabled = !_saving;
  _saveButton.enabled = !_saving && current && !_pendingImports;
  for (UIControl *button in _formatButtons) button.enabled = !_saving;
  _stop.hidden = !_saving || !_uploadTask; _stop.enabled = !_cancelingUpload;
  _saveButton.title = _saving ? @"保存中…" : @"保存";
  _placeholder.hidden = _text.text.length > 0;
  if (!current) _status.text = @"连接或账号已改变：请复制正文后关闭；不会将旧草稿写入新账号。";
  else if (_saving) _status.text = _uploadTask ? @"正在上传附件；可取消上传，正文与文件会保留。" : @"正在保存，请勿重复提交。";
  else if (_pendingImports) _status.text = [NSString stringWithFormat:@"正在导入 %ld 个附件… 完成后才可保存。", (long)_pendingImports];
  else if (_unknownOutcome) _status.text = @"上次保存结果未知。请先检查时间线，避免重试创建重复记录。";
  else if (_draftSaved) _status.text = _localFilesPersisted ? @"私密草稿已存本机 · 未发布" : @"正文与已上传附件已存草稿；待上传文件仅本次编辑保留。";
  else _status.text = nil;
  _status.hidden = !_status.text.length;
}

#pragma mark - Markdown editing
- (UIView *)writingToolbar {
  UIGlassEffect *glass = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
  glass.interactive = YES; glass.tintColor = [LBTheme.surface colorWithAlphaComponent:0.3];
  LBEditorToolbarGlass *capsule = [[LBEditorToolbarGlass alloc] initWithEffect:glass];
  capsule.translatesAutoresizingMaskIntoConstraints = NO;
  capsule.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
  _toolbar = capsule;
  capsule.accessibilityIdentifier = @"memos.editor.tools";
  [capsule.heightAnchor constraintEqualToConstant:52].active = YES;
  UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.showsHorizontalScrollIndicator = NO; [capsule.contentView addSubview:scroll];
  UIStackView *stack = [UIStackView new]; stack.distribution = UIStackViewDistributionFillEqually;
  stack.translatesAutoresizingMaskIntoConstraints = NO; [scroll addSubview:stack];
  _attach = [self toolButton:@"照片或视频" icon:@"photo.on.rectangle" action:@selector(choosePhotos)];
  _attach.accessibilityHint = @"每次最多 10 个，每个不超过 32 MiB";
  _files = [self toolButton:@"文件、音频及其他" icon:@"doc.badge.plus" action:@selector(chooseFiles)];
  _files.accessibilityHint = _attach.accessibilityHint;
  UIButton *tag = [self toolButton:@"插入标签" icon:@"number" action:@selector(formatPressed:)]; tag.tag = 6;
  UIButton *format = [self toolButton:@"Markdown 格式" icon:@"textformat" action:NULL];
  format.showsMenuAsPrimaryAction = YES;
  NSArray *titles = @[@"粗体", @"标题", @"列表", @"待办", @"代码", @"链接", @"标签", @"收起"];
  NSArray *symbols = @[@"bold", @"textformat.size", @"list.bullet", @"checklist", @"chevron.left.forwardslash.chevron.right", @"link"];
  NSMutableArray *actions = [NSMutableArray new];
  __weak typeof(self) weakSelf = self;
  for (NSUInteger i = 0; i < symbols.count; i++) {
    UIAction *action = [UIAction actionWithTitle:titles[i] image:[UIImage systemImageNamed:symbols[i]] identifier:nil handler:^(UIAction *item) {
      UIButton *sender = [UIButton buttonWithType:UIButtonTypeSystem]; sender.tag = (NSInteger)i;
      [weakSelf formatPressed:sender];
    }]; [actions addObject:action];
  }
  format.menu = [UIMenu menuWithTitle:@"Markdown" children:actions];
  _preview = [self toolButton:@"预览" icon:@"eye" action:@selector(showPreview)];
  UIButton *dismiss = [self toolButton:@"收起键盘" icon:@"keyboard.chevron.compact.down" action:@selector(formatPressed:)]; dismiss.tag = 7;
  _stop = [self toolButton:@"取消上传" icon:@"stop.circle" action:@selector(stopUpload)]; _stop.hidden = YES;
  for (UIButton *button in @[_stop, _attach, _files, tag, format, _preview, dismiss]) [stack addArrangedSubview:button];
  _formatButtons = @[tag, format, dismiss];
  [NSLayoutConstraint activateConstraints:@[
    [scroll.leadingAnchor constraintEqualToAnchor:capsule.contentView.leadingAnchor constant:4],
    [scroll.trailingAnchor constraintEqualToAnchor:capsule.contentView.trailingAnchor constant:-4],
    [scroll.topAnchor constraintEqualToAnchor:capsule.contentView.topAnchor constant:4],
    [scroll.bottomAnchor constraintEqualToAnchor:capsule.contentView.bottomAnchor constant:-4],
    [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
    [stack.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
    [stack.widthAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
  ]]; return capsule;
}
- (void)formatPressed:(UIButton *)sender {
  if (_saving) return;
  [_text unmarkText];
  if (sender.tag == 7) { [_text resignFirstResponder]; return; }
  NSString *source = _text.text ?: @"";
  NSRange range = _text.selectedRange;
  if (range.location == NSNotFound || NSMaxRange(range) > source.length) range = NSMakeRange(source.length, 0);
  NSString *selection = [source substringWithRange:range];
  NSString *replacement = @""; NSRange selected = NSMakeRange(0, 0);
  if (sender.tag == 0 || sender.tag == 4) {
    NSString *mark = sender.tag == 0 ? @"**" : ([selection containsString:@"\n"] ? @"```\n" : @"`");
    NSString *tail = [mark isEqual:@"```\n"] ? @"\n```" : mark;
    replacement = [NSString stringWithFormat:@"%@%@%@", mark, selection, tail]; selected = NSMakeRange(mark.length, selection.length);
  } else if (sender.tag >= 1 && sender.tag <= 3) {
    range = [source lineRangeForRange:range]; selection = [source substringWithRange:range];
    NSString *prefix = @[@"", @"## ", @"- ", @"- [ ] "][sender.tag];
    NSMutableArray *lines = [[selection componentsSeparatedByString:@"\n"] mutableCopy];
    for (NSUInteger i = 0; i < lines.count; i++) {
      if (i == lines.count - 1 && i > 0 && ![lines[i] length]) continue;
      lines[i] = [prefix stringByAppendingString:lines[i]];
    }
    replacement = [lines componentsJoinedByString:@"\n"]; selected = NSMakeRange(prefix.length, MAX((NSInteger)replacement.length - (NSInteger)prefix.length, 0));
  } else if (sender.tag == 5) {
    NSString *label = selection.length ? selection : @"链接文字";
    replacement = [NSString stringWithFormat:@"[%@](https://)", label]; selected = NSMakeRange(label.length + 3, 8);
  } else {
    NSString *tag = selection.length ? selection : @"标签";
    BOOL space = range.location && ![NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[source characterAtIndex:range.location - 1]];
    replacement = [NSString stringWithFormat:@"%@#%@ ", space ? @" " : @"", tag]; selected = NSMakeRange(space ? 2 : 1, tag.length);
  }
  [_text.undoManager beginUndoGrouping];
  UITextPosition *start = [_text positionFromPosition:_text.beginningOfDocument offset:(NSInteger)range.location];
  UITextPosition *end = [_text positionFromPosition:start offset:(NSInteger)range.length];
  [_text replaceRange:[_text textRangeFromPosition:start toPosition:end] withText:replacement];
  [_text.undoManager endUndoGrouping];
  _text.selectedRange = NSMakeRange(range.location + selected.location, selected.length); [_text becomeFirstResponder];
  [self textViewDidChange:_text];
}
- (void)textViewDidChange:(UITextView *)textView { [self changed]; }
- (void)textViewDidEndEditing:(UITextView *)textView { if (!_finished && !_saving) [self persistDraft]; }
- (void)visibilityChanged {
  NSArray *values = @[@"PRIVATE", @"PROTECTED", @"PUBLIC"];
  NSArray *titles = @[@"仅自己", @"登录可见", @"公开"];
  NSArray *symbols = @[@"lock", @"person.2", @"globe"];
  NSUInteger selected = [values indexOfObject:_visibility];
  UIButtonConfiguration *config = _visibilityButton.configuration;
  config.title = titles[selected]; config.image = [UIImage systemImageNamed:symbols[selected]];
  config.baseForegroundColor = LBTheme.muted;
  config.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:13];
  config.contentInsets = NSDirectionalEdgeInsetsMake(4, 0, 4, 8); _visibilityButton.configuration = config;
  _visibilityButton.accessibilityLabel = [@"可见范围：" stringByAppendingString:titles[selected]];
  NSMutableArray *actions = [NSMutableArray new];
  __weak typeof(self) weakSelf = self;
  for (NSUInteger i = 0; i < values.count; i++) {
    UIAction *action = [UIAction actionWithTitle:titles[i] image:[UIImage systemImageNamed:symbols[i]] identifier:nil handler:^(UIAction *item) {
      typeof(self) self = weakSelf;
      if (!self || self->_saving || ![self accountCurrent]) return;
      self->_visibility = values[i]; [self visibilityChanged]; [self changed];
    }];
    action.state = i == selected ? UIMenuElementStateOn : UIMenuElementStateOff; [actions addObject:action];
  }
  _visibilityButton.menu = [UIMenu menuWithTitle:@"可见范围" children:actions];
}
- (BOOL)hasContentChanges {
  if (![(_text.text ?: @"") isEqual:_initialText] ||
      ![_visibility isEqual:_initialVisibility] ||
      ![[self resourceIDs] isEqual:_initialIDs]) return YES;
  // Pending, failed and recovered missing files are still author content. An
  // uploaded ID replaces the local file's identity; progress/selection do not.
  for (LBEditorAttachment *a in _attachments) if (!a.resourceID) return YES;
  return NO;
}
- (void)clearUnchangedDraft {
  if (!_ownsDraft || _unknownOutcome || ![self accountCurrent]) return;
  [LBMemosClient.shared removeDraftForMemo:[self memoID]];
  _ownsDraft = NO; _draftSaved = NO; _localFilesPersisted = NO;
}
- (void)changed {
  _draftSaved = NO;
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(persistDraft) object:nil];
  if (![self hasContentChanges] && !_unknownOutcome) {
    [self clearUnchangedDraft]; [self refreshControls]; return;
  }
  [self refreshControls];
  [self performSelector:@selector(persistDraft) withObject:nil afterDelay:1.0];
}
- (void)showPreview {
  if (_saving || ![self accountCurrent]) return;
  [_text unmarkText]; [self.view endEditing:YES];
  NSMutableArray *resources = [NSMutableArray new];
  for (LBEditorAttachment *a in _attachments) if (a.resource) [resources addObject:a.resource];
  NSMutableDictionary *memo = [@{@"id": [self memoID] ?: @0, @"content":_text.text ?: @"", @"visibility":_visibility, @"resourceList":resources} mutableCopy];
  // Retain a real creation date when editing; a new draft has no publication date.
  if ([_original[@"createdTs"] isKindOfClass:NSNumber.class]) memo[@"createdTs"] = _original[@"createdTs"];
  UIViewController *preview = LBMemoMarkdownPreview(memo);
  if (!preview) return;
  // Same sheet interaction as the article preview: swipe down or 完成 returns to writing.
  LBNavigationController *nav = [[LBNavigationController alloc] initWithRootViewController:preview];
  [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Protected account-scoped drafts
- (void)restoreDraft {
  if (![self accountCurrent]) return;
  NSDictionary *draft = [LBMemosClient.shared draftForMemo:[self memoID]];
  if (![draft isKindOfClass:NSDictionary.class]) return;
  if (_original) {
    NSDictionary *snapshot = draft[@"originalSnapshot"];
    if (![snapshot isKindOfClass:NSDictionary.class] || ![snapshot[@"id"] isEqual:_original[@"id"]]) {
      self.navigationItem.prompt = @"旧草稿缺少冲突基线，未自动恢复；可关闭后保存当前内容为新草稿。";
      return;
    }
    if (![snapshot isEqual:_original]) self.navigationItem.prompt = @"已恢复旧草稿，但远端有变化。保存将检查旧基线；请先复制正文避免覆盖远端。";
    _original = [snapshot copy]; // Preserve A, never relabel an A-based draft with current remote B.
    // Dirty comparison must use that same A baseline, not the newer B that was
    // passed to init. Restoring an old draft must not silently rebase its edits.
    _initialText = LBEditorString(_original[@"content"]);
    _initialVisibility = LBEditorVisibility(_original[@"visibility"]);
    NSMutableOrderedSet *ids = [NSMutableOrderedSet new];
    for (id resource in _original[@"resourceList"]) {
      if ([resource isKindOfClass:NSDictionary.class] && LBEditorID(resource[@"id"])) [ids addObject:resource[@"id"]];
    }
    _initialIDs = ids.array;
  }
  _text.text = LBEditorString(draft[@"text"] ?: draft[@"content"]);
  _visibility = LBEditorVisibility(draft[@"visibility"]);
  [self visibilityChanged];
  NSMutableArray *restored = [NSMutableArray new];
  for (id identifier in draft[@"resourceIDs"]) {
    if (!LBEditorID(identifier)) continue;
    LBEditorAttachment *a = nil;
    for (LBEditorAttachment *old in _attachments) if ([old.resourceID isEqual:identifier]) { a = old; break; }
    if (!a) { a = [LBEditorAttachment new]; a.resourceID = identifier; a.filename = [NSString stringWithFormat:@"已上传附件 #%@", identifier]; }
    for (NSDictionary *resource in draft[@"resourceList"]) if ([resource[@"id"] isEqual:identifier]) {
      a.resource = resource; a.filename = LBEditorString(resource[@"filename"]); a.type = LBEditorString(resource[@"type"]); break;
    }
    [restored addObject:a];
  }
  NSUInteger missing = 0;
  for (id row in draft[@"localFiles"]) {
    if (![row isKindOfClass:NSDictionary.class]) continue;
    NSURL *url = [NSURL fileURLWithPath:LBEditorString(row[@"path"])];
    LBEditorAttachment *a = [LBEditorAttachment new]; a.file = url; a.filename = LBEditorFilename(row[@"filename"]);
    a.type = LBEditorString(row[@"type"]);
    if (!LBEditorOwnFile(url)) { missing++; a.state = @"failed"; a.failure = @"本地附件已丢失，请移除后重新选择。"; }
    else a.thumbnail = LBEditorThumbnail(url);
    [restored addObject:a];
  }
  _attachments = restored; _ownsDraft = YES;
  _draftSaved = [self hasContentChanges]; _localFilesPersisted = YES;
  if (!_draftSaved) [self clearUnchangedDraft];
  if (missing) self.navigationItem.prompt = @"部分本地附件已丢失，请重新选择；正文和已有资源已恢复。";
}
- (BOOL)persistDraft {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(persistDraft) object:nil];
  if (_finished || ![self accountCurrent] || !_text || _text.markedTextRange) return NO;
  if (![self hasContentChanges] && !_unknownOutcome) {
    [self clearUnchangedDraft]; [self refreshControls]; return YES;
  }
  NSMutableArray *files = [NSMutableArray new];
  for (LBEditorAttachment *a in _attachments) if (!a.resourceID && a.file)
    [files addObject:@{@"path":a.file.path, @"filename":a.filename, @"type":a.type ?: @"application/octet-stream"}];
  NSMutableArray *resources = [NSMutableArray new];
  for (LBEditorAttachment *a in _attachments) if (a.resourceID && a.resource) [resources addObject:a.resource];
  NSMutableDictionary *draft = [@{@"text":_text.text ?: @"", @"visibility":_visibility, @"resourceIDs":[self resourceIDs], @"localFiles":files, @"resourceList":resources} mutableCopy];
  if (_original) draft[@"originalSnapshot"] = _original;
  BOOL ok = [LBMemosClient.shared saveDraft:draft forMemo:[self memoID]];
  if (ok) _ownsDraft = YES;
  _draftSaved = ok;
  // The client contract guarantees text/visibility/IDs. Verify optional file
  // metadata round-trip rather than claiming attachments survived a relaunch.
  NSDictionary *stored = ok ? [LBMemosClient.shared draftForMemo:[self memoID]] : nil;
  _localFilesPersisted = !files.count || [stored[@"localFiles"] isEqual:files];
  if (!ok) self.navigationItem.prompt = @"草稿未能写入本机，请勿关闭；可先复制正文。";
  [self refreshControls]; return ok;
}

#pragma mark - Native pickers and import lifetime
- (void)choosePhotos {
  if (_saving || ![self accountCurrent]) return;
  [self.view endEditing:YES];
  PHPickerConfiguration *config = [PHPickerConfiguration new]; config.selectionLimit = 10;
  config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter]];
  config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
  PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config]; picker.delegate = self;
  [self presentViewController:picker animated:YES completion:nil];
}
- (void)chooseFiles {
  if (_saving || ![self accountCurrent]) return;
  [self.view endEditing:YES];
  UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:NO];
  picker.allowsMultipleSelection = YES; picker.delegate = self; [self presentViewController:picker animated:YES completion:nil];
}
- (LBEditorAttachment *)beginImport:(NSString *)name type:(NSString *)type {
  LBEditorAttachment *a = [LBEditorAttachment new]; a.filename = LBEditorFilename(name); a.type = type.length ? type : @"application/octet-stream";
  a.state = @"importing"; [_attachments addObject:a]; _pendingImports++;
  [self renderAttachments]; [self refreshControls]; return a;
}
- (void)completeImport:(LBEditorAttachment *)a file:(NSURL *)file error:(NSError *)error epoch:(NSUInteger)epoch {
  // Called only on main. Canceled/deleted imports never reappear later.
  if (_finished || epoch != _importEpoch || ![self accountCurrent] || ![_attachments containsObject:a]) { LBEditorRemoveFile(file); return; }
  _pendingImports = MAX(0, _pendingImports - 1); a.importProgress = nil; a.providerProgress = nil;
  a.file = file; a.state = file ? @"ready" : @"failed"; a.failure = file ? nil : (error.localizedDescription ?: @"导入失败，请移除后重新选择。");
  if (file && [a.type hasPrefix:@"image/"]) a.thumbnail = LBEditorThumbnail(file);
  [self renderAttachments]; [self changed];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (!results.count || _saving || ![self accountCurrent]) return;
  if (results.count > 10) { [self message:@"选择过多" detail:@"一次最多选择 10 个附件，请重新选择。此次没有导入任何文件。"]; return; }
  NSUInteger epoch = _importEpoch;
  for (PHPickerResult *result in results) {
    NSItemProvider *provider = result.itemProvider;
    NSString *identifier = LBEditorProviderIdentifier(provider);
    NSString *name = provider.suggestedName.length ? provider.suggestedName : @"attachment";
    NSDictionary *metadata = LBEditorImportMetadata(nil, name, identifier);
    LBEditorAttachment *a = [self beginImport:metadata[@"filename"] type:metadata[@"type"]];
    if (!identifier) { [self completeImport:a file:nil error:LBEditorError(@"此照片或视频没有可读取的文件表示，请用文件选择器重试。") epoch:epoch]; continue; }
    __weak typeof(self) weakSelf = self;
    NSProgress *progress = [NSProgress discreteProgressWithTotalUnitCount:1]; a.importProgress = progress;
    NSString *filename = a.filename;
    UTType *requested = [UTType typeWithIdentifier:identifier];
    BOOL photo = [requested conformsToType:UTTypeImage] || LBEditorHEIFExtension(identifier) != nil;
    a.providerProgress = [provider loadFileRepresentationForTypeIdentifier:identifier completionHandler:^(NSURL *url, NSError *error) {
      @autoreleasepool {
        NSError *copyError = error;
        // Provider URLs expire when this callback returns; retain our own copy now.
        NSURL *copy = url && !progress.cancelled ? LBEditorCopy(url, filename, &copyError) : nil;
        dispatch_async(LBEditorPreparationQueue(), ^{
          @autoreleasepool {
            NSError *failure = copyError; NSDictionary *actual = nil;
            NSURL *prepared = LBEditorPrepareCopy(copy, name, identifier, photo, progress, &actual, &failure);
            dispatch_async(dispatch_get_main_queue(), ^{
              typeof(self) self = weakSelf;
              if (!self) { LBEditorRemoveFile(prepared); return; }
              if (actual) { a.filename = actual[@"filename"]; a.type = actual[@"type"]; }
              [self completeImport:a file:prepared error:failure epoch:epoch];
            });
          }
        });
      }
    }];
  }
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  if (_saving || ![self accountCurrent]) return;
  // UIDocumentPicker has no selectionLimit. Reject the entire oversized batch
  // explicitly; never silently drop the eleventh file.
  if (urls.count > 10) { [self message:@"选择过多" detail:@"文件选择器一次最多导入 10 个。此次没有导入任何文件，请减少选择后重试。"]; return; }
  NSUInteger epoch = _importEpoch;
  for (NSURL *url in urls) {
    // Read declared resource metadata only while holding the granted scope;
    // explicit extension fallback also covers uppercase .HEIC/.HEIF files.
    BOOL scope = [url startAccessingSecurityScopedResource];
    UTType *type = nil;
    [url getResourceValue:&type forKey:NSURLContentTypeKey error:nil];
    NSString *identifier = LBEditorImportIdentifier(type.identifier, url.pathExtension);
    NSDictionary *metadata = LBEditorImportMetadata(nil, url.lastPathComponent, identifier);
    LBEditorAttachment *a = [self beginImport:metadata[@"filename"] type:metadata[@"type"]];
    // Keep the scope until the background coordinated copy finishes (copy also
    // balances its own scope). No source URL escapes into draft persistence.
    __weak typeof(self) weakSelf = self;
    NSProgress *progress = [NSProgress discreteProgressWithTotalUnitCount:1]; a.importProgress = progress;
    NSString *filename = a.filename;
    dispatch_async(LBEditorPreparationQueue(), ^{
      @autoreleasepool {
        NSError *error = nil;
        NSURL *copy = !progress.cancelled ? LBEditorCopy(url, filename, &error) : nil;
        if (scope) [url stopAccessingSecurityScopedResource];
        NSDictionary *actual = nil;
        NSURL *prepared = LBEditorPrepareCopy(copy, url.lastPathComponent, identifier, NO, progress, &actual, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
          typeof(self) self = weakSelf;
          if (!self) { LBEditorRemoveFile(prepared); return; }
          if (actual) { a.filename = actual[@"filename"]; a.type = actual[@"type"]; }
          [self completeImport:a file:prepared error:error epoch:epoch];
        });
      }
    });
  }
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { [self refreshControls]; }

#pragma mark - Attachment strip (removal never deletes a remote resource)
- (void)renderAttachments {
  for (UIView *view in _attachmentStack.arrangedSubviews) { [_attachmentStack removeArrangedSubview:view]; [view removeFromSuperview]; }
  _strip.hidden = !_attachments.count;
  if (!_attachments.count) return;
  for (LBEditorAttachment *a in _attachments) {
    UIVisualEffectView *card = [LBTheme glassWithTint:[LBTheme.surface colorWithAlphaComponent:0.45] interactive:NO];
    card.layer.cornerRadius = 16; card.clipsToBounds = YES;
    [card.widthAnchor constraintEqualToConstant:244].active = YES;
    UIStackView *column = [UIStackView new]; column.axis = UILayoutConstraintAxisVertical; column.spacing = 4;
    column.translatesAutoresizingMaskIntoConstraints = NO; [card.contentView addSubview:column];
    UIStackView *row = [UIStackView new]; row.spacing = 6; row.alignment = UIStackViewAlignmentCenter;
    NSString *symbol = [a.type hasPrefix:@"image/"] ? @"photo" : ([a.type hasPrefix:@"video/"] ? @"film" : ([a.type hasPrefix:@"audio/"] ? @"waveform" : @"doc"));
    UIImageView *image = [[UIImageView alloc] initWithImage:a.thumbnail ?: [UIImage systemImageNamed:symbol]];
    image.contentMode = UIViewContentModeScaleAspectFit; image.tintColor = LBTheme.accent;
    [image.widthAnchor constraintEqualToConstant:32].active = YES; [image.heightAnchor constraintEqualToConstant:32].active = YES;
    UILabel *name = [UILabel new]; name.text = a.filename; name.font = [LBTheme rounded:12 weight:UIFontWeightMedium]; name.textColor = LBTheme.ink;
    name.lineBreakMode = NSLineBreakByTruncatingMiddle; [row addArrangedSubview:image]; [row addArrangedSubview:name];
    __weak typeof(self) weakSelf = self;
    UIButton *remove = [UIButton buttonWithType:UIButtonTypeSystem]; [remove setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    remove.accessibilityLabel = [@"移除附件 " stringByAppendingString:a.filename]; remove.enabled = !_saving;
    [remove.widthAnchor constraintEqualToConstant:36].active = YES;
    [remove addAction:[UIAction actionWithHandler:^(UIAction *action) { [weakSelf removeAttachment:a]; }] forControlEvents:UIControlEventTouchUpInside];
    [row addArrangedSubview:remove]; [column addArrangedSubview:row];
    NSString *state = a.resourceID ? @"已上传 · 保存后关联" : @"待上传 · 保存时上传";
    if ([a.state isEqual:@"importing"]) state = @"正在导入… 点 × 可取消";
    if ([a.state isEqual:@"uploading"]) state = [NSString stringWithFormat:@"正在上传 %.0f%%", a.fraction * 100];
    if ([a.state isEqual:@"failed"]) state = a.failure ?: @"失败";
    UILabel *status = [UILabel new]; status.text = state; status.numberOfLines = 2; status.font = [UIFont systemFontOfSize:11];
    status.textColor = [a.state isEqual:@"failed"] ? UIColor.systemRedColor : LBTheme.muted; [column addArrangedSubview:status];
    UIProgressView *progress = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    progress.progress = (float)a.fraction; progress.hidden = ![a.state isEqual:@"uploading"]; [column addArrangedSubview:progress];
    if ([a.state isEqual:@"failed"] && a.file && LBEditorOwnFile(a.file)) {
      UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem]; [retry setTitle:@"重试此文件上传" forState:UIControlStateNormal]; retry.titleLabel.font = [UIFont systemFontOfSize:11]; retry.enabled = !_saving && [self accountCurrent];
      [retry addAction:[UIAction actionWithHandler:^(UIAction *action) { [weakSelf retryAttachment:a]; }] forControlEvents:UIControlEventTouchUpInside]; [column addArrangedSubview:retry];
    }
    [NSLayoutConstraint activateConstraints:@[
      [column.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:6], [column.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:8],
      [column.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-8], [column.bottomAnchor constraintLessThanOrEqualToAnchor:card.contentView.bottomAnchor constant:-4]
    ]]; [_attachmentStack addArrangedSubview:card];
  }
}
- (void)removeAttachment:(LBEditorAttachment *)a {
  if (_saving || ![_attachments containsObject:a]) return;
  if ([a.state isEqual:@"importing"]) _pendingImports = MAX(0, _pendingImports - 1);
  [a.importProgress cancel]; [a.providerProgress cancel]; LBEditorRemoveFile(a.file); [_attachments removeObject:a]; [self renderAttachments]; [self changed];
}

#pragma mark - Sequential uploads and explicit save
- (void)savePressed {
  if (_saving || _pendingImports || ![self accountCurrent]) return;
  [_text unmarkText]; [self.view endEditing:YES];
  if (_original && ![self hasContentChanges] && !_unknownOutcome) { [self closeEditor]; return; }
  if (!_text.text.length && !_attachments.count) { [self message:@"还没有内容" detail:@"请输入正文或添加一个有效附件。"]; return; }
  for (LBEditorAttachment *a in _attachments) {
    if (!a.resourceID && (!a.file || !LBEditorOwnFile(a.file))) {
      [self message:@"附件尚未就绪" detail:[NSString stringWithFormat:@"%@：请移除失败项并重新选择。不会忽略此附件直接保存。", a.filename]]; return;
    }
  }
  if (_unknownOutcome) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"先检查时间线" message:@"上次请求可能已在服务器成功。请先检查时间线，再决定是否再次保存，避免创建重复记录。不会自动重试。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"返回检查" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"我已检查，仍要保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self beginSave]; }]];
    [self presentViewController:alert animated:YES completion:nil]; return;
  }
  [self beginSave];
}
- (void)beginSave {
  if (_saving || _finished || _pendingImports || ![self accountCurrent]) return;
  if (_original && ![self hasContentChanges] && !_unknownOutcome) { [self closeEditor]; return; }
  [self persistDraft]; _saving = YES; [self renderAttachments]; [self refreshControls]; [self uploadNext];
}
- (void)uploadNext {
  if (!_saving || ![self accountCurrent] || _finished) return;
  for (LBEditorAttachment *a in _attachments) if (!a.resourceID) {
    [self uploadAttachment:a completion:^{ [self uploadNext]; }]; return;
  }
  _uploadTask = nil; [self refreshControls];
  // One invocation only. Client owns fresh-original conflict checking.
  __weak typeof(self) weakSelf = self;
  [LBMemosClient.shared saveOriginal:_original content:_text.text ?: @"" visibility:_visibility resourceIDs:[self resourceIDs] done:^(NSDictionary *memo, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf; if (!self || self->_finished) return;
      if (![self accountCurrent]) { [self connectionChanged:nil]; return; }
      self->_saving = NO;
      if (error || !memo) {
        NSError *failure = error ?: LBEditorError(@"服务器未返回有效记录。");
        // Transport failures may happen after a create committed. Never replay
        // automatically; preserve draft and make the uncertainty explicit.
        self->_unknownOutcome = !self->_original && (!error || [failure.domain isEqual:NSURLErrorDomain] ||
          [failure.userInfo[@"outcomeUnknown"] boolValue] || failure.code == 1010 || failure.code == 1008 ||
          failure.code == 1006 || (failure.code >= 500 && failure.code < 600));
        [self persistDraft]; [self renderAttachments]; [self refreshControls];
        NSString *detail = failure.localizedDescription;
        if (self->_unknownOutcome) detail = [detail stringByAppendingString:@"\n创建结果可能未知，请先检查时间线再重试，以免重复。正文与已上传资源 ID 已保留。"];
        [self message:@"保存未完成" detail:detail]; return;
      }
      self->_finished = YES; self->_ownsDraft = NO;
      [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(persistDraft) object:nil];
      [LBMemosClient.shared removeDraftForMemo:[self memoID]];
      for (LBEditorAttachment *a in self->_attachments) LBEditorRemoveFile(a.file);
      void (^saved)(NSDictionary *) = self->_saved;
      [self dismissEditor:^{ if (saved) saved(memo); }];
    });
  }];
}
- (void)uploadAttachment:(LBEditorAttachment *)a completion:(void (^)(void))completion {
  if (!_saving || ![self accountCurrent]) return;
  if (!LBEditorOwnFile(a.file)) { _saving = NO; a.state = @"failed"; a.failure = @"本地文件不可用，请重新选择。"; [self renderAttachments]; [self refreshControls]; return; }
  _cancelingUpload = NO;
  a.state = @"uploading"; a.fraction = 0; a.failure = nil; [self renderAttachments];
  __weak typeof(self) weakSelf = self;
  _uploadTask = [LBMemosClient.shared uploadFile:a.file filename:a.filename type:a.type progress:^(double fraction) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (!self || !self->_saving || ![self accountCurrent] || ![a.state isEqual:@"uploading"]) return;
      a.fraction = MIN(1, MAX(0, fraction)); [self renderAttachments];
    });
  } done:^(NSDictionary *resource, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (!self || self->_finished || ![self accountCurrent]) return;
      self->_uploadTask = nil;
      if (!self->_saving) return;
      BOOL canceled = self->_cancelingUpload; self->_cancelingUpload = NO;
      NSNumber *identifier = LBEditorID(resource[@"id"]);
      if (error || !identifier) {
        self->_saving = NO; a.state = @"failed"; a.failure = error.localizedDescription ?: @"服务器未返回资源 ID。";
        [self persistDraft]; [self renderAttachments]; [self refreshControls];
        [self message:@"附件上传未完成" detail:[NSString stringWithFormat:@"%@\n%@\n正文和文件保留。可重试此文件；已成功上传的附件不会重复上传。", a.filename, a.failure]]; return;
      }
      a.resourceID = identifier; a.resource = resource; a.state = @"ready"; a.fraction = 1;
      [self persistDraft]; [self renderAttachments];
      if (canceled) { self->_saving = NO; [self refreshControls]; return; }
      if (completion) completion();
    });
  }];
  [self refreshControls];
}
- (void)retryAttachment:(LBEditorAttachment *)a {
  if (_saving || _pendingImports || ![self accountCurrent] || a.resourceID || !LBEditorOwnFile(a.file)) return;
  [_text unmarkText]; [self.view endEditing:YES]; _saving = YES;
  [self uploadAttachment:a completion:^{ self->_saving = NO; [self renderAttachments]; [self refreshControls]; }];
}
- (void)stopUpload {
  if (!_saving || !_uploadTask) return;
  // Do not start another request until the canceled task's completion arrives.
  _cancelingUpload = YES; [_uploadTask cancel]; _stop.enabled = NO;
  _status.text = @"正在取消上传；服务器可能已收到文件，取消不会删除远端资源。";
}

#pragma mark - Exit never publishes
- (void)message:(NSString *)title detail:(NSString *)detail {
  if (self.presentedViewController) { self.navigationItem.prompt = detail; return; }
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}
- (void)closeEditor {
  if (_saving) { [self message:@"操作进行中" detail:@"请等待保存结束，或先取消当前上传。不会在请求未结束时丢弃正文。"]; return; }
  [_text unmarkText]; [self.view endEditing:YES];
  BOOL dirty = [self hasContentChanges] || _unknownOutcome;
  if (!dirty && !_pendingImports) { [self clearUnchangedDraft]; [self finishClosing:NO]; return; }
  NSString *detail = _pendingImports ? @"仍有附件正在导入。保存草稿并关闭将取消未完成的导入，已完成的附件与正文保留。" : @"保存草稿只写入本机，不会发布。已上传但未关联的资源不会自动删除。";
  if (![self accountCurrent]) detail = @"账号已变更，不能把旧内容保存到当前账号。请先继续编辑并复制需要的正文，或丢弃并关闭。";
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保留这次编辑？" message:detail preferredStyle:UIAlertControllerStyleAlert];
  if ([self accountCurrent]) [alert addAction:[UIAlertAction actionWithTitle:@"保存草稿并关闭" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    if (![self persistDraft]) { [self message:@"草稿保存失败" detail:@"请继续编辑并复制正文，不会关闭编辑器。"]; return; }
    if (!self->_localFilesPersisted) {
      [self message:@"附件未持久保存" detail:@"当前草稿存储仅保存正文与已上传资源。请先保存记录或移除待上传附件后再关闭；不会丢弃本地文件直接退出。"]; return;
    }
    [self finishClosing:NO];
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"丢弃并关闭" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [self finishClosing:YES]; }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}
- (void)finishClosing:(BOOL)discard {
  _finished = YES; _importEpoch++; _pendingImports = 0;
  [NSObject cancelPreviousPerformRequestsWithTarget:self];
  for (LBEditorAttachment *a in _attachments) { [a.importProgress cancel]; [a.providerProgress cancel]; if (discard) LBEditorRemoveFile(a.file); }
  if (discard && [self accountCurrent]) [LBMemosClient.shared removeDraftForMemo:[self memoID]];
  [self dismissEditor:nil];
}
- (void)dismissEditor:(void (^)(void))completion {
  if (self.navigationController.presentingViewController || self.presentingViewController) [self dismissViewControllerAnimated:YES completion:completion];
  else { [self.navigationController popViewControllerAnimated:YES]; if (completion) completion(); }
}
@end

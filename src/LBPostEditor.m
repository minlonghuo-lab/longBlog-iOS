#import "LBPostEditor.h"
#import "LBMdStore.h"
#import "LBMarkdown.h"
#import "LBLayout.h"
#import "LBPostReader.h"
#import "LBNavigationController.h"
#import "LBAI.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>

NSNotificationName const LBPostEditorDidFinish = @"LBPostEditorDidFinish";

@interface LBLocalAttachment : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *filename;
@property (nonatomic, copy) NSString *mime;
@property (nonatomic, strong) NSData *data;
@property (nonatomic) BOOL isImage;
@end

@implementation LBLocalAttachment
@end

// Downscale an arbitrary image payload to a bounded JPEG so local drafts and
// previews stay well under the Reader's 4 MiB HTML ceiling.
static NSData *LBThumbnailImageData(NSData *bytes, CGFloat maxDimension) {
  if (!bytes.length) return bytes;
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, NULL);
  if (!src) return bytes;
  CGImageRef image = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)@{
    (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
    (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
    (id)kCGImageSourceThumbnailMaxPixelSize: @(maxDimension)
  });
  CFRelease(src);
  if (!image) return bytes;
  NSMutableData *out = [NSMutableData data];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out,
      (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
  if (!dest) { CGImageRelease(image); return bytes; }
  CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)@{(id)kCGImageDestinationLossyCompressionQuality: @0.8});
  CGImageDestinationFinalize(dest);
  CFRelease(dest);
  CGImageRelease(image);
  return out.length ? out : bytes;
}

// Inserts a unique marker paragraph at the start of the Markdown block that
// contains `caret`, never inside a fenced code / $$ math block or a table.
// The Reader removes the marker and scrolls the preview to that spot.
static NSString *LBPreviewMarkdownWithAnchor(NSString *markdown, NSUInteger caret, NSString *marker) {
  if (!markdown.length || !marker.length) return markdown ?: @"";
  caret = MIN(caret, markdown.length);
  NSArray<NSString *> *lines = [markdown componentsSeparatedByString:@"\n"];
  NSUInteger offset = 0, blockStart = 0, blockOffset = 0;
  NSString *fence = nil;
  BOOL math = NO;
  for (NSUInteger i = 0; i < lines.count; i++) {
    NSString *line = lines[i];
    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    BOOL blank = trimmed.length == 0;
    if (!fence && !math && blank) { blockStart = i + 1; blockOffset = offset + line.length + 1; }
    if (fence) {
      if ([trimmed hasPrefix:fence]) fence = nil;
    } else if (!math && ([trimmed hasPrefix:@"```"] || [trimmed hasPrefix:@"~~~"])) {
      fence = [trimmed substringToIndex:3];
    } else if ([trimmed isEqualToString:@"$$"]) {
      math = !math;
    }
    if (caret <= offset + line.length) {
      // A caret on a blank line between blocks anchors exactly there.
      if (blank && !fence && !math) { blockStart = i; blockOffset = offset; }
      break;
    }
    offset += line.length + 1;
  }
  if (blockStart == 0 || blockOffset == 0) return markdown; // top of document: preview starts at top anyway
  blockOffset = MIN(blockOffset, markdown.length);
  BOOL previousBlank = blockStart > 0 && blockStart - 1 < lines.count &&
      [lines[blockStart - 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length == 0;
  NSString *insert = [NSString stringWithFormat:@"%@%@\n\n", previousBlank ? @"" : @"\n", marker];
  return [markdown stringByReplacingCharactersInRange:NSMakeRange(blockOffset, 0) withString:insert];
}

typedef enum {
  LBEditorPublicationPublish,
  LBEditorPublicationUnpublish
} LBEditorPublicationAction;

// The send menu always offers exactly one publication transition next to save.
static LBEditorPublicationAction LBEditorActionForState(BOOL published) {
  return published ? LBEditorPublicationUnpublish : LBEditorPublicationPublish;
}

// Ordered markdown list markers recognised for Return continuation and toggles.
static NSRegularExpression *LBListMarker(void) {
  static NSRegularExpression *re; static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression regularExpressionWithPattern:@"^(\\s*)(- \\[[ xX]\\] |[-*+] |(\\d{1,6})\\. |> )" options:0 error:nil];
  });
  return re;
}

// One serial queue for every draft snapshot write/removal, so a late write can
// never resurrect a draft that a successful save already removed.
static dispatch_queue_t LBDraftQueue(void) {
  static dispatch_queue_t q; static dispatch_once_t once;
  dispatch_once(&once, ^{ q = dispatch_queue_create("com.huowenlong.longblog.drafts", DISPATCH_QUEUE_SERIAL); });
  return q;
}

static const NSUInteger LBAIMaxInput = 30000;
static NSString *const LBAISystemPrompt = @"你是一位细腻的中文博客写作助手。严格只输出结果本身，不要任何解释、前言、标题、引号或代码围栏。"
    @"保持原文中的 Markdown 语法、链接、图片、公式与代码块不被破坏，不编造事实。";

static NSString *LBEditorString(id value) {
  return [value isKindOfClass:NSString.class] ? value : @"";
}

static NSString *LBEditorAssetReference(NSString *noteId, NSString *filename) {
  NSMutableCharacterSet *allowed = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
  [allowed addCharactersInString:@"-._~"];
  return [NSString stringWithFormat:@"/assets/%@/%@",
      [noteId stringByAddingPercentEncodingWithAllowedCharacters:allowed],
      [filename stringByAddingPercentEncodingWithAllowedCharacters:allowed]];
}

NSString *LBDraftsDirectory(void) {
  NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
      stringByAppendingPathComponent:@"Drafts"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  return dir;
}

static NSString *LBDraftMarkdown(NSDictionary *draft) {
  return [draft[@"markdown"] isKindOfClass:NSString.class] ? draft[@"markdown"] : @"";
}

NSArray<NSDictionary *> *LBListLocalDrafts(void) {
  NSMutableArray *items = [NSMutableArray array];
  NSFileManager *fm = NSFileManager.defaultManager;
  NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:LBDraftsDirectory() error:nil];
  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^draft_(.+)\\.json$" options:0 error:nil];
  for (NSString *f in files) {
    NSTextCheckingResult *m = [re firstMatchInString:f options:0 range:NSMakeRange(0, f.length)];
    if (!m) continue;
    NSString *key = [f substringWithRange:[m rangeAtIndex:1]];
    if ([key isEqualToString:@"new_article"]) continue; // in-progress unsaved editor state
    NSString *path = [LBDraftsDirectory() stringByAppendingPathComponent:f];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *d = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![d isKindOfClass:NSDictionary.class]) continue;
    if ([d[@"noteId"] isKindOfClass:NSString.class]) continue; // already synced / remote draft
    NSString *title = d[@"title"];
    if (![title isKindOfClass:NSString.class] || !title.length) continue;

    long long savedAt = [d[@"savedAtMs"] longLongValue] ?: (long long)(NSDate.date.timeIntervalSince1970 * 1000);
    [items addObject:@{
      @"id": [@"local:" stringByAppendingString:key],
      @"slug": key,
      @"title": title,
      @"summary": [d[@"summary"] isKindOfClass:NSString.class] ? d[@"summary"] : @"",
      @"publish": @NO,
      @"isLocalDraft": @YES,
      @"draftKey": key,
      @"draftPath": path,
      @"markdown": LBDraftMarkdown(d),
      @"updatedAt": @(savedAt),
      @"publishedAt": @(savedAt)
    }];
  }
  [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [b[@"updatedAt"] compare:a[@"updatedAt"]];
  }];
  return items;
}

NSDictionary *LBLoadLocalDraftPost(NSString *draftPath) {
  NSData *data = [NSData dataWithContentsOfFile:draftPath];
  NSDictionary *d = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![d isKindOfClass:NSDictionary.class]) return nil;

  NSString *markdown = LBDraftMarkdown(d);
  NSString *mediaDir = [draftPath stringByDeletingPathExtension];

  // Resolve minis-local attachments to inline data: images so the offline Reader renders them.
  NSMutableString *md = [markdown mutableCopy];

  NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"minis-local://(local_[A-Za-z0-9-]+)" options:0 error:nil];
  NSArray<NSTextCheckingResult *> *matches = [re matchesInString:markdown options:0 range:NSMakeRange(0, markdown.length)];
  for (NSTextCheckingResult *m in [matches reverseObjectEnumerator]) {
    NSString *key = [markdown substringWithRange:[m rangeAtIndex:1]];
    NSData *bytes = [NSData dataWithContentsOfFile:[mediaDir stringByAppendingPathComponent:key]];
    NSString *mime = @"image/png";
    for (NSDictionary *item in [d[@"attachments"] isKindOfClass:NSArray.class] ? d[@"attachments"] : @[]) {
      if ([item[@"key"] isEqualToString:key] && [item[@"mime"] isKindOfClass:NSString.class]) { mime = item[@"mime"]; break; }
    }
    if (bytes.length && [mime hasPrefix:@"image/"]) {
      NSString *uri = [NSString stringWithFormat:@"data:image/jpeg;base64,%@", [LBThumbnailImageData(bytes, 1280) base64EncodedStringWithOptions:0]];
      [md replaceCharactersInRange:m.range withString:uri];
    } else {
      [md replaceCharactersInRange:m.range withString:@"#attachment"];
    }
  }

  NSString *html = LBMarkdownToHTML(md);
  NSString *key = [draftPath.lastPathComponent stringByReplacingOccurrencesOfString:@".json" withString:@""];
  if ([key hasPrefix:@"draft_"]) key = [key substringFromIndex:6];
  return @{
    @"id": [@"local:" stringByAppendingString:key],
    @"slug": key,
    @"title": d[@"title"] ?: @"草稿",
    @"summary": [d[@"summary"] isKindOfClass:NSString.class] ? d[@"summary"] : @"",
    @"publish": @NO,
    @"isLocalDraft": @YES,
    @"draftKey": key,
    @"draftPath": draftPath,
    @"html": html,
    @"markdown": markdown
  };
}

@interface LBPostEditor () <UITextViewDelegate, UITextFieldDelegate, PHPickerViewControllerDelegate, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@end

@implementation LBPostEditor {
  NSDictionary *_original;
  void (^_saved)(NSDictionary *);
  NSString *_noteId;

  UITextField *_titleField;
  UIButton *_summaryToggle;
  UIImageView *_summaryChevron;
  UITextView *_summaryView;
  UIView *_summaryContainer;
  NSLayoutConstraint *_summaryHeight;
  BOOL _summaryExpanded;

  UITextView *_textView;
  UILabel *_placeholder;

  BOOL _hasSavedArticle;
  BOOL _published;
  BOOL _revealingCaret;
  BOOL _checkedDraft;
  CGSize _editorViewportSize;

  UIStackView *_dock;
  UILabel *_operationStatusLabel;
  UIVisualEffectView *_toolbar;
  UIStackView *_toolbarStack;
  UIButton *_formatButton;
  UIInputView *_formatPanel;
  NSArray<UIButton *> *_styleButtons;

  UIBarButtonItem *_saveItem;
  UIBarButtonItem *_cancelItem;

  BOOL _saving;
  BOOL _closed;
  NSUUID *_publicationOperation;
  NSUInteger _attachmentGeneration;
  NSString *_completionMessage;
  BOOL _dirty;
  NSDictionary *_contentBaseline;
  BOOL _ownsDraft;
  NSTimer *_draftTimer;
  NSString *_draftPath;

  NSMutableDictionary<NSString *, LBLocalAttachment *> *_localAttachments;
}

- (instancetype)initWithPost:(NSDictionary *)post saved:(void (^)(NSDictionary *))saved {
  if ((self = [super init])) {
    _original = [post isKindOfClass:NSDictionary.class] ? [post copy] : nil;
    _saved = [saved copy];
    _localAttachments = [NSMutableDictionary dictionary];

    NSString *candidate = LBEditorString(_original[@"id"]);
    if (!candidate.length) candidate = LBEditorString(_original[@"slug"]);
    NSCharacterSet *idCharacters = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"];
    if (candidate.length && [candidate rangeOfCharacterFromSet:idCharacters.invertedSet].location == NSNotFound) {
      _noteId = [candidate copy];
    } else {
      _noteId = [LBMdStore.shared generateUniqueNoteID];
    }
    NSDictionary *stored = [LBMdStore.shared loadArticle:_noteId];
    if (stored) _original = [stored copy];
    _hasSavedArticle = stored != nil;
    _published = [stored[@"publish"] boolValue];
    // The new-article slot must be stable across fresh IDs after a process restart.
    NSString *slot = _hasSavedArticle ? [@"autosave_" stringByAppendingString:_noteId] : @"new_article";
    _draftPath = [LBDraftsDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"draft_%@.json", slot]];
  }
  return self;
}

- (void)dealloc {
  [_draftTimer invalidate];
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = _original ? @"编辑文章" : @"撰写文章";
  self.view.backgroundColor = LBTheme.paper;
  self.modalInPresentation = YES;

  _cancelItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancelPressed)];
  __weak typeof(self) weakSelf = self;
  // Single send button: tap saves; long-press offers save + publish/unpublish.
  _saveItem = [[UIBarButtonItem alloc] initWithPrimaryAction:[UIAction actionWithTitle:@"保存"
      image:[UIImage systemImageNamed:@"paperplane.fill"] identifier:nil handler:^(UIAction *a) { [weakSelf savePressed]; }] menu:nil];
  _saveItem.style = UIBarButtonItemStyleProminent;
  _saveItem.tintColor = LBTheme.accent;
  self.navigationItem.leftBarButtonItem = _cancelItem;
  self.navigationItem.rightBarButtonItem = _saveItem;

  // Background decoration
  LBAuroraView *bg = [[LBAuroraView alloc] initWithFrame:self.view.bounds];
  bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:bg];

  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

  [self updatePublicationActions];

  // Title Field
  _titleField = [UITextField new];
  _titleField.translatesAutoresizingMaskIntoConstraints = NO;
  _titleField.placeholder = @"文章标题…";
  _titleField.font = [LBTheme rounded:20 weight:UIFontWeightBold];
  _titleField.textColor = LBTheme.ink;
  _titleField.tintColor = LBTheme.accent;
  _titleField.returnKeyType = UIReturnKeyNext;
  _titleField.delegate = self;
  [_titleField addTarget:self action:@selector(contentChanged) forControlEvents:UIControlEventEditingChanged];
  [self.view addSubview:_titleField];

  // Summary Container
  _summaryContainer = [UIView new];
  _summaryContainer.translatesAutoresizingMaskIntoConstraints = NO;
  _summaryContainer.backgroundColor = [LBTheme.surface colorWithAlphaComponent:0.4];
  _summaryContainer.layer.cornerRadius = 12;
  _summaryContainer.layer.cornerCurve = kCACornerCurveContinuous;
  _summaryContainer.layer.borderWidth = 0.5;
  _summaryContainer.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
  _summaryContainer.clipsToBounds = YES;
  [self.view addSubview:_summaryContainer];

  _summaryToggle = [UIButton buttonWithType:UIButtonTypeSystem];
  _summaryToggle.translatesAutoresizingMaskIntoConstraints = NO;
  _summaryToggle.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
  [self updateSummaryToggle];
  [_summaryToggle addTarget:self action:@selector(toggleSummary) forControlEvents:UIControlEventTouchUpInside];
  [_summaryContainer addSubview:_summaryToggle];

  _summaryView = [UITextView new];
  _summaryView.translatesAutoresizingMaskIntoConstraints = NO;
  _summaryView.backgroundColor = UIColor.clearColor;
  _summaryView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  _summaryView.textColor = LBTheme.ink;
  _summaryView.tintColor = LBTheme.accent;
  _summaryView.delegate = self;
  _summaryView.hidden = YES;
  [_summaryContainer addSubview:_summaryView];

  // Text View for Markdown Body. TextKit 1 with contiguous layout keeps
  // contentSize exact: non-contiguous layout only estimates the unlaid tail, so
  // the scroll view stopped short while text still existed below.
  _textView = [UITextView textViewUsingTextLayoutManager:NO];
  _textView.translatesAutoresizingMaskIntoConstraints = NO;
  _textView.backgroundColor = UIColor.clearColor;
  _textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  _textView.textColor = LBTheme.ink;
  _textView.tintColor = LBTheme.accent;
  _textView.delegate = self;
  _textView.scrollEnabled = YES;
  _textView.layoutManager.allowsNonContiguousLayout = NO;
  _textView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
  _textView.textContainerInset = UIEdgeInsetsMake(16, 8, 16, 8);
  // Bottom writing space is recomputed from the visible height in viewDidLayoutSubviews.
  _textView.contentInset = UIEdgeInsetsMake(0, 0, 120, 0);
  _textView.automaticallyAdjustsScrollIndicatorInsets = NO;
  _textView.scrollIndicatorInsets = UIEdgeInsetsZero;
  _textView.alwaysBounceVertical = YES;
  _textView.showsVerticalScrollIndicator = YES;
  _textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  _textView.smartDashesType = UITextSmartDashesTypeNo;
  _textView.smartQuotesType = UITextSmartQuotesTypeNo;
  [self.view addSubview:_textView];

  UITapGestureRecognizer *tapBg = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleBackgroundTap:)];
  tapBg.cancelsTouchesInView = NO;
  [self.view addGestureRecognizer:tapBg];

  _placeholder = [UILabel new];
  _placeholder.translatesAutoresizingMaskIntoConstraints = NO;
  _placeholder.text = @"开始撰写正文…";
  _placeholder.font = _textView.font;
  _placeholder.textColor = LBTheme.muted;
  _placeholder.numberOfLines = 0;
  _placeholder.userInteractionEnabled = NO;
  [_textView addSubview:_placeholder];

  // Bottom Floating Dock
  _dock = [UIStackView new];
  _dock.translatesAutoresizingMaskIntoConstraints = NO;
  _dock.axis = UILayoutConstraintAxisVertical;
  _dock.spacing = 6;
  [self.view addSubview:_dock];

  _operationStatusLabel = [UILabel new];
  _operationStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  _operationStatusLabel.adjustsFontForContentSizeCategory = YES;
  _operationStatusLabel.textColor = LBTheme.muted;
  _operationStatusLabel.numberOfLines = 3;
  _operationStatusLabel.hidden = YES;
  [_dock addArrangedSubview:_operationStatusLabel];

  _toolbar = [[UIVisualEffectView alloc] initWithEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
  _toolbar.translatesAutoresizingMaskIntoConstraints = NO;
  _toolbar.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
  [_dock addArrangedSubview:_toolbar];

  _toolbarStack = [UIStackView new];
  _toolbarStack.translatesAutoresizingMaskIntoConstraints = NO;
  _toolbarStack.axis = UILayoutConstraintAxisHorizontal;
  _toolbarStack.distribution = UIStackViewDistributionEqualSpacing;
  _toolbarStack.alignment = UIStackViewAlignmentCenter;
  [_toolbar.contentView addSubview:_toolbarStack];

  [self setupToolbarButtons];

  // Layout Constraints
  _summaryHeight = [_summaryContainer.heightAnchor constraintEqualToConstant:32];
  _summaryHeight.priority = UILayoutPriorityDefaultHigh;
  _summaryHeight.active = YES;

  [_summaryView.heightAnchor constraintEqualToConstant:60].active = YES;
  NSLayoutConstraint *summaryBottom = [_summaryView.bottomAnchor constraintEqualToAnchor:_summaryContainer.bottomAnchor constant:-6];
  summaryBottom.priority = UILayoutPriorityDefaultLow;
  summaryBottom.active = YES;
  // Collapsing hides/clips the summary without requiring a negative text-view
  // height. Its optional bottom constraint yields to the collapsed container.
  [NSLayoutConstraint activateConstraints:@[
    [_titleField.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
    [_titleField.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [_titleField.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    [_titleField.heightAnchor constraintEqualToConstant:40],

    [_summaryContainer.topAnchor constraintEqualToAnchor:_titleField.bottomAnchor constant:6],
    [_summaryContainer.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
    [_summaryContainer.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

    [_summaryToggle.topAnchor constraintEqualToAnchor:_summaryContainer.topAnchor],
    [_summaryToggle.leadingAnchor constraintEqualToAnchor:_summaryContainer.leadingAnchor constant:10],
    [_summaryToggle.trailingAnchor constraintEqualToAnchor:_summaryContainer.trailingAnchor constant:-10],
    [_summaryToggle.heightAnchor constraintEqualToConstant:32],

    [_summaryView.topAnchor constraintEqualToAnchor:_summaryToggle.bottomAnchor constant:2],
    [_summaryView.leadingAnchor constraintEqualToAnchor:_summaryContainer.leadingAnchor constant:8],
    [_summaryView.trailingAnchor constraintEqualToAnchor:_summaryContainer.trailingAnchor constant:-8],

    [_textView.topAnchor constraintEqualToAnchor:_summaryContainer.bottomAnchor constant:8],
    [_textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
    [_textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
    [_textView.bottomAnchor constraintEqualToAnchor:_dock.topAnchor constant:-6],

    // Frame-guide anchors never feed Auto Layout into the text view's contentSize.
    [_placeholder.topAnchor constraintEqualToAnchor:_textView.frameLayoutGuide.topAnchor constant:16],
    [_placeholder.leadingAnchor constraintEqualToAnchor:_textView.frameLayoutGuide.leadingAnchor constant:13],
    [_placeholder.widthAnchor constraintEqualToAnchor:_textView.frameLayoutGuide.widthAnchor constant:-26],

    [_dock.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
    [_dock.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
    [_dock.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-6],
    // Only the toolbar row is fixed; a visible status line grows the dock upward
    // instead of crushing the toolbar inside a fixed-height stack.
    [_toolbar.heightAnchor constraintEqualToConstant:52],

    [_toolbarStack.topAnchor constraintEqualToAnchor:_toolbar.contentView.topAnchor],
    [_toolbarStack.bottomAnchor constraintEqualToAnchor:_toolbar.contentView.bottomAnchor],
    [_toolbarStack.leadingAnchor constraintEqualToAnchor:_toolbar.contentView.leadingAnchor constant:14],
    [_toolbarStack.trailingAnchor constraintEqualToAnchor:_toolbar.contentView.trailingAnchor constant:-14]
  ]];

  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
  [self populateInitialData];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  self.presentationController.delegate = self;
  self.navigationController.presentationController.delegate = self;
  self.navigationController.modalInPresentation = YES;
  if (!_checkedDraft) {
    _checkedDraft = YES;
    [self checkLocalDraft];
  }
}

- (void)updatePublicationActions {
  LBEditorPublicationAction action = LBEditorActionForState(_published);
  NSString *saveTitle = _published ? @"保存修改" : (_hasSavedArticle ? @"保存草稿" : @"存为草稿");
  __weak typeof(self) weakSelf = self;
  UIAction *save = [UIAction actionWithTitle:saveTitle image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil
      handler:^(UIAction *a) { [weakSelf savePressed]; }];
  save.subtitle = _published ? @"立即同步更新线上文章" : @"仅保存在本地";
  UIAction *publication;
  if (action == LBEditorPublicationUnpublish) {
    publication = [UIAction actionWithTitle:@"下架文章" image:[UIImage systemImageNamed:@"archivebox"] identifier:nil
        handler:^(UIAction *a) { [weakSelf publicationPressed]; }];
    publication.subtitle = @"加入待下架，在文章列表一并提交";
    publication.attributes = UIMenuElementAttributesDestructive;
  } else {
    publication = [UIAction actionWithTitle:@"发布文章" image:[UIImage systemImageNamed:@"paperplane"] identifier:nil
        handler:^(UIAction *a) { [weakSelf publicationPressed]; }];
    publication.subtitle = @"加入待发布，在文章列表一并提交";
  }
  _saveItem.menu = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ save, publication ]];
  _saveItem.accessibilityLabel = saveTitle;
  _saveItem.accessibilityHint = action == LBEditorPublicationUnpublish ? @"轻点保存，长按可下架文章" : @"轻点保存，长按可发布文章";
  _saveItem.enabled = !_saving;
  _cancelItem.enabled = !_saving;
}

- (void)revealEditorCaret {
  // keyboardLayoutGuide alone resizes the viewport; never add keyboard-height
  // insets as well (that double-counts keyboard avoidance).
  if (_revealingCaret) return;
  UITextView *active = _textView.isFirstResponder ? _textView : (_summaryView.isFirstResponder ? _summaryView : nil);
  if (!active || !active.selectedTextRange || CGRectIsEmpty(active.bounds)) return;
  if (active.isTracking || active.isDragging || active.isDecelerating) return;
  _revealingCaret = YES;
  CGRect caret = [active caretRectForPosition:active.selectedTextRange.end];
  [active scrollRectToVisible:CGRectInset(caret, 0, -20) animated:NO];
  _revealingCaret = NO;
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGSize viewport = _textView.bounds.size;
  if (!CGSizeEqualToSize(viewport, _editorViewportSize)) {
    _editorViewportSize = viewport;
    // Writing room: the last line can always be lifted to roughly the middle of
    // the visible editor, above the dock and keyboard, instead of hugging the edge.
    CGFloat room = MAX(120, floor(viewport.height * 0.45));
    if (fabs(_textView.contentInset.bottom - room) > 0.5) {
      UIEdgeInsets inset = _textView.contentInset;
      inset.bottom = room;
      _textView.contentInset = inset;
    }
    if (!_textView.isTracking && !_textView.isDragging && !_textView.isDecelerating) {
      [self revealEditorCaret];
    }
  }
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  [self saveDraftToDisk];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
  [self saveDraftToDisk];
}

- (void)toggleSummary {
  _summaryExpanded = !_summaryExpanded;
  _summaryView.hidden = !_summaryExpanded;
  [self updateSummaryToggle];
  _summaryHeight.constant = _summaryExpanded ? 100 : 32;
  if (!_summaryExpanded && _summaryView.isFirstResponder) [_textView becomeFirstResponder];
  [UIView animateWithDuration:0.25 animations:^{
    [self.view layoutIfNeeded];
  }];
}

// One SF Symbol row: a leading state glyph and a trailing chevron that morphs
// with the native content transition instead of text arrows.
- (void)updateSummaryToggle {
  BOOL filled = _summaryView.text.length > 0;
  UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
  cfg.contentInsets = NSDirectionalEdgeInsetsZero;
  cfg.baseForegroundColor = filled ? LBTheme.accent : LBTheme.muted;
  cfg.image = [UIImage systemImageNamed:filled ? @"text.quote" : @"text.alignleft"
      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightMedium]];
  cfg.imagePadding = 6;
  cfg.title = _summaryExpanded ? @"手写摘要" : (filled ? @"手写摘要 · 已填写" : @"手写摘要 · 可选");
  cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *in) {
    NSMutableDictionary *out = [in mutableCopy];
    out[NSFontAttributeName] = [LBTheme rounded:12 weight:UIFontWeightMedium];
    return out;
  };
  _summaryToggle.configuration = cfg;
  _summaryToggle.accessibilityValue = _summaryExpanded ? @"已展开" : @"已收起";
  if (!_summaryChevron) {
    _summaryChevron = [UIImageView new];
    _summaryChevron.translatesAutoresizingMaskIntoConstraints = NO;
    _summaryChevron.contentMode = UIViewContentModeCenter;
    _summaryChevron.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIImageSymbolWeightSemibold];
    _summaryChevron.tintColor = LBTheme.muted;
    _summaryChevron.image = [UIImage systemImageNamed:@"chevron.down"];
    _summaryChevron.userInteractionEnabled = NO;
    [_summaryToggle addSubview:_summaryChevron];
    [NSLayoutConstraint activateConstraints:@[
      [_summaryChevron.trailingAnchor constraintEqualToAnchor:_summaryToggle.trailingAnchor],
      [_summaryChevron.centerYAnchor constraintEqualToAnchor:_summaryToggle.centerYAnchor]
    ]];
  }
  [_summaryChevron setSymbolImage:[UIImage systemImageNamed:_summaryExpanded ? @"chevron.up" : @"chevron.down"]
      withContentTransition:[NSSymbolReplaceContentTransition replaceDownUpTransition]];
}

#pragma mark - Initial Data & Drafts

- (void)populateInitialData {
  if (_original) {
    _titleField.text = LBEditorString(_original[@"title"]);
    _textView.text = LBEditorString(_original[@"markdown"]);
    NSString *summary = LBEditorString(_original[@"manualSummary"]);
    if (!summary.length) summary = LBEditorString(_original[@"summary"]);
    if (summary.length) {
      _summaryView.text = summary;
      [self updateSummaryToggle];
    }
  }
  _placeholder.hidden = _textView.text.length > 0;
  // Capture displayed content, including the manual-summary fallback, before
  // offering recovery. Caret, selection, keyboard and preview are not content.
  _contentBaseline = [self contentSnapshot];
}

- (NSDictionary *)contentSnapshot {
  NSString *body = _textView.text ?: @"";
  NSMutableDictionary *attachments = [NSMutableDictionary dictionary];
  for (LBLocalAttachment *att in _localAttachments.allValues) {
    // An insertion that has been undone must not stay dirty just because its
    // recovery bytes are still cached. Never delete the asset as a side effect.
    if (![body containsString:LBEditorAssetReference(_noteId, att.filename)]) continue;
    attachments[att.filename] = @{ @"data":att.data ?: NSData.data,
      @"mime":att.mime ?: @"", @"isImage":@(att.isImage) };
  }
  return @{ @"title":_titleField.text ?: @"", @"markdown":body,
    @"summary":_summaryView.text ?: @"", @"publish":@(_published),
    @"attachments":attachments };
}

- (BOOL)hasContentChanges {
  _dirty = _contentBaseline && ![[self contentSnapshot] isEqual:_contentBaseline];
  return _dirty;
}

- (void)clearUnchangedDraft {
  if (!_ownsDraft) return; // Do not erase a recovery the author has not accepted.
  _ownsDraft = NO;
  [self removeDraftFiles]; // Same serial queue as writes, including a late autosave.
}

- (BOOL)draftAttachmentsMatchCurrentContent:(NSDictionary *)draft {
  NSString *body = LBEditorString(draft[@"markdown"]);
  for (id item in [draft[@"attachments"] isKindOfClass:NSArray.class] ? draft[@"attachments"] : @[]) {
    if (![item isKindOfClass:NSDictionary.class]) return NO;
    NSString *key = LBEditorString(item[@"key"]), *filename = LBEditorString(item[@"filename"]);
    if (![key hasPrefix:@"local_"] || ![key isEqualToString:key.lastPathComponent] ||
        !filename.length || ![filename isEqualToString:filename.lastPathComponent]) return NO;
    if (![body containsString:LBEditorAssetReference(_noteId, filename)]) continue;
    NSData *recovery = [NSData dataWithContentsOfFile:[[_draftPath stringByDeletingPathExtension] stringByAppendingPathComponent:key]];
    NSURL *url = [LBMdStore.shared readOnlyAssetURLForNote:_noteId filename:filename];
    NSData *current = url ? [NSData dataWithContentsOfURL:url] : nil;
    // Attachment metadata alone is not an edit when the referenced bytes are
    // already installed. Missing/conflicting recovery is never silently erased.
    if (!recovery.length || ![current isEqual:recovery]) return NO;
  }
  return YES;
}

- (void)checkLocalDraft {
  dispatch_sync(LBDraftQueue(), ^{}); // Let any pending snapshot from a previous editor land first.
  if (![NSFileManager.defaultManager fileExistsAtPath:_draftPath]) return;
  NSData *data = [NSData dataWithContentsOfFile:_draftPath];
  if (!data.length) return;
  NSDictionary *draft = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![draft isKindOfClass:NSDictionary.class]) return;

  NSString *draftBody = LBEditorString(draft[@"markdown"]);
  NSString *draftSummary = LBEditorString(draft[@"summary"]);
  if ([draftBody isEqualToString:_textView.text] && [LBEditorString(draft[@"title"]) isEqualToString:_titleField.text] &&
      [draftSummary isEqualToString:_summaryView.text ?: @""] &&
      [self draftAttachmentsMatchCurrentContent:draft] &&
      (!_hasSavedArticle || !draft[@"noteId"] || [draft[@"noteId"] isEqualToString:_noteId])) return;

  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"发现未提交的本地草稿"
                                                                 message:@"是否恢复上次由于意外关闭或未同步的内容？"
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"放弃草稿" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
    [self removeDraftFiles];
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"恢复草稿" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
    NSString *recoveredID = LBEditorString(draft[@"noteId"]);
    if (!self->_hasSavedArticle && recoveredID.length &&
        [recoveredID rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet.invertedSet].location == NSNotFound) {
      self->_noteId = recoveredID;
    }
    self->_titleField.text = LBEditorString(draft[@"title"]);
    self->_textView.text = draftBody;
    self->_placeholder.hidden = draftBody.length > 0;
    self->_summaryView.text = draftSummary;
    if (draftSummary.length) {
      [self updateSummaryToggle];
    }
    // A recovery snapshot contains unsaved text, never authority to publish.
    self->_ownsDraft = YES;
    [self restoreAttachmentsFromDraft:draft];
    [self contentChanged];
    [self updatePublicationActions];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreAttachmentsFromDraft:(NSDictionary *)draft {
  for (NSDictionary *item in [draft[@"attachments"] isKindOfClass:NSArray.class] ? draft[@"attachments"] : @[]) {
    if (![item isKindOfClass:NSDictionary.class]) continue;
    NSString *key = LBEditorString(item[@"key"]);
    NSString *filename = LBEditorString(item[@"filename"]);
    if (![key hasPrefix:@"local_"] || ![key isEqualToString:key.lastPathComponent] ||
        !filename.length || ![filename isEqualToString:filename.lastPathComponent]) { _ownsDraft = NO; continue; }
    NSData *data = [NSData dataWithContentsOfFile:[[self->_draftPath stringByDeletingPathExtension] stringByAppendingPathComponent:key]];
    if (!data.length) { _ownsDraft = NO; continue; }
    NSURL *destination = [[LBMdStore.shared assetsFolderForNote:_noteId] URLByAppendingPathComponent:filename];
    NSData *existing = destination ? [NSData dataWithContentsOfURL:destination] : nil;
    if (existing && ![existing isEqual:data]) {
      _ownsDraft = NO;
      [self showEditorError:@"附件恢复冲突" message:@"当前目录已有不同内容的同名附件，已保留原件。请重新选择附件后保存。"];
      continue;
    }
    // Existing baseline references with identical bytes were not edited by
    // recovery. Do not make an unrelated text edit impossible to undo to clean.
    if (existing && [LBEditorString(_contentBaseline[@"markdown"]) containsString:LBEditorAssetReference(_noteId, filename)]) continue;
    NSError *restoreError = nil;
    if (!destination || (!existing && ![data writeToURL:destination options:NSDataWritingAtomic error:&restoreError])) {
      _ownsDraft = NO;
      [self showEditorError:@"附件恢复失败" message:@"恢复副本仍保留在本地，请检查所选目录的访问权限。"];
      continue;
    }
    LBLocalAttachment *att = [LBLocalAttachment new];
    att.key = key;
    att.filename = filename;
    att.mime = LBEditorString(item[@"mime"]);
    att.isImage = [item[@"isImage"] boolValue];
    att.data = data;
    self->_localAttachments[key] = att;
  }
}

- (void)saveDraftToDisk {
  if (_closed) return;
  if (![self hasContentChanges]) { [self clearUnchangedDraft]; return; }
  [self writeDraftSnapshot];
}

- (void)writeDraftSnapshot {
  _ownsDraft = YES;
  NSMutableDictionary *draft = [NSMutableDictionary dictionary];
  draft[@"title"] = _titleField.text ?: @"";
  draft[@"markdown"] = _textView.text ?: @"";
  draft[@"summary"] = _summaryView.text ?: @"";
  draft[@"publish"] = @(_published);
  if (_noteId.length) draft[@"noteId"] = _noteId;
  NSMutableArray *attachments = [NSMutableArray array];
  NSMutableDictionary *attachmentData = [NSMutableDictionary dictionary];
  for (LBLocalAttachment *att in _localAttachments.allValues) {
    if (![_textView.text containsString:LBEditorAssetReference(_noteId, att.filename)]) continue;
    if (att.data.length) attachmentData[att.key] = att.data;
    [attachments addObject:@{@"key":att.key, @"filename":att.filename,
      @"mime":att.mime, @"isImage":@(att.isImage)}];
  }
  draft[@"attachments"] = attachments;
  draft[@"savedAt"] = [NSDate.date description];
  draft[@"savedAtMs"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000));

  // Snapshot on main (cheap), serialize + write off main: long articles no
  // longer stall typing every half second.
  NSString *path = [_draftPath copy];
  NSDictionary *snapshot = [draft copy];
  NSDictionary *mediaSnapshot = [attachmentData copy];
  dispatch_async(LBDraftQueue(), ^{
    // Undo-to-clean removes recovery files; Redo must recreate the referenced
    // copies. Existing immutable keys are not rewritten on every keystroke.
    NSString *mediaDir = [path stringByDeletingPathExtension];
    if (mediaSnapshot.count) [NSFileManager.defaultManager createDirectoryAtPath:mediaDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *key in mediaSnapshot) {
      NSString *file = [mediaDir stringByAppendingPathComponent:key];
      if (![NSFileManager.defaultManager fileExistsAtPath:file]) [mediaSnapshot[key] writeToFile:file atomically:YES];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    [data writeToFile:path atomically:YES];
  });
}

- (void)removeDraftFiles {
  NSString *path = [_draftPath copy];
  dispatch_async(LBDraftQueue(), ^{
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    [NSFileManager.defaultManager removeItemAtPath:[path stringByDeletingPathExtension] error:nil];
  });
}

- (void)contentChanged {
  _placeholder.hidden = _textView.text.length > 0;
  [_draftTimer invalidate];
  _draftTimer = nil;
  if (![self hasContentChanges]) { [self clearUnchangedDraft]; return; }
  _draftTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(saveDraftToDisk) userInfo:nil repeats:NO];
}

- (void)textViewDidEndEditing:(UITextView *)textView {
  if (textView == _summaryView) [self updateSummaryToggle];
  if (textView == _textView && _textView.inputView) {
    _textView.inputView = nil;
    UIButtonConfiguration *cfg = _formatButton.configuration;
    cfg.baseForegroundColor = LBTheme.ink;
    _formatButton.configuration = cfg;
  }
}

- (void)textViewDidChange:(UITextView *)textView {
  [self contentChanged];
  [self revealEditorCaret];
}

- (void)textViewDidChangeSelection:(UITextView *)textView {
  [self revealEditorCaret];
  if (textView == _textView && _textView.inputView) [self refreshFormatPanelState];
}

// Notes-like Return: continue the current list item; Return on an empty item
// ends the list instead of producing a dangling marker.
- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
  if (textView != _textView || ![text isEqualToString:@"\n"] || range.length || textView.markedTextRange) return YES;
  NSString *body = _textView.text;
  NSRange line = [body lineRangeForRange:NSMakeRange(range.location, 0)];
  NSUInteger lineEnd = NSMaxRange(line);
  if (lineEnd > line.location && [body characterAtIndex:lineEnd - 1] == '\n') lineEnd--;
  if (range.location != lineEnd) return YES; // only at the end of the line
  NSString *current = [body substringWithRange:NSMakeRange(line.location, lineEnd - line.location)];
  NSTextCheckingResult *m = [LBListMarker() firstMatchInString:current options:0 range:NSMakeRange(0, current.length)];
  if (!m) return YES;
  NSString *rest = [[current substringFromIndex:m.range.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if (!rest.length) {
    [self replaceBodyRange:NSMakeRange(line.location, current.length) withText:@"" selection:NSMakeRange(line.location, 0)];
    return NO;
  }
  NSString *indent = [current substringWithRange:[m rangeAtIndex:1]];
  NSString *marker = [current substringWithRange:[m rangeAtIndex:2]];
  if ([m rangeAtIndex:3].location != NSNotFound) {
    marker = [NSString stringWithFormat:@"%ld. ", (long)[[current substringWithRange:[m rangeAtIndex:3]] integerValue] + 1];
  } else if ([marker hasPrefix:@"- ["]) {
    marker = @"- [ ] ";
  }
  NSString *insert = [NSString stringWithFormat:@"\n%@%@", indent, marker];
  [self replaceBodyRange:range withText:insert selection:NSMakeRange(range.location + insert.length, 0)];
  return NO;
}

- (void)textViewDidBeginEditing:(UITextView *)textView {
  [self revealEditorCaret];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
  [_textView becomeFirstResponder];
  return NO;
}

#pragma mark - Notes-style toolbar and Aa format panel

- (UIButton *)toolIconButton:(NSString *)symbolName action:(SEL)sel accessibilityLabel:(NSString *)label {
  UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
  cfg.baseForegroundColor = LBTheme.ink;
  cfg.contentInsets = NSDirectionalEdgeInsetsZero;
  cfg.image = [UIImage systemImageNamed:symbolName withConfiguration:
      [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightRegular]];
  UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
  b.accessibilityLabel = label;
  b.pointerInteractionEnabled = YES;
  if (sel) [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
  [b addTarget:self action:@selector(toolTouched:) forControlEvents:UIControlEventTouchUpInside | UIControlEventMenuActionTriggered];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  [b.heightAnchor constraintEqualToConstant:44].active = YES;
  [b.widthAnchor constraintEqualToConstant:40].active = YES;
  return b;
}

// A single restrained bounce confirms the tap; Reduce Motion is honoured by UIKit.
- (void)toolTouched:(UIButton *)button {
  [button.imageView addSymbolEffect:[NSSymbolBounceEffect bounceUpEffect] options:[NSSymbolEffectOptions optionsWithNonRepeating]];
  [[UISelectionFeedbackGenerator new] selectionChanged];
}

- (UIButton *)toolMenuButton:(NSString *)symbolName menu:(UIMenu *)menu accessibilityLabel:(NSString *)label {
  UIButton *b = [self toolIconButton:symbolName action:nil accessibilityLabel:label];
  b.menu = menu;
  b.showsMenuAsPrimaryAction = YES;
  return b;
}

- (UIMenu *)calloutMenu {
  __weak typeof(self) weakSelf = self;
  NSArray *types = @[ @[@"NOTE", @"备注", @"info.circle"], @[@"TIP", @"提示", @"lightbulb"], @[@"IMPORTANT", @"重要", @"message"],
                      @[@"CAUTION", @"注意", @"exclamationmark.circle"], @[@"WARNING", @"警告", @"exclamationmark.triangle"] ];
  NSMutableArray *items = [NSMutableArray array];
  for (NSArray *t in types) {
    [items addObject:[UIAction actionWithTitle:t[1] image:[UIImage systemImageNamed:t[2]] identifier:nil handler:^(UIAction *a) {
      [weakSelf insertCallout:t[0] name:t[1]];
    }]];
  }
  return [UIMenu menuWithTitle:@"提示卡片 (Callout)" children:items];
}

- (UIMenu *)formulaMenu {
  __weak typeof(self) weakSelf = self;
  UIAction *fInline = [UIAction actionWithTitle:@"行内公式 ($ … $)" image:[UIImage systemImageNamed:@"character"] identifier:nil handler:^(UIAction *a) {
    [weakSelf wrapSelectionWithPrefix:@"$" suffix:@"$" placeholder:@"E = mc^2"];
  }];
  UIAction *fBlock = [UIAction actionWithTitle:@"独立公式块 ($$ … $$)" image:[UIImage systemImageNamed:@"function"] identifier:nil handler:^(UIAction *a) {
    [weakSelf wrapSelectionWithPrefix:@"\n$$\n" suffix:@"\n$$\n" placeholder:@"\\int_0^\\infty f(x)dx"];
  }];
  return [UIMenu menuWithTitle:@"LaTeX 数学公式" children:@[fInline, fBlock]];
}

- (UIMenu *)attachmentMenu {
  __weak typeof(self) weakSelf = self;
  UIAction *mPhoto = [UIAction actionWithTitle:@"照片" image:[UIImage systemImageNamed:@"photo.on.rectangle"] identifier:nil handler:^(UIAction *a) { [weakSelf pickPhoto]; }];
  UIAction *mVideo = [UIAction actionWithTitle:@"视频" image:[UIImage systemImageNamed:@"video"] identifier:nil handler:^(UIAction *a) { [weakSelf pickVideo]; }];
  UIAction *mAudio = [UIAction actionWithTitle:@"音频" image:[UIImage systemImageNamed:@"waveform"] identifier:nil handler:^(UIAction *a) { [weakSelf pickAudio]; }];
  UIAction *mFile = [UIAction actionWithTitle:@"文件" image:[UIImage systemImageNamed:@"doc"] identifier:nil handler:^(UIAction *a) { [weakSelf pickDocument]; }];
  UIAction *mLink = [UIAction actionWithTitle:@"链接" image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *a) { [weakSelf insertLink]; }];
  return [UIMenu menuWithTitle:@"" children:@[mPhoto, mVideo, mAudio, mFile, mLink]];
}

- (void)setupToolbarButtons {
  _formatButton = [self toolIconButton:@"textformat" action:@selector(toggleFormatPanel) accessibilityLabel:@"格式"];
  [_toolbarStack addArrangedSubview:_formatButton];
  [_toolbarStack addArrangedSubview:[self toolIconButton:@"checklist" action:@selector(toggleChecklist) accessibilityLabel:@"核对清单"]];
  [_toolbarStack addArrangedSubview:[self toolIconButton:@"tablecells" action:@selector(insertTable) accessibilityLabel:@"表格"]];
  [_toolbarStack addArrangedSubview:[self toolMenuButton:@"paperclip" menu:[self attachmentMenu] accessibilityLabel:@"附件"]];
  __weak typeof(self) weakSelf = self;
  UIMenu *ai = [UIMenu menuWithTitle:@"AI 写作助手" children:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
    [LBAI.shared checkConfigured:^(BOOL ready) {
      completion([weakSelf aiMenuElements:ready] ?: @[]);
    }];
  }]]];
  [_toolbarStack addArrangedSubview:[self toolMenuButton:@"sparkles" menu:ai accessibilityLabel:@"AI 写作助手"]];
  [_toolbarStack addArrangedSubview:[self toolIconButton:@"eye" action:@selector(previewPost) accessibilityLabel:@"预览文章"]];
  [_toolbarStack addArrangedSubview:[self toolIconButton:@"keyboard.chevron.compact.down" action:@selector(dismissKeyboard) accessibilityLabel:@"收起键盘"]];
}

// Notes-style pill: tinted rounded fill, optional title under a symbol.
- (UIButton *)panelButton:(NSString *)title symbol:(NSString *)symbol font:(UIFont *)font action:(void (^)(void))action {
  UIButtonConfiguration *cfg = [UIButtonConfiguration grayButtonConfiguration];
  cfg.baseForegroundColor = LBTheme.ink;
  cfg.cornerStyle = UIButtonConfigurationCornerStyleMedium;
  cfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 10, 8, 10);
  if (symbol) cfg.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightMedium]];
  if (title) {
    cfg.title = title;
    cfg.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *in) {
      NSMutableDictionary *out = [in mutableCopy]; out[NSFontAttributeName] = font; return out;
    };
  }
  UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) {
    [[UISelectionFeedbackGenerator new] selectionChanged];
    if (action) action();
  }]];
  b.accessibilityLabel = title ?: symbol;
  return b;
}

- (UIStackView *)panelRow:(NSArray<UIView *> *)views equal:(BOOL)equal {
  UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
  row.spacing = 8;
  row.distribution = equal ? UIStackViewDistributionFillEqually : UIStackViewDistributionFill;
  [row.heightAnchor constraintEqualToConstant:44].active = YES;
  return row;
}

- (void)buildFormatPanel {
  if (_formatPanel) return;
  _formatPanel = [[UIInputView alloc] initWithFrame:CGRectMake(0, 0, 0, 286) inputViewStyle:UIInputViewStyleKeyboard];
  _formatPanel.allowsSelfSizing = NO;
  __weak typeof(self) weakSelf = self;

  UILabel *title = [UILabel new];
  title.text = @"格式";
  title.font = [LBTheme rounded:17 weight:UIFontWeightBold];
  title.textColor = LBTheme.ink;
  UIButtonConfiguration *closeCfg = [UIButtonConfiguration plainButtonConfiguration];
  closeCfg.image = [UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular]];
  closeCfg.baseForegroundColor = LBTheme.muted;
  UIButton *close = [UIButton buttonWithConfiguration:closeCfg primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [weakSelf toggleFormatPanel]; }]];
  close.accessibilityLabel = @"关闭格式面板";
  UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, [UIView new], close]];

  // Paragraph styles: same order and naming spirit as Notes.
  NSArray *styles = @[ @[@"二级标题", @"## ", @19], @[@"三级标题", @"### ", @17], @[@"四级标题", @"#### ", @16], @[@"正文", @"", @15] ];
  NSMutableArray *styleButtons = [NSMutableArray array];
  for (NSArray *st in styles) {
    NSString *prefix = st[1];
    [styleButtons addObject:[self panelButton:st[0] symbol:nil font:[UIFont systemFontOfSize:[st[2] doubleValue] weight:prefix.length ? UIFontWeightBold : UIFontWeightRegular]
        action:^{ [weakSelf applyHeadingPrefix:prefix]; }]];
  }
  UIButton *mono = [self panelButton:@"代码块" symbol:nil font:[UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular] action:^{ [weakSelf insertCode]; }];
  [styleButtons addObject:mono];
  _styleButtons = styleButtons;
  UIScrollView *styleScroll = [UIScrollView new];
  styleScroll.showsHorizontalScrollIndicator = NO;
  UIStackView *styleRow = [[UIStackView alloc] initWithArrangedSubviews:styleButtons];
  styleRow.spacing = 8;
  styleRow.translatesAutoresizingMaskIntoConstraints = NO;
  [styleScroll addSubview:styleRow];
  [NSLayoutConstraint activateConstraints:@[
    [styleRow.topAnchor constraintEqualToAnchor:styleScroll.contentLayoutGuide.topAnchor],
    [styleRow.bottomAnchor constraintEqualToAnchor:styleScroll.contentLayoutGuide.bottomAnchor],
    [styleRow.leadingAnchor constraintEqualToAnchor:styleScroll.contentLayoutGuide.leadingAnchor],
    [styleRow.trailingAnchor constraintEqualToAnchor:styleScroll.contentLayoutGuide.trailingAnchor],
    [styleRow.heightAnchor constraintEqualToAnchor:styleScroll.frameLayoutGuide.heightAnchor],
    [styleScroll.heightAnchor constraintEqualToConstant:44]
  ]];

  UIStackView *inlineRow = [self panelRow:@[
    [self panelButton:nil symbol:@"bold" font:nil action:^{ [weakSelf insertBold]; }],
    [self panelButton:nil symbol:@"italic" font:nil action:^{ [weakSelf insertItalic]; }],
    [self panelButton:nil symbol:@"strikethrough" font:nil action:^{ [weakSelf insertStrikethrough]; }],
    [self panelButton:nil symbol:@"chevron.left.forwardslash.chevron.right" font:nil action:^{ [weakSelf wrapSelectionWithPrefix:@"`" suffix:@"`" placeholder:@"code"]; }],
    [self panelButton:nil symbol:@"link" font:nil action:^{ [weakSelf insertLink]; }] ] equal:YES];

  UIStackView *listRow = [self panelRow:@[
    [self panelButton:nil symbol:@"list.bullet" font:nil action:^{ [weakSelf toggleListMarker:@"- "]; }],
    [self panelButton:nil symbol:@"list.number" font:nil action:^{ [weakSelf toggleListMarker:@"1. "]; }],
    [self panelButton:nil symbol:@"checklist" font:nil action:^{ [weakSelf toggleListMarker:@"- [ ] "]; }],
    [self panelButton:nil symbol:@"text.quote" font:nil action:^{ [weakSelf toggleListMarker:@"> "]; }],
    [self panelButton:nil symbol:@"decrease.indent" font:nil action:^{ [weakSelf shiftIndent:NO]; }],
    [self panelButton:nil symbol:@"increase.indent" font:nil action:^{ [weakSelf shiftIndent:YES]; }] ] equal:YES];

  UIButton *callout = [self panelButton:@"提示卡片" symbol:@"exclamationmark.bubble" font:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium] action:nil];
  callout.menu = [self calloutMenu]; callout.showsMenuAsPrimaryAction = YES;
  UIButton *formula = [self panelButton:@"公式" symbol:@"function" font:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium] action:nil];
  formula.menu = [self formulaMenu]; formula.showsMenuAsPrimaryAction = YES;
  UIStackView *blockRow = [self panelRow:@[ callout, formula,
    [self panelButton:@"折叠" symbol:@"chevron.down.square" font:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium] action:^{ [weakSelf insertDetails]; }],
    [self panelButton:@"分割线" symbol:@"minus" font:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium] action:^{ [weakSelf insertTextAtCursor:@"\n---\n\n"]; }] ] equal:YES];
  for (UIButton *b in blockRow.arrangedSubviews) {
    UIButtonConfiguration *c = b.configuration; c.imagePlacement = NSDirectionalRectEdgeTop; c.imagePadding = 2; c.contentInsets = NSDirectionalEdgeInsetsMake(4, 4, 4, 4);
    c.image = [c.image imageByApplyingSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightMedium]];
    b.configuration = c;
  }

  UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header, styleScroll, inlineRow, listRow, blockRow]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 10;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [_formatPanel addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.topAnchor constraintEqualToAnchor:_formatPanel.topAnchor constant:12],
    [stack.leadingAnchor constraintEqualToAnchor:_formatPanel.safeAreaLayoutGuide.leadingAnchor constant:14],
    [stack.trailingAnchor constraintEqualToAnchor:_formatPanel.safeAreaLayoutGuide.trailingAnchor constant:-14],
  ]];
}

// Aa swaps the keyboard for the format panel (and back), like Notes.
- (void)toggleFormatPanel {
  BOOL showing = _textView.inputView != nil;
  if (showing) {
    _textView.inputView = nil;
  } else {
    [self buildFormatPanel];
    _textView.inputView = _formatPanel;
    [self refreshFormatPanelState];
  }
  UIButtonConfiguration *cfg = _formatButton.configuration;
  cfg.baseForegroundColor = showing ? LBTheme.ink : LBTheme.accent;
  _formatButton.configuration = cfg;
  if (_textView.isFirstResponder) [_textView reloadInputViews];
  else [_textView becomeFirstResponder];
}

- (void)refreshFormatPanelState {
  if (!_styleButtons.count) return;
  NSString *text = _textView.text ?: @"";
  NSRange line = [text lineRangeForRange:NSMakeRange(MIN(_textView.selectedRange.location, text.length), 0)];
  NSString *current = [text substringWithRange:line];
  NSInteger level = 0;
  while (level < (NSInteger)current.length && level < 6 && [current characterAtIndex:level] == '#') level++;
  if (level >= (NSInteger)current.length || [current characterAtIndex:level] != ' ') level = 0;
  NSInteger selected = level == 0 ? 3 : (level >= 2 && level <= 4 ? level - 2 : -1);
  [_styleButtons enumerateObjectsUsingBlock:^(UIButton *b, NSUInteger i, BOOL *stop) {
    if (i > 3) return;
    UIButtonConfiguration *c = b.configuration;
    c.baseBackgroundColor = (NSInteger)i == selected ? [LBTheme.accent colorWithAlphaComponent:0.22] : nil;
    c.baseForegroundColor = (NSInteger)i == selected ? LBTheme.accent : LBTheme.ink;
    b.configuration = c;
  }];
}

// Rewrites every line touched by the selection in one undoable edit.
- (void)transformSelectedLines:(NSString *(^)(NSString *line, NSUInteger index))transform {
  NSString *text = _textView.text ?: @"";
  NSRange sel = _textView.selectedRange;
  if (NSMaxRange(sel) > text.length) sel = NSMakeRange(text.length, 0);
  NSRange block = [text lineRangeForRange:sel];
  NSString *original = [text substringWithRange:block];
  BOOL trailingNewline = [original hasSuffix:@"\n"];
  NSString *core = trailingNewline ? [original substringToIndex:original.length - 1] : original;
  NSArray<NSString *> *lines = [core componentsSeparatedByString:@"\n"];
  NSMutableArray *out = [NSMutableArray arrayWithCapacity:lines.count];
  [lines enumerateObjectsUsingBlock:^(NSString *line, NSUInteger i, BOOL *stop) { [out addObject:transform(line, i)]; }];
  NSString *replacement = [[out componentsJoinedByString:@"\n"] stringByAppendingString:trailingNewline ? @"\n" : @""];
  NSInteger firstDelta = (NSInteger)[out.firstObject length] - (NSInteger)lines.firstObject.length;
  NSRange selection;
  if (sel.length) {
    selection = NSMakeRange(block.location, replacement.length - (trailingNewline ? 1 : 0));
  } else {
    NSInteger caret = (NSInteger)sel.location + firstDelta;
    selection = NSMakeRange((NSUInteger)MAX((NSInteger)block.location, caret), 0);
  }
  [self replaceBodyRange:block withText:replacement selection:selection];
}

static NSString *LBStripHeading(NSString *line) {
  NSUInteger i = 0;
  while (i < line.length && i < 6 && [line characterAtIndex:i] == '#') i++;
  if (i && i < line.length && [line characterAtIndex:i] == ' ') return [line substringFromIndex:i + 1];
  return line;
}

- (void)applyHeadingPrefix:(NSString *)prefix {
  [self transformSelectedLines:^NSString *(NSString *line, NSUInteger index) {
    // Tapping the active style again returns the line to body text.
    if (prefix.length && [line hasPrefix:prefix] && ![[line substringFromIndex:prefix.length] hasPrefix:@"#"]) return LBStripHeading(line);
    return [prefix stringByAppendingString:LBStripHeading(line)];
  }];
  [self refreshFormatPanelState];
}

- (void)toggleListMarker:(NSString *)marker {
  NSString *text = _textView.text ?: @"";
  NSRange block = [text lineRangeForRange:_textView.selectedRange];
  NSArray *lines = [[text substringWithRange:block] componentsSeparatedByString:@"\n"];
  BOOL numbered = [marker isEqualToString:@"1. "];
  // Toggle off only when every non-empty line already carries this marker.
  BOOL allMarked = YES;
  for (NSString *line in lines) {
    if (!line.length) continue;
    NSTextCheckingResult *m = [LBListMarker() firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    NSString *existing = m ? [line substringWithRange:[m rangeAtIndex:2]] : nil;
    BOOL same = numbered ? (m && [m rangeAtIndex:3].location != NSNotFound)
                         : [existing isEqualToString:marker] || ([marker hasPrefix:@"- ["] && [existing hasPrefix:@"- ["]);
    if (!same) { allMarked = NO; break; }
  }
  [self transformSelectedLines:^NSString *(NSString *line, NSUInteger index) {
    if (!line.length && lines.count > 1) return line;
    NSTextCheckingResult *m = [LBListMarker() firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    NSString *indent = m ? [line substringWithRange:[m rangeAtIndex:1]] : @"";
    NSString *content = m ? [line substringFromIndex:m.range.length] : [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!m) {
      NSUInteger firstContent = [line rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet.invertedSet].location;
      indent = [line substringToIndex:firstContent == NSNotFound ? line.length : firstContent];
    }
    if (allMarked) return [indent stringByAppendingString:content];
    NSString *prefix = numbered ? [NSString stringWithFormat:@"%lu. ", (unsigned long)index + 1] : marker;
    return [NSString stringWithFormat:@"%@%@%@", indent, prefix, content];
  }];
}

- (void)toggleChecklist { [self toggleListMarker:@"- [ ] "]; }

- (void)shiftIndent:(BOOL)increase {
  [self transformSelectedLines:^NSString *(NSString *line, NSUInteger index) {
    if (increase) return line.length ? [@"  " stringByAppendingString:line] : line;
    if ([line hasPrefix:@"  "]) return [line substringFromIndex:2];
    if ([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) return [line substringFromIndex:1];
    return line;
  }];
}

#pragma mark - AI writing assistant

- (NSString *)aiClip:(NSString *)text {
  return text.length > LBAIMaxInput ? [[text substringToIndex:LBAIMaxInput] stringByAppendingString:@"\n\n（后文过长已省略）"] : text;
}

- (NSArray<UIMenuElement *> *)aiMenuElements:(BOOL)configured {
  __weak typeof(self) weakSelf = self;
  if (!configured) {
    return @[[UIAction actionWithTitle:@"配置 AI 写作助手…" image:[UIImage systemImageNamed:@"gearshape"] identifier:nil handler:^(UIAction *a) {
      if (weakSelf) LBPresentSettings(weakSelf);
    }]];
  }
  NSRange sel = _textView.selectedRange;
  BOOL hasSelection = sel.length > 0 && NSMaxRange(sel) <= _textView.text.length;
  NSCharacterSet *nonWhitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet.invertedSet;
  BOOL hasBody = [_textView.textStorage.string rangeOfCharacterFromSet:nonWhitespace].location != NSNotFound;
  BOOL hasSummary = [_summaryView.textStorage.string rangeOfCharacterFromSet:nonWhitespace].location != NSNotFound;

  UIAction *summary = [UIAction actionWithTitle:@"生成摘要" image:[UIImage systemImageNamed:@"text.quote"] identifier:nil handler:^(UIAction *a) { [weakSelf aiGenerateSummary]; }];
  summary.subtitle = @"根据标题和正文写一段列表摘要";
  UIAction *polishSummary = [UIAction actionWithTitle:@"润色摘要" image:[UIImage systemImageNamed:@"wand.and.sparkles"] identifier:nil handler:^(UIAction *a) { [weakSelf aiPolishSummary]; }];
  UIAction *polish = [UIAction actionWithTitle:hasSelection ? @"润色所选文字" : @"润色全文" image:[UIImage systemImageNamed:@"wand.and.stars"] identifier:nil handler:^(UIAction *a) { [weakSelf aiPolishBody]; }];
  polish.subtitle = @"修正错别字和语病，保留结构与 Markdown";
  UIAction *continueWriting = [UIAction actionWithTitle:@"从光标处续写" image:[UIImage systemImageNamed:@"text.append"] identifier:nil handler:^(UIAction *a) { [weakSelf aiContinue]; }];
  UIAction *custom = [UIAction actionWithTitle:@"自定义指令…" image:[UIImage systemImageNamed:@"text.bubble"] identifier:nil handler:^(UIAction *a) { [weakSelf aiCustom]; }];
  if (!hasBody) { summary.attributes = UIMenuElementAttributesDisabled; polish.attributes = UIMenuElementAttributesDisabled; }
  if (!hasSummary) polishSummary.attributes = UIMenuElementAttributesDisabled;
  UIMenu *summaryGroup = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[summary, polishSummary]];
  UIMenu *bodyGroup = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[polish, continueWriting, custom]];
  return @[summaryGroup, bodyGroup];
}

- (void)presentAI:(NSString *)title applyTitle:(NSString *)applyTitle prompt:(NSString *)prompt apply:(void (^)(NSString *))apply {
  if (_saving || _closed) return;
  [_textView unmarkText];
  LBAIResultViewController *vc = [[LBAIResultViewController alloc] initWithTitle:title applyTitle:applyTitle
      system:LBAISystemPrompt prompt:prompt apply:apply];
  LBNavigationController *nav = [[LBNavigationController alloc] initWithRootViewController:vc];
  nav.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
  nav.sheetPresentationController.prefersGrabberVisible = YES;
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)applyAISummary:(NSString *)text {
  _summaryView.text = text;
  [self updateSummaryToggle];
  if (!_summaryExpanded) [self toggleSummary];
  [self contentChanged];
}

- (void)aiGenerateSummary {
  NSString *prompt = [NSString stringWithFormat:@"请为下面这篇博客文章写一段用于文章列表的摘要：80～150 字，一段话，自然克制，不使用 Markdown，不以“本文”开头。\n\n标题：%@\n\n正文：\n%@",
      _titleField.text ?: @"", [self aiClip:_textView.text ?: @""]];
  __weak typeof(self) weakSelf = self;
  [self presentAI:@"生成摘要" applyTitle:@"填入摘要" prompt:prompt apply:^(NSString *text) { [weakSelf applyAISummary:text]; }];
}

- (void)aiPolishSummary {
  NSString *prompt = [NSString stringWithFormat:@"润色下面这段博客文章摘要：保持原意和长度相近，语言更流畅精炼，不使用 Markdown。\n\n文章标题：%@\n\n摘要：\n%@",
      _titleField.text ?: @"", _summaryView.text ?: @""];
  __weak typeof(self) weakSelf = self;
  [self presentAI:@"润色摘要" applyTitle:@"替换摘要" prompt:prompt apply:^(NSString *text) { [weakSelf applyAISummary:text]; }];
}

// Replaces `range` only if it still holds the exact original text; otherwise
// inserts at the caret so a concurrent edit is never overwritten.
- (void)applyAIText:(NSString *)text replacing:(NSRange)range original:(NSString *)original {
  NSString *body = _textView.text ?: @"";
  if (NSMaxRange(range) <= body.length && [[body substringWithRange:range] isEqualToString:original ?: @""]) {
    [self replaceBodyRange:range withText:text selection:NSMakeRange(range.location, text.length)];
  } else {
    [self insertTextAtCursor:text];
  }
}

- (void)aiPolishBody {
  NSString *body = _textView.text ?: @"";
  NSRange range = _textView.selectedRange;
  if (!range.length || NSMaxRange(range) > body.length) range = NSMakeRange(0, body.length);
  if (range.length > LBAIMaxInput) {
    [self showEditorError:@"内容过长" message:@"一次最多润色约 3 万字。请先选中要润色的段落。"];
    return;
  }
  NSString *original = [body substringWithRange:range];
  NSString *prompt = [NSString stringWithFormat:@"润色下面的 Markdown 文本：修正错别字和语病，让表达更流畅自然；保持作者的语气、段落结构、所有 Markdown 语法与信息不变，不要增删观点。\n\n%@", original];
  BOOL whole = range.length == body.length;
  __weak typeof(self) weakSelf = self;
  [self presentAI:whole ? @"润色全文" : @"润色所选文字" applyTitle:whole ? @"替换全文" : @"替换所选" prompt:prompt apply:^(NSString *text) {
    [weakSelf applyAIText:text replacing:range original:original];
  }];
}

- (void)aiContinue {
  NSString *body = _textView.text ?: @"";
  NSUInteger caret = MIN(NSMaxRange(_textView.selectedRange), body.length);
  NSString *before = [body substringToIndex:caret];
  if (before.length > LBAIMaxInput) before = [before substringFromIndex:before.length - LBAIMaxInput];
  NSString *prompt = [NSString stringWithFormat:@"下面是一篇博客文章（Markdown）在光标之前的内容。请顺着作者的语气和思路续写 1～3 段，只输出新增的内容，保持 Markdown。\n\n标题：%@\n\n%@",
      _titleField.text ?: @"", before];
  NSRange insertion = NSMakeRange(caret, 0);
  __weak typeof(self) weakSelf = self;
  [self presentAI:@"续写" applyTitle:@"插入" prompt:prompt apply:^(NSString *text) {
    NSString *glue = caret > 0 && ![before hasSuffix:@"\n"] ? @"\n\n" : @"";
    [weakSelf applyAIText:[glue stringByAppendingString:text] replacing:insertion original:@""];
  }];
}

- (void)aiCustom {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AI 自定义指令"
      message:_textView.selectedRange.length ? @"将作用于选中的文字，结果替换所选内容。" : @"以全文为参考，结果插入到光标处。"
      preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"例如：改写成更口语化的语气"; }];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  __weak typeof(self) weakSelf = self;
  __weak UIAlertController *weakAlert = alert;
  [alert addAction:[UIAlertAction actionWithTitle:@"生成" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
    NSString *instruction = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (instruction.length) [weakSelf aiRunCustom:instruction];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)aiRunCustom:(NSString *)instruction {
  NSString *body = _textView.text ?: @"";
  NSRange range = _textView.selectedRange;
  if (range.location > body.length || range.length > body.length - range.location) range = NSMakeRange(body.length, 0);
  if (range.length > LBAIMaxInput) {
    [self showEditorError:@"内容过长" message:@"一次最多处理约 3 万字。请先缩小选中的文字范围。"];
    return;
  }
  NSString *original = [body substringWithRange:range];
  NSString *prompt = range.length
      ? [NSString stringWithFormat:@"指令：%@\n\n请按指令处理下面选中的文字，只输出处理后的文字：\n\n%@", instruction, original]
      : [NSString stringWithFormat:@"指令：%@\n\n以下是文章标题与全文，仅作参考；请只输出可以直接插入光标处的内容。\n\n标题：%@\n\n%@", instruction, _titleField.text ?: @"", [self aiClip:body]];
  __weak typeof(self) weakSelf = self;
  [self presentAI:@"自定义指令" applyTitle:range.length ? @"替换所选" : @"插入" prompt:prompt apply:^(NSString *text) {
    [weakSelf applyAIText:text replacing:range original:original];
  }];
}

- (void)wrapSelectionWithPrefix:(NSString *)prefix suffix:(NSString *)suffix placeholder:(NSString *)ph {
  NSRange sel = _textView.selectedRange;
  NSString *text = _textView.text ?: @"";
  if (sel.location > text.length || sel.length > text.length - sel.location) {
    sel = NSMakeRange(text.length, 0);
  }
  if (sel.length > 0) {
    NSString *selected = [text substringWithRange:sel];
    NSString *rep = [NSString stringWithFormat:@"%@%@%@", prefix, selected, suffix];
    [self replaceBodyRange:sel withText:rep selection:NSMakeRange(sel.location + rep.length, 0)];
  } else {
    NSString *rep = [NSString stringWithFormat:@"%@%@%@", prefix, ph, suffix];
    [self replaceBodyRange:sel withText:rep selection:NSMakeRange(sel.location + prefix.length, ph.length)];
  }
}

- (void)insertBold { [self wrapSelectionWithPrefix:@"**" suffix:@"**" placeholder:@"粗体文本"]; }
- (void)insertItalic { [self wrapSelectionWithPrefix:@"*" suffix:@"*" placeholder:@"斜体文本"]; }

- (void)insertCode {
  NSRange sel = _textView.selectedRange;
  NSString *body = _textView.text ?: @"";
  if (sel.location > body.length || sel.length > body.length - sel.location) sel = NSMakeRange(body.length, 0);
  NSString *selected = [body substringWithRange:sel];
  // Always a fenced block, including a one-line selection. A longer fence
  // preserves pasted Markdown snippets containing their own backticks.
  NSMutableString *fence = [NSMutableString stringWithString:@"```"];
  while ([selected containsString:fence]) [fence appendString:@"`"];
  NSString *prefix = [NSString stringWithFormat:@"\n%@\n", fence];
  NSString *suffix = [NSString stringWithFormat:@"\n%@\n", fence];
  [self wrapSelectionWithPrefix:prefix suffix:suffix placeholder:@"// 代码在此"];
}

- (void)dismissKeyboard {
  [self.view endEditing:YES];
}

- (void)handleBackgroundTap:(UITapGestureRecognizer *)g {
  CGPoint pt = [g locationInView:self.view];
  if (!CGRectContainsPoint(_textView.frame, pt) &&
      !CGRectContainsPoint(_dock.frame, pt) &&
      !CGRectContainsPoint(_summaryContainer.frame, pt) &&
      !CGRectContainsPoint(_titleField.frame, pt)) {
    [self.view endEditing:YES];
  }
}

- (void)insertStrikethrough { [self wrapSelectionWithPrefix:@"~~" suffix:@"~~" placeholder:@"删除线文本"]; }

- (void)insertLink {
  NSRange sel = _textView.selectedRange;
  if (sel.length > 0) {
    [self wrapSelectionWithPrefix:@"[" suffix:@"](https://)" placeholder:@"链接描述"];
  } else {
    [self insertTextAtCursor:@"[链接描述](https://example.com)"];
  }
}

- (void)insertTable {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"插入表格" message:@"请指定表格的行数与列数（不含表头）：" preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.placeholder = @"行数（默认 3）";
    tf.text = @"3";
    tf.keyboardType = UIKeyboardTypeNumberPad;
  }];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.placeholder = @"列数（默认 3）";
    tf.text = @"3";
    tf.keyboardType = UIKeyboardTypeNumberPad;
  }];
  __weak typeof(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"插入表格" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
    NSInteger rows = [alert.textFields[0].text integerValue];
    NSInteger cols = [alert.textFields[1].text integerValue];
    if (rows <= 0) rows = 3;
    if (cols <= 0) cols = 3;
    if (rows > 50) rows = 50;
    if (cols > 20) cols = 20;

    NSMutableString *table = [NSMutableString stringWithString:@"\n|"];
    for (NSInteger c = 1; c <= cols; c++) [table appendFormat:@" 列 %ld |", (long)c];
    [table appendString:@"\n|"];
    for (NSInteger c = 1; c <= cols; c++) [table appendString:@" :--- |"];
    for (NSInteger r = 1; r <= rows; r++) {
      [table appendString:@"\n|"];
      for (NSInteger c = 1; c <= cols; c++) [table appendFormat:@" 内容 %ld-%ld |", (long)r, (long)c];
    }
    [table appendString:@"\n\n"];
    [weakSelf insertTextAtCursor:table];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)insertCallout:(NSString *)type name:(NSString *)name {
  NSString *tpl = [NSString stringWithFormat:@"\n> [!%@]\n> 这里输入%@内容\n\n", type.uppercaseString, name];
  [self insertTextAtCursor:tpl];
}

- (void)insertDetails {
  [self insertTextAtCursor:@"\n<details class=\"trilium-collapsible\">\n<summary>折叠标题</summary>\n<p>折叠内容</p>\n</details>\n\n"];
}

- (void)insertTextAtCursor:(NSString *)text {
  NSRange sel = _textView.selectedRange;
  [self replaceBodyRange:sel withText:text selection:NSMakeRange(sel.location + text.length, 0)];
}

// Edits the body in place: assigning `text` reset the scroll offset, dropped undo
// and forced a full relayout of long articles on every toolbar tap.
- (void)replaceBodyRange:(NSRange)range withText:(NSString *)text selection:(NSRange)selection {
  NSUInteger length = _textView.text.length;
  if (range.location > length) range = NSMakeRange(length, 0);
  if (NSMaxRange(range) > length) range.length = length - range.location;
  UITextPosition *start = [_textView positionFromPosition:_textView.beginningOfDocument offset:(NSInteger)range.location];
  UITextPosition *end = start ? [_textView positionFromPosition:start offset:(NSInteger)range.length] : nil;
  UITextRange *target = end ? [_textView textRangeFromPosition:start toPosition:end] : nil;
  if (target) {
    [_textView replaceRange:target withText:text ?: @""];
  } else {
    _textView.text = [_textView.text stringByReplacingCharactersInRange:range withString:text ?: @""];
  }
  NSUInteger newLength = _textView.text.length;
  if (selection.location > newLength) selection = NSMakeRange(newLength, 0);
  if (NSMaxRange(selection) > newLength) selection.length = newLength - selection.location;
  _textView.selectedRange = selection;
  [self contentChanged];
  [self revealEditorCaret];
}

#pragma mark - Attachments Picking (Secondary Menu Actions)

- (void)pickPhoto {
  PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
  config.filter = [PHPickerFilter imagesFilter];
  config.selectionLimit = 1;
  PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
  picker.delegate = self;
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)pickVideo {
  PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
  config.filter = [PHPickerFilter videosFilter];
  config.selectionLimit = 1;
  PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
  picker.delegate = self;
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)pickAudio {
  UIDocumentPickerViewController *doc = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeAudio] asCopy:YES];
  doc.delegate = self;
  [self presentViewController:doc animated:YES completion:nil];
}

- (void)pickDocument {
  UIDocumentPickerViewController *doc = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
  doc.delegate = self;
  [self presentViewController:doc animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
  [picker dismissViewControllerAnimated:YES completion:nil];
  if (!results.count) return;
  PHPickerResult *res = results.firstObject;

  BOOL isMovie = [res.itemProvider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier];
  UTType *mediaType = isMovie ? UTTypeMovie : UTTypeImage;
  for (NSString *identifier in res.itemProvider.registeredTypeIdentifiers) {
    UTType *candidate = [UTType typeWithIdentifier:identifier];
    if ([candidate conformsToType:mediaType] && candidate.preferredFilenameExtension.length) {
      mediaType = candidate;
      break;
    }
  }
  NSString *typeId = mediaType.identifier;
  NSString *ext = mediaType.preferredFilenameExtension ?: (isMovie ? @"mov" : @"jpg");
  NSString *mime = mediaType.preferredMIMEType ?: (isMovie ? @"video/quicktime" : @"image/jpeg");

  NSUInteger generation = ++_attachmentGeneration;
  NSString *noteId = [_noteId copy];
  __weak typeof(self) weakSelf = self;
  [res.itemProvider loadDataRepresentationForTypeIdentifier:typeId completionHandler:^(NSData *data, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      LBPostEditor *editor = weakSelf;
      if (!editor || editor->_closed || editor->_saving || generation != editor->_attachmentGeneration || ![editor->_noteId isEqualToString:noteId]) return;
      if (!data.length) {
        editor->_operationStatusLabel.hidden = NO;
        editor->_operationStatusLabel.text = error.localizedDescription ?: @"附件读取失败，正文未改动";
        return;
      }
      NSString *fname = [NSString stringWithFormat:@"media_%@.%@", [NSUUID.UUID.UUIDString substringToIndex:8], ext];
      [editor registerLocalAttachment:data filename:fname mime:mime isImage:!isMovie];
    });
  }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  if (!urls.count) return;
  NSURL *url = urls.firstObject;
  NSData *data = [NSData dataWithContentsOfURL:url];
  if (!data.length) return;
  NSString *fname = url.lastPathComponent ?: @"attachment";
  NSString *ext = url.pathExtension.lowercaseString;
  UTType *fileType = [UTType typeWithFilenameExtension:ext];
  BOOL isImg = [fileType conformsToType:UTTypeImage];
  NSString *mime = fileType.preferredMIMEType ?: @"application/octet-stream";
  [self registerLocalAttachment:data filename:fname mime:mime isImage:isImg];
}

- (void)registerLocalAttachment:(NSData *)data filename:(NSString *)filename mime:(NSString *)mime isImage:(BOOL)isImage {
  if (_saving || !data.length) return;
  filename = LBEditorString(filename).lastPathComponent;
  if (!filename.length || [filename isEqualToString:@"."] || [filename isEqualToString:@".."]) filename = @"attachment";
  NSString *key = [NSString stringWithFormat:@"local_%@", NSUUID.UUID.UUIDString];
  NSURL *assetsDir = [LBMdStore.shared assetsFolderForNote:_noteId];
  if (!assetsDir) {
    [self showEditorError:@"附件目录不可用" message:@"请重新选择文章工作区或检查目录权限；附件未插入正文。"];
    return;
  }
  if ([NSFileManager.defaultManager fileExistsAtPath:[assetsDir URLByAppendingPathComponent:filename].path]) {
    filename = [NSString stringWithFormat:@"%@_%@%@%@", filename.stringByDeletingPathExtension,
        [NSUUID.UUID.UUIDString substringToIndex:8], filename.pathExtension.length ? @"." : @"", filename.pathExtension];
  }
  NSError *writeError = nil;
  if (![data writeToURL:[assetsDir URLByAppendingPathComponent:filename] options:NSDataWritingAtomic error:&writeError]) {
    [self showEditorError:@"附件保存失败" message:writeError.localizedDescription];
    return;
  }
  LBLocalAttachment *att = [LBLocalAttachment new];
  att.key = key;
  att.filename = filename;
  att.mime = mime;
  att.data = data;
  att.isImage = isImage;
  _localAttachments[key] = att;

  // Order media-cache writes with snapshot writes and revert cleanup too: a
  // queued clean-up must not delete a newly inserted attachment's recovery copy.
  NSString *mediaDir = [_draftPath stringByDeletingPathExtension];
  NSData *recoveryBytes = [data copy];
  dispatch_async(LBDraftQueue(), ^{
    [NSFileManager.defaultManager createDirectoryAtPath:mediaDir withIntermediateDirectories:YES attributes:nil error:nil];
    [recoveryBytes writeToFile:[mediaDir stringByAppendingPathComponent:key] atomically:YES];
  });

  NSString *canonicalURL = LBEditorAssetReference(_noteId, filename);
  NSString *label = [[filename stringByReplacingOccurrencesOfString:@"[" withString:@"\\["] stringByReplacingOccurrencesOfString:@"]" withString:@"\\]"];
  NSString *ref = isImage ? [NSString stringWithFormat:@"\n![%@](%@)\n", label, canonicalURL]
                          : [NSString stringWithFormat:@"\n[%@](%@)\n", label, canonicalURL];
  NSRange sel = _textView.selectedRange;
  [self replaceBodyRange:sel withText:ref selection:NSMakeRange(sel.location + ref.length, 0)];
}

#pragma mark - Preview with Full Image Support

- (void)previewPost {
  NSString *title = _titleField.text.length ? _titleField.text : @"预览文章";
  // Attachments were persisted on insertion. The Reader resolves them through
  // its read-only capability instead of converting every image to base64 again.
  NSString *markdown = _textView.text ?: @"";
  // Preview opens where the author is: the caret while editing, otherwise the
  // first visible character of the editor viewport.
  NSUInteger focus = _textView.selectedRange.location;
  if (!_textView.isFirstResponder) {
    CGPoint top = CGPointMake(_textView.textContainerInset.left + 4,
        _textView.contentOffset.y + _textView.textContainerInset.top + 4);
    UITextPosition *visible = [_textView closestPositionToPoint:top];
    focus = visible ? (NSUInteger)MAX(0, [_textView offsetFromPosition:_textView.beginningOfDocument toPosition:visible]) : 0;
  }
  focus = MIN(focus, markdown.length);
  NSDictionary *stored = [LBMdStore.shared loadArticle:_noteId];
  // The stored Markdown body is the only source, including embedded HTML.
  // Keep its format marker during edits; the store owns format classification on save.
  NSString *bodyFormat = LBEditorString(stored[@"bodyFormat"]);
  if (!bodyFormat.length) bodyFormat = LBEditorString(_original[@"bodyFormat"]);
  if (!bodyFormat.length) bodyFormat = @"markdown";
  long long now = (long long)(NSDate.date.timeIntervalSince1970 * 1000);
  NSString *anchor = @"";
  double ratio = 0;
  if ([bodyFormat isEqualToString:@"html"]) {
    // Raw HTML bodies cannot take an injected paragraph safely; use source position.
    ratio = markdown.length ? (double)focus / (double)markdown.length : 0;
  } else {
    anchor = [NSString stringWithFormat:@"LBCARET%08X", arc4random()];
    markdown = LBPreviewMarkdownWithAnchor(markdown, focus, anchor);
    if ([markdown rangeOfString:anchor].location == NSNotFound) anchor = @"";
  }
  NSDictionary *mockPost = @{
    @"id": _noteId ?: @"preview",
    @"title": title,
    @"summary": _summaryView.text ?: @"",
    @"bodyFormat": bodyFormat,
    @"markdown": markdown,
    @"tags": @[],
    @"isEditorPreview": @YES,
    @"previewAnchor": anchor,
    @"previewRatio": @(ratio),
    @"createdAt": stored[@"createdAt"] ?: @(now),
    @"publishedAt": stored[@"publishedAt"] ?: @0,
    @"updatedAt": @(now),
    @"publish": @(_published)
  };

  LBPostReaderViewController *reader = [[LBPostReaderViewController alloc] initWithPost:mockPost];
  LBNavigationController *nav = [[LBNavigationController alloc] initWithRootViewController:reader];
  [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Save / Cancel

- (void)presentationControllerDidAttemptToDismiss:(UIPresentationController *)presentationController {
  [self cancelPressed];
}

- (void)cancelPressed {
  if (_saving || _closed) return;
  [self.view endEditing:YES];
  if ([self hasContentChanges]) {
    [self saveDraftToDisk];
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"放弃此次修改？" message:@"本地草稿已妥善保存，随时可以恢复。" preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"继续编辑" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
      self->_closed = YES;
      ++self->_attachmentGeneration;
      [self dismissViewControllerAnimated:YES completion:nil];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
  } else {
    [self clearUnchangedDraft];
    [_draftTimer invalidate];
    _draftTimer = nil;
    _closed = YES;
    ++_attachmentGeneration;
    [self dismissViewControllerAnimated:YES completion:nil];
  }
}

- (void)showEditorError:(NSString *)title message:(NSString *)message {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)persistCurrentArticle {
  if (_hasSavedArticle && ![self hasContentChanges]) return YES;
  NSString *title = [LBEditorString(_titleField.text) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!title.length) {
    [self showEditorError:@"请填写文章标题" message:nil];
    return NO;
  }
  [self saveDraftToDisk]; // Always snapshot before a potentially failing write.
  // A supplied, not-yet-saved local article may be unchanged in the UI but still
  // needs a recovery snapshot when its first explicit save fails.
  if (!_hasSavedArticle && ![self hasContentChanges]) [self writeDraftSnapshot];
  NSError *error = nil;
  // Saving text is NOT a publication-state transition.
  BOOL ok = [LBMdStore.shared saveArticleWithId:_noteId title:title
      markdown:_textView.text ?: @"" summary:_summaryView.text ?: @""
      publish:_published tags:[_original[@"tags"] isKindOfClass:NSArray.class] ? _original[@"tags"] : nil error:&error];
  if (!ok) {
    [self showEditorError:@"本地保存失败" message:error.localizedDescription ?: @"内容仍保留在恢复草稿中，请检查文章目录后重试。"];
    return NO;
  }
  _hasSavedArticle = YES;
  _contentBaseline = [self contentSnapshot];
  _dirty = NO;
  [_draftTimer invalidate];
  _draftTimer = nil;
  [self updatePublicationActions];
  return YES;
}

- (void)finishSuccessfulSave {
  [_draftTimer invalidate];
  _draftTimer = nil;
  _dirty = NO;
  [self removeDraftFiles];
  NSDictionary *post = [LBMdStore.shared loadArticle:_noteId];
  if (!post) post = @{@"id":_noteId, @"title":_titleField.text ?: @"", @"publish":@(_published), @"markdown":_textView.text ?: @"", @"summary":_summaryView.text ?: @"", @"isLocalDraft":@(!_published)};
  NSString *message = _completionMessage ?: @"草稿保存成功";
  [NSNotificationCenter.defaultCenter postNotificationName:LBPostEditorDidFinish object:self userInfo:@{@"message": message}];
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
  _closed = YES;
  ++_attachmentGeneration;
  if (_saved) _saved(post);
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)savePressed {
  if (_saving) return;
  if (_closed) return;
  [self.view endEditing:YES];
  if (_hasSavedArticle && ![self hasContentChanges]) {
    [self cancelPressed]; // No timestamp rewrite, modified badge or remote save.
    return;
  }
  _completionMessage = nil;
  ++_attachmentGeneration;
  if (_published) { [self performPublicationToPublished:YES]; return; }
  if (![self persistCurrentArticle]) return;
  [self finishSuccessfulSave];
}

- (void)publicationPressed {
  if (_saving || _closed) return;
  BOOL previousPublish = _published;
  BOOL targetPublish = !previousPublish;
  // Persist text under its current publication state; saveArticle deliberately
  // does not own publication transitions for existing articles.
  if (![self persistCurrentArticle]) return;
  NSError *error = nil;
  BOOL staged = targetPublish ? [LBMdStore.shared stagePublishArticle:_noteId error:&error]
                              : [LBMdStore.shared stageUnpublishArticle:_noteId error:&error];
  if (!staged) {
    _published = previousPublish;
    [self updatePublicationActions];
    [self showEditorError:@"暂存状态失败" message:error.localizedDescription ?: @"正文已保存在本地，请检查目录权限后重试。"];
    return;
  }
  _published = targetPublish;
  _completionMessage = targetPublish ? @"已加入待发布文章，可在列表一并提交" : @"已加入待下架文章，可在列表一并提交";
  [self finishSuccessfulSave];
}

- (void)performPublication {
  [self performPublicationToPublished:!_published];
}

- (void)performPublicationToPublished:(BOOL)targetPublish {
  if (_saving || !_hasSavedArticle) return;
  if (_closed) return;
  if (![self persistCurrentArticle]) return;
  BOOL unpublishing = !targetPublish;
  BOOL updating = _published && targetPublish;
  _saving = YES;
  [self.view endEditing:YES];
  _titleField.enabled = NO;
  _textView.editable = NO;
  _summaryView.editable = NO;
  _dock.userInteractionEnabled = NO;
  [self updatePublicationActions];
  NSString *progressTitle = unpublishing ? @"正在下架…" : (updating ? @"正在更新…" : @"正在发布…");
  UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  [spinner startAnimating];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
  _operationStatusLabel.hidden = NO;
  _operationStatusLabel.textColor = LBTheme.muted;
  _operationStatusLabel.text = unpublishing ? @"正在下架文章，保留本地内容…" : @"正在同步文章与附件到 GitHub…";
  self.navigationItem.subtitle = progressTitle;
  NSUUID *operation = NSUUID.UUID;
  _publicationOperation = operation;
  NSString *noteId = [_noteId copy];
  ++_attachmentGeneration;
  __weak typeof(self) weakSelf = self;
  void (^completion)(NSError *) = ^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      LBPostEditor *editor = weakSelf;
      if (!editor || !editor->_saving) return;
      if (editor->_closed || editor->_publicationOperation != operation || ![editor->_noteId isEqualToString:noteId]) return;
      editor->_publicationOperation = nil;
      editor->_saving = NO;
      editor->_titleField.enabled = YES;
      editor->_textView.editable = YES;
      editor->_summaryView.editable = YES;
      editor->_dock.userInteractionEnabled = YES;
      editor.navigationItem.rightBarButtonItem = editor->_saveItem;
      if (error) {
        [editor updatePublicationActions];
        [editor saveDraftToDisk];
        NSString *failure = unpublishing ? @"下架文章失败" : (updating ? @"更新文章失败" : @"发布文章失败");
        editor.navigationItem.subtitle = failure;
        editor->_operationStatusLabel.textColor = UIColor.systemRedColor;
        editor->_operationStatusLabel.text = [NSString stringWithFormat:@"%@：%@\n编辑已保存在本地。", failure, error.localizedDescription ?: @"请检查网络和 GitHub 配置。"];
        return;
      }
      editor->_published = targetPublish;
      editor->_completionMessage = unpublishing ? @"下架文章成功，本地草稿已保留" : (updating ? @"文章更新成功" : @"文章发布成功");
      [editor updatePublicationActions];
      [editor finishSuccessfulSave];
    });
  };
  if (unpublishing) {
    [LBMdStore.shared unpublishArticle:_noteId done:completion];
  } else {
    [LBMdStore.shared publishArticle:_noteId done:completion];
  }
}

@end

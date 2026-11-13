#import "LBMemos.h"
#import "LBMemosCache.h"
#import "LBMemoMedia.h"
#import "LBNavigationController.h"
#import "LBLayout.h"
#import "LBMemoContentView.h"
#import "LBDiagramPreview.h"
#import "LBPostReader.h"
#import <QuickLook/QuickLook.h>

@interface LBMemosDetailController () <QLPreviewControllerDataSource>
@end
@implementation LBMemosDetailController {
  NSDictionary *_memo, *_displayMemo;
  UIScrollView *_scroll;
  LBMemoContentView *_content;
  NSUInteger _context, _revision;
  BOOL _visible, _working;
  NSMutableArray<LBMemoInlineMediaController *> *_mediaChildren;
  NSUInteger _mediaEpoch;
  NSURL *_previewFile;
}
- (instancetype)initWithMemo:(NSDictionary *)memo {
  if ((self = [super init])) { _memo = [memo copy]; _context = LBMemosClient.shared.generation; }
  return self;
}
- (void)viewDidLoad {
  [super viewDidLoad]; self.title = @"说说详情";
  self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
  _scroll = [UIScrollView new]; _scroll.backgroundColor = UIColor.clearColor;
  LBInstallContentScrollView(self, _scroll, nil);
  __weak typeof(self) weakSelf = self;
  _content = [[LBMemoContentView alloc] initWithPreview:^(NSURL *file) {
    typeof(self) self = weakSelf;
    if (!self || !self->_visible || self->_context != LBMemosClient.shared.generation || self.presentedViewController) return;
    NSString *ext = file.pathExtension.lowercaseString;
    BOOL isImg = [@[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"gif", @"webp"] containsObject:ext];
    if (isImg) {
      LBReaderImageController *img = [[LBReaderImageController alloc] initWithLocalFile:file];
      UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:img];
      nav.modalPresentationStyle = UIModalPresentationFullScreen;
      [self presentViewController:nav animated:YES completion:nil];
      return;
    }
    self->_previewFile = file;
    QLPreviewController *preview = [QLPreviewController new]; preview.dataSource = self;
    [self presentViewController:preview animated:YES completion:nil];
  }];
  _content.openDiagram = ^(NSString *dataURL, NSUInteger generation) {
    typeof(self) self = weakSelf;
    if (!self || !self->_visible || generation != self->_context || generation != LBMemosClient.shared.generation || self.presentedViewController) return;
    LBDiagramPreviewController *preview = [LBDiagramPreviewController previewWithDataURL:dataURL memoGeneration:@(generation)];
    if (preview) [self presentViewController:preview animated:YES completion:nil];
  };
  _content.resetDiagram = ^{
    typeof(self) self = weakSelf;
    if ([self.presentedViewController isKindOfClass:LBDiagramPreviewController.class]) [(LBDiagramPreviewController *)self.presentedViewController close];
  };
  _mediaChildren = [NSMutableArray array];
  _content.resetMedia = ^{ [weakSelf resetInlineMedia]; };
  _content.installMedia = ^(UIView *host, NSDictionary *resource) {
    typeof(self) self = weakSelf;
    if (!self || self->_context != LBMemosClient.shared.generation) return;
    LBMemoInlineMediaController *child = [[LBMemoInlineMediaController alloc] initWithResource:resource];
    NSUInteger epoch = self->_mediaEpoch;
    child.willPlay = ^(LBMemoInlineMediaController *playing) {
      typeof(self) owner = weakSelf;
      if (!owner || epoch != owner->_mediaEpoch || !owner->_visible || owner->_context != LBMemosClient.shared.generation) { [playing pausePlayback]; return; }
      for (LBMemoInlineMediaController *other in owner->_mediaChildren) if (other != playing) [other pausePlayback];
    };
    [self->_mediaChildren addObject:child];
    [self addChildViewController:child]; [host addSubview:child.view];
    child.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      [child.view.topAnchor constraintEqualToAnchor:host.topAnchor], [child.view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
      [child.view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor], [child.view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor]]];
    [child didMoveToParentViewController:self]; [child setPageVisible:self->_visible];
  };
  _content.translatesAutoresizingMaskIntoConstraints = NO; [_scroll addSubview:_content];
  [NSLayoutConstraint activateConstraints:@[
    [_content.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:8],
    [_content.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-24],
    [_content.leadingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.leadingAnchor constant:16],
    [_content.trailingAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.trailingAnchor constant:-16],
    [_content.widthAnchor constraintEqualToAnchor:_scroll.frameLayoutGuide.widthAnchor constant:-32]]];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:LBMemosDidChange object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cachedContentChanged:) name:LBMemosCacheDidChange object:nil];
  if (_context != LBMemosClient.shared.generation) { [self clearContext]; return; }
  // Resolve the account-scoped local snapshot before the first display. UIKit
  // loads this view before the push transition; neither appearance nor a GET
  // should be a prerequisite for showing the full body we already have.
  BOOL foundCached = NO;
  for (NSDictionary *row in [LBMemosClient.shared cachedState:_memo[@"rowStatus"]]) {
    if ([row[@"id"] isEqual:_memo[@"id"]]) { _memo = row; foundCached = YES; break; }
  }
  [self rebuild];
  // Reopening a cached memo must not repeat full-body fetches or discard its
  // protected originals. Uncached refreshes run only after local display.
  if (foundCached) return;
  NSUInteger revision = _revision;
  [LBMemosClient.shared memo:_memo[@"id"] done:^(NSDictionary *memo, NSError *error) {
    if (self->_context != LBMemosClient.shared.generation) { [self clearContext]; return; }
    if (revision != self->_revision) return;
    if (memo) { self->_memo = memo; [self rebuild]; }
    else if (error.code == 404) { self->_memo = nil; self->_displayMemo = nil; self->_previewFile = nil; [self->_content invalidateContent]; self.navigationItem.prompt = @"这条说说已不存在"; self.navigationItem.rightBarButtonItem = nil; }
    else if (error) self.navigationItem.prompt = error.localizedDescription;
  }];
}
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  if (_context != LBMemosClient.shared.generation) [self clearContext];
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated]; _visible = YES;
  if (_context != LBMemosClient.shared.generation) [self clearContext];
  else {
    [_content setPageVisible:YES];
    for (LBMemoInlineMediaController *child in _mediaChildren) [child setPageVisible:YES];
    if (!self->_memo) self.navigationItem.rightBarButtonItem = nil;
  }
}
- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  // AVKit's native expand is a presentation of the existing inline player,
  // not leaving the memo. Do not pause or tear down that transition.
  BOOL fullscreen = NO;
  for (LBMemoInlineMediaController *child in _mediaChildren) if (child.isPresentingFullscreen) fullscreen = YES;
  if (fullscreen && !self.isMovingFromParentViewController && !self.navigationController.isBeingDismissed) return;
  _visible = NO; [_content setPageVisible:NO];
  for (LBMemoInlineMediaController *child in _mediaChildren) [child setPageVisible:NO];
}
- (void)resetInlineMedia {
  ++_mediaEpoch;
  for (LBMemoInlineMediaController *child in _mediaChildren.copy) {
    [child invalidateMedia]; [child willMoveToParentViewController:nil];
    [child.view removeFromSuperview]; [child removeFromParentViewController];
  }
  [_mediaChildren removeAllObjects];
}
- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  for (LBMemoInlineMediaController *child in _mediaChildren) [child invalidateMedia];
}
- (void)clearContext {
  ++_revision; _working = NO; _memo = nil; _displayMemo = nil; _previewFile = nil;
  [_content invalidateContent];
  self.navigationItem.rightBarButtonItem = nil;
  if (self.presentedViewController) [self dismissViewControllerAnimated:NO completion:nil];
  self.navigationItem.prompt = nil;
  self.navigationItem.subtitle = @"连接已变更，请返回列表";
}
- (void)cachedContentChanged:(NSNotification *)notification {
  (void)notification;
  if (_context != LBMemosClient.shared.generation) { [self clearContext]; return; }
  for (NSDictionary *row in [LBMemosClient.shared cachedState:_memo[@"rowStatus"]]) {
    if ([row[@"id"] isEqual:_memo[@"id"]] && ![row isEqual:_memo]) { _memo = row; ++_revision; [self rebuild]; break; }
  }
}
- (void)changed:(NSNotification *)notification {
  if (_context != LBMemosClient.shared.generation) { [self clearContext]; return; }
  NSDictionary *memo = notification.userInfo[@"memo"];
  if ([notification.userInfo[@"deletedID"] isEqual:_memo[@"id"]]) { ++_revision; _memo = nil; _displayMemo = nil; _previewFile = nil; [_content invalidateContent]; self.navigationItem.rightBarButtonItem = nil; if (_visible) [self.navigationController popViewControllerAnimated:YES]; return; }
  if ([memo[@"id"] isEqual:_memo[@"id"]]) { ++_revision; _memo = memo; [self rebuild]; }
}
- (void)rebuild {
  if (_context != LBMemosClient.shared.generation) { [self clearContext]; return; }
  if (_displayMemo && ![_displayMemo isEqual:_memo]) [self resetInlineMedia];
  // Rendering is local state, not playback/interaction. Prepare it even while
  // entering the screen (or covered by an editor); _visible still gates media.
  if (!_memo) { [_content invalidateContent]; self.navigationItem.rightBarButtonItem = nil; return; }
  _displayMemo = [_memo copy];
  self.navigationItem.subtitle = [_memo[@"rowStatus"] isEqual:@"ARCHIVED"] ? @"已归档" : LBMemoVisibility(_memo[@"visibility"]);
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis"] menu:[self menu]];
  _previewFile = nil; [_content displayMemo:_displayMemo generation:_context];
}
- (UIMenu *)menu {
  __weak typeof(self) weakSelf = self;
  UIAction *edit = [UIAction actionWithTitle:@"编辑说说" image:[UIImage systemImageNamed:@"square.and.pencil"] identifier:nil handler:^(UIAction *a) { (void)a; [weakSelf edit]; }];
  UIAction *copy = [UIAction actionWithTitle:@"复制Markdown正文" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *a) {
    (void)a; typeof(self) self = weakSelf; if (self && self->_context == LBMemosClient.shared.generation) UIPasteboard.generalPasteboard.string = self->_memo[@"content"];
  }];
  UIAction *share = [UIAction actionWithTitle:@"分享正文" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a) { (void)a; [weakSelf share]; }];
  BOOL pinned = [_memo[@"pinned"] boolValue], archived = [_memo[@"rowStatus"] isEqual:@"ARCHIVED"];
  UIAction *pin = [UIAction actionWithTitle:pinned ? @"取消置顶" : @"置顶" image:[UIImage systemImageNamed:@"pin"] identifier:nil handler:^(UIAction *a) { (void)a; [weakSelf change:@{ @"pinned" : @(!pinned) }]; }];
  UIAction *archive = [UIAction actionWithTitle:archived ? @"恢复到说说列表" : @"归档说说" image:[UIImage systemImageNamed:archived ? @"arrow.uturn.backward" : @"archivebox"] identifier:nil handler:^(UIAction *a) { (void)a; [weakSelf change:@{ @"rowStatus" : archived ? @"NORMAL" : @"ARCHIVED" }]; }];
  UIAction *remove = [UIAction actionWithTitle:@"永久删除" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) { (void)a; [weakSelf confirmDelete]; }]; remove.attributes = UIMenuElementAttributesDestructive;
  UIAction *softRemove = [UIAction actionWithTitle:@"删除…" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) { (void)a; [weakSelf confirmArchiveDelete]; }];
  softRemove.attributes = UIMenuElementAttributesDestructive;
  if (_working) for (UIAction *action in @[ edit, pin, archive, remove, softRemove ]) action.attributes |= UIMenuElementAttributesDisabled;
  return [UIMenu menuWithChildren:archived ? @[ edit, copy, share, archive, remove ] : @[ edit, copy, share, pin, archive, softRemove ]];
}
- (BOOL)canWrite { return !_working && _memo && _context == LBMemosClient.shared.generation; }
- (void)edit {
  if (![self canWrite]) return;
  if (!LBMemosClient.shared.user) {
    NSUInteger generation = _context;
    [LBMemosClient.shared validate:^(NSDictionary *user, NSError *error) {
      if (generation != LBMemosClient.shared.generation) { [self clearContext]; return; }
      if (error) LBMemosShowError(self, error);
      else if (user && self->_visible && !self.presentedViewController) [self edit];
    }];
    return;
  }
  LBMemosEditor *editor = [[LBMemosEditor alloc] initWithMemo:_memo saved:nil];
  LBNavigationController *nav = [[LBNavigationController alloc] initWithRootViewController:editor];
  nav.modalPresentationStyle = UIModalPresentationPageSheet; nav.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
  [self presentViewController:nav animated:YES completion:nil];
}
- (void)share {
  if (!_memo || _context != LBMemosClient.shared.generation) return;
  UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ _memo[@"content"] ?: @"" ] applicationActivities:nil];
  share.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
  [self presentViewController:share animated:YES completion:nil];
}
- (void)change:(NSDictionary *)fields {
  if (![self canWrite]) return;
  NSUInteger revision = ++_revision; NSDictionary *snapshot = [_memo copy];
  _working = YES; [self rebuild]; self.navigationItem.prompt = @"正在保存到服务器…";
  [LBMemosClient.shared updateMemo:snapshot fields:fields done:^(NSDictionary *memo, NSError *error) {
    if (self->_context != LBMemosClient.shared.generation) { [self clearContext]; return; }
    self->_working = NO;
    if (revision != self->_revision) { self.navigationItem.prompt = nil; [self rebuild]; return; }
    if (error) { self.navigationItem.prompt = error.localizedDescription; [self rebuild]; if (self->_visible) LBMemosShowError(self, error); return; }
    self->_memo = memo; self.navigationItem.prompt = nil; [self rebuild];
  }];
}
- (void)confirmArchiveDelete {
  if (![self canWrite] || [_memo[@"rowStatus"] isEqual:@"ARCHIVED"]) return;
  NSUInteger revision = _revision;
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"如何删除这条说说？" message:@"移至归档可恢复。永久删除会先安全归档，再执行一次永久删除；不会自动删除可能共用的附件文件。" preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"移至归档（可恢复）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; if (revision == self->_revision) [self change:@{@"rowStatus":@"ARCHIVED"}]; }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"永久删除（不可恢复）" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
    (void)action; if (revision != self->_revision || ![self canWrite]) return;
    // Present the final destructive confirmation after this choice alert closes.
    [self dismissViewControllerAnimated:YES completion:^{ if (revision == self->_revision && self->_visible) [self confirmPermanentNormal]; }];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmPermanentNormal {
  if (![self canWrite] || [_memo[@"rowStatus"] isEqual:@"ARCHIVED"]) return;
  NSUInteger revision = _revision; NSDictionary *snapshot = [_memo copy];
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认永久删除？" message:@"正文和说说关联将不可恢复。会先移至归档，再永久删除；任一步结果不确定都不会自动重试，请刷新核对。" preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"永久删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
    (void)action; if (![self canWrite] || revision != self->_revision) return;
    ++self->_revision; self->_working = YES; [self rebuild]; self.navigationItem.prompt = @"正在安全归档…";
    [LBMemosClient.shared updateMemo:snapshot fields:@{@"rowStatus":@"ARCHIVED"} done:^(NSDictionary *archived, NSError *error) {
      if (self->_context != LBMemosClient.shared.generation) { [self clearContext]; return; }
      if (error || ![archived[@"rowStatus"] isEqual:@"ARCHIVED"]) {
        self->_working = NO; [self rebuild]; self.navigationItem.prompt = @"归档未确认；未发送永久删除，请刷新核对。";
        if (error && self->_visible) LBMemosShowError(self, error); return;
      }
      // Pass ONLY the normalized archived response into the existing guarded
      // client. No direct DELETE of a NORMAL snapshot, and no retry loop.
      if (![self->_memo[@"id"] isEqual:archived[@"id"]]) { self->_working = NO; return; }
      self->_memo = archived; [self rebuild]; self.navigationItem.prompt = @"已归档，正在永久删除…";
      [LBMemosClient.shared deleteArchived:archived done:^(NSError *deleteError) {
        if (self->_context != LBMemosClient.shared.generation) { [self clearContext]; return; }
        self->_working = NO; [self rebuild];
        if (deleteError) {
          NSString *message = @"第一步已归档；永久删除未确认。请先刷新归档核对，若记录仍在可恢复或明确重试；不会自动重发。";
          self.navigationItem.prompt = message;
          if (self->_visible) LBMemosShowError(self, [NSError errorWithDomain:@"LBMemoDetail" code:deleteError.code userInfo:@{NSLocalizedDescriptionKey:message}]);
        } else if (self.navigationController.topViewController == self) [self.navigationController popViewControllerAnimated:YES];
      }];
    }];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmDelete {
  if (![self canWrite] || ![_memo[@"rowStatus"] isEqual:@"ARCHIVED"]) return;
  NSUInteger revision = _revision;
  UIAlertController *a = [UIAlertController alertControllerWithTitle:@"永久删除这条归档说说？" message:@"正文将不可恢复。此操作只删除说说及关联，不自动删除可能被其它说说使用的资源文件。请求结果不确定时不会自动重试，请刷新核对。" preferredStyle:UIAlertControllerStyleAlert];
  [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  [a addAction:[UIAlertAction actionWithTitle:@"永久删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
    (void)action; if (![self canWrite] || revision != self->_revision || ![self->_memo[@"rowStatus"] isEqual:@"ARCHIVED"]) return; ++self->_revision; self->_working = YES; [self rebuild];
    [LBMemosClient.shared deleteArchived:self->_memo done:^(NSError *error) {
      if (self->_context != LBMemosClient.shared.generation) { [self clearContext]; return; }
      self->_working = NO; [self rebuild];
      if (error) { self.navigationItem.prompt = error.localizedDescription; if (self->_visible) LBMemosShowError(self, error); }
      else if (self.navigationController.topViewController == self) [self.navigationController popViewControllerAnimated:YES];
    }];
  }]];
  [self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller { return _previewFile ? 1 : 0; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index { return _previewFile; }
@end

#import "LBMemos.h"
#import "LBMemosCache.h"
#import "LBMemosDiskCache.h"
#import <ImageIO/ImageIO.h>
#import "LBNavigationController.h"
#import "LBPostReader.h"
#import <Symbols/NSSymbolEffect.h>
#import <objc/runtime.h>

@interface LBMemosTimelineController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating, UISearchControllerDelegate>
@end
@implementation LBMemosTimelineController {
  UITableView *_table;
  NSArray<NSDictionary *> *_rows, *_display;
  NSString *_query, *_tag, *_state, *_nextQuery;
  NSUInteger _offset, _request, _context;
  BOOL _more, _loading, _visible, _searchDismissing, _needsRender, _needsReconcile;
  NSError *_error;
  NSNumber *_otherStateCount;
  NSTimer *_syncTimer;
  NSDate *_lastSync;
  NSArray<NSDictionary *> *_lastRenderedRows, *_filteredRows;
  NSString *_filteredQuery, *_filteredTag;
  UILabel *_cacheProgressLabel;
  BOOL _hasLocalSeed;
  UIView *_navHeaderView;
  UILabel *_navTitleLabel;
  UIStackView *_navSubtitleStack;
  UIImageView *_navSyncIcon;
  NSString *_navSyncSymbol;
  UILabel *_navSubtitleLabel;
  BOOL _swipeActive; // swipe actions open/closing: reloadData would tear the row
  BOOL _checkingCloud;
  NSCache<NSString *, UIImage *> *_thumbnails;
  NSMutableDictionary<NSString *, NSHashTable<UIImageView *> *> *_thumbnailWaiters;
  NSOperationQueue *_thumbnailQueue;
}
- (instancetype)initWithArchived:(BOOL)archived {
  if ((self = [super init])) { _state = archived ? @"ARCHIVED" : @"NORMAL"; _rows = @[]; _display = @[]; _query = @""; _tag = @""; }
  return self;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  _thumbnails = [NSCache new]; _thumbnails.countLimit = 128; _thumbnails.totalCostLimit = 24 * 1024 * 1024;
  _thumbnailWaiters = [NSMutableDictionary dictionary];
  _thumbnailQueue = [NSOperationQueue new]; _thumbnailQueue.maxConcurrentOperationCount = 2;
  _thumbnailQueue.qualityOfService = NSQualityOfServiceUserInitiated;
  self.title = [_state isEqual:@"NORMAL"] ? @"说说" : @"说说归档";
  _table = LBGlassTable(self, self);
  UIRefreshControl *rc = [UIRefreshControl new]; [rc addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged]; _table.refreshControl = rc;

  // Header Title View with Animated SF Symbol Micro-icon (Matching Articles Tab)
  _navHeaderView = [UIView new];
  _navTitleLabel = [UILabel new];
  _navTitleLabel.text = [_state isEqual:@"NORMAL"] ? @"说说" : @"说说归档";
  _navTitleLabel.font = [LBTheme rounded:18 weight:UIFontWeightBold];
  _navTitleLabel.textColor = LBTheme.ink;

  _navSyncIcon = [UIImageView new];
  _navSyncIcon.contentMode = UIViewContentModeScaleAspectFit;
  _navSyncIcon.tintColor = LBTheme.muted;
  _navSyncIcon.image = [UIImage systemImageNamed:@"text.bubble"];
  [_navSyncIcon.widthAnchor constraintEqualToConstant:12].active = YES;
  [_navSyncIcon.heightAnchor constraintEqualToConstant:12].active = YES;

  _navSubtitleLabel = [UILabel new];
  _navSubtitleLabel.font = [LBTheme rounded:12 weight:UIFontWeightMedium];
  _navSubtitleLabel.textColor = LBTheme.muted;

  _navSubtitleStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _navSyncIcon, _navSubtitleLabel ]];
  _navSubtitleStack.axis = UILayoutConstraintAxisHorizontal;
  _navSubtitleStack.spacing = 4;
  _navSubtitleStack.alignment = UIStackViewAlignmentCenter;

  UIStackView *navStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _navTitleLabel, _navSubtitleStack ]];
  navStack.axis = UILayoutConstraintAxisVertical;
  navStack.spacing = 2;
  navStack.alignment = UIStackViewAlignmentLeading;
  navStack.translatesAutoresizingMaskIntoConstraints = NO;
  [_navHeaderView addSubview:navStack];
  [NSLayoutConstraint activateConstraints:@[
    [navStack.topAnchor constraintEqualToAnchor:_navHeaderView.topAnchor],
    [navStack.bottomAnchor constraintEqualToAnchor:_navHeaderView.bottomAnchor],
    [navStack.leadingAnchor constraintEqualToAnchor:_navHeaderView.leadingAnchor],
    [navStack.trailingAnchor constraintEqualToAnchor:_navHeaderView.trailingAnchor]
  ]];
  self.navigationItem.titleView = _navHeaderView;

  UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
  search.searchResultsUpdater = self; search.delegate = self; search.obscuresBackgroundDuringPresentation = NO; search.hidesNavigationBarDuringPresentation = NO;
  search.searchBar.placeholder = @"搜索说说…";
  self.navigationItem.searchController = search; self.navigationItem.hidesSearchBarWhenScrolling = NO;
  self.navigationItem.preferredSearchBarPlacement = UINavigationItemSearchBarPlacementStacked;
  self.navigationItem.searchBarPlacementAllowsToolbarIntegration = NO;
  UIBarButtonItem *compose = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.pencil"] style:UIBarButtonItemStyleProminent target:self action:@selector(compose)];
  compose.accessibilityLabel = @"新建说说";
  self.navigationItem.rightBarButtonItems = @[ compose, [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease"] menu:[self filters]] ];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:LBMemosDidChange object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cacheChanged:) name:LBMemosCacheDidChange object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resignedActive:) name:UIApplicationWillResignActiveNotification object:nil];
}
- (UIMenu *)filters {
  __weak typeof(self) weakSelf = self;
  UIAction *connection = [UIAction actionWithTitle:@"Memos连接与令牌" image:[UIImage systemImageNamed:@"key.horizontal"] identifier:nil handler:^(UIAction *a) { LBMemosPresentConnection(weakSelf); }];
  UIAction *tags = [UIAction actionWithTitle:@"按标签筛选" image:[UIImage systemImageNamed:@"number"] identifier:nil handler:^(UIAction *a) { [weakSelf pickTag]; }];
  UIAction *clear = [UIAction actionWithTitle:@"清除标签筛选" image:[UIImage systemImageNamed:@"xmark.circle"] identifier:nil handler:^(UIAction *a) { typeof(self) self = weakSelf; if (!self) return; self->_tag = @""; [self refresh]; }];
  UIAction *archives = [UIAction actionWithTitle:@"归档说说" image:[UIImage systemImageNamed:@"archivebox"] identifier:nil handler:^(UIAction *a) { [weakSelf.navigationController pushViewController:[[LBMemosTimelineController alloc] initWithArchived:YES] animated:YES]; }];
  return [UIMenu menuWithChildren:[_state isEqual:@"NORMAL"] ? @[ tags, clear, archives, connection ] : @[ tags, clear, connection ]];
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated]; _visible = YES;
  [self loadCachedRows]; [self startSyncTimer];
  if (!_rows.count && !_loading) [self refresh];
  else [self checkCloudChangesAndSyncIfNeeded];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; _visible = NO; [_syncTimer invalidate]; _syncTimer = nil; }
- (void)startSyncTimer {
  if (!_visible || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
  [_syncTimer invalidate]; __weak typeof(self) weakSelf = self;
  // Local-first: light change detection on timer, never recurring full syncs
  _syncTimer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *timer) {
    (void)timer; typeof(self) self = weakSelf;
    if (!self || !self->_visible || self->_loading || self->_table.dragging || self->_table.decelerating || self->_searchDismissing || LBMemosClient.shared.busy || LBMemosClient.shared.authenticationRequired) return;
    [self checkCloudChangesAndSyncIfNeeded];
  }]; _syncTimer.tolerance = 10;
}
- (void)checkCloudChangesAndSyncIfNeeded {
  LBMemosClient *client = LBMemosClient.shared;
  if (_loading || _checkingCloud || !client.configured || client.authenticationRequired || client.busy) return;
  // A cold credential-bound disk cache is read-only, NOT /user/me proof.
  // The lightweight endpoint requires a live user; refresh validates first.
  if (!client.user) { [self refresh]; return; }
  _checkingCloud = YES;
  NSUInteger request = _request, generation = client.generation;
  __weak typeof(self) weakSelf = self;
  [client checkLatestMemoState:_state done:^(NSDictionary *latest, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (!self || generation != client.generation) return;
      self->_checkingCloud = NO;
      if (request != self->_request || error || !self->_visible || self->_loading) return;
      if (!latest) {
        if (self->_rows.count > 0) [self refresh];
        return;
      }
      NSDictionary *localTop = self->_rows.firstObject;
      if (!localTop ||
          ![localTop[@"id"] isEqual:latest[@"id"]] ||
          ![localTop[@"updatedTs"] isEqual:latest[@"updatedTs"]]) {
        // Cloud has changes: reconcile now!
        [self refresh];
      }
    });
  }];
}
- (void)becameActive:(NSNotification *)note { (void)note; if (_visible) { [self startSyncTimer]; if (!_loading && !LBMemosClient.shared.authenticationRequired) [self checkCloudChangesAndSyncIfNeeded]; } }
- (void)resignedActive:(NSNotification *)note { (void)note; [_syncTimer invalidate]; _syncTimer = nil; }
- (void)loadCachedRows {
  // Cache access may resolve a previous exact-credential binding for offline
  // reading; it never sets the client's verified user or enables writes.
  NSArray *cached = [LBMemosClient.shared cachedState:_state];
  if (cached && !_hasLocalSeed) {
    _hasLocalSeed = YES;
    _rows = [self ordered:cached]; _context = LBMemosClient.shared.generation; _error = nil;
    NSString *other = [_state isEqual:@"NORMAL"] ? @"ARCHIVED" : @"NORMAL";
    NSArray *cachedOther = [LBMemosClient.shared cachedState:other];
    if (cachedOther) _otherStateCount = @(cachedOther.count);
  }
  [self render];
}
- (void)cacheChanged:(NSNotification *)note { (void)note; if (_visible) [self loadCachedRows]; }
- (void)dealloc { [_syncTimer invalidate]; [_thumbnailQueue cancelAllOperations]; [NSObject cancelPreviousPerformRequestsWithTarget:self]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh {
  _otherStateCount = nil;
  _needsReconcile = NO;
  _context = LBMemosClient.shared.generation; _request++; _loading = NO; _offset = 0; _more = NO;
  [self fetch:NO];
}
- (void)fetch:(BOOL)append {
  if (_loading) return;
  [self loadCachedRows];
  LBMemosClient *client = LBMemosClient.shared;
  if (!client.configured) { _rows = @[]; _error = nil; [_table.refreshControl endRefreshing]; [self render]; return; }
  _loading = YES; _error = nil; NSUInteger request = ++_request, context = _context;
  (void)append;
  [self render];
  void (^load)(void) = ^{
    // Read the backend's complete authenticated personal snapshot, not page 1.
    [client allState:self->_state text:@"" tag:@"" done:^(NSArray<NSDictionary *> *rows, NSError *error) {
      if (request != self->_request || context != client.generation) return;
      self->_loading = error != nil ? NO : YES;
      if (error) [self->_table.refreshControl endRefreshing];
      self->_error = error;
      if (!error) { self->_hasLocalSeed = YES; self->_rows = [self ordered:rows]; self->_offset = rows.count; self->_more = NO; }
      [self render];
      if (error) return;
      NSString *other = [self->_state isEqual:@"NORMAL"] ? @"ARCHIVED" : @"NORMAL";
      [client allState:other text:@"" tag:@"" done:^(NSArray<NSDictionary *> *others, NSError *otherError) {
        if (request != self->_request || context != client.generation) return;
        self->_loading = NO; [self->_table.refreshControl endRefreshing];
        self->_otherStateCount = otherError ? nil : @(others.count);
        if (!otherError) {
          self->_lastSync = NSDate.date;
          [client reconcileCacheNormal:[self->_state isEqual:@"NORMAL"] ? rows : others archived:[self->_state isEqual:@"ARCHIVED"] ? rows : others];
        }
        [self render];
      }];
    }];
  };
  if (client.authenticationRequired) {
    _loading = NO; [_table.refreshControl endRefreshing];
    _error = [NSError errorWithDomain:@"LBMemos" code:401 userInfo:@{ NSLocalizedDescriptionKey:@"令牌已失效，请打开连接设置重新验证" }];
    [self render]; return;
  }
  if (client.user) load();
  else [client validate:^(NSDictionary *user, NSError *error) {
    if (request != self->_request || context != client.generation) return;
    if (error) { self->_loading = NO; self->_error = error; [self->_table.refreshControl endRefreshing]; [self render]; }
    else { [self loadCachedRows]; load(); }
  }];
}
- (void)changed:(NSNotification *)note {
  if (_context != LBMemosClient.shared.generation) {
    _rows = @[]; _display = @[]; _context = LBMemosClient.shared.generation; _request++; _loading = NO;
    _error = nil; _more = NO; _offset = 0; _otherStateCount = nil;
    _hasLocalSeed = NO; _lastSync = nil; _lastRenderedRows = nil;
    _checkingCloud = NO;
    [_thumbnails removeAllObjects]; [_thumbnailWaiters removeAllObjects]; [_thumbnailQueue cancelAllOperations];
    _filteredRows = nil; _filteredQuery = nil; _filteredTag = nil;
    _cacheProgressLabel.text = nil;
    // Privacy reset is immediate, even during a gesture/search dismissal.
    [_table reloadData]; _table.tableFooterView = nil; _table.backgroundView = nil;
    self.navigationItem.subtitle = nil;
    _navSubtitleLabel.text = @"连接已变更，请验证后刷新";
    [self render]; return;
  }
  NSDictionary *memo = note.userInfo[@"memo"]; NSNumber *deleted = note.userInfo[@"deletedID"];
  if (memo || deleted) {
    NSMutableArray *rows = [_rows mutableCopy]; NSNumber *identifier = memo[@"id"] ?: deleted;
    NSIndexSet *drop = [rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *row, NSUInteger index, BOOL *stop) { return [row[@"id"] isEqual:identifier]; }];
    [rows removeObjectsAtIndexes:drop];
    // All records remain in the snapshot; filtering is applied only at render.
    if (memo && [memo[@"rowStatus"] isEqual:_state]) [rows addObject:memo];
    _rows = [self ordered:rows]; _otherStateCount = nil; _needsReconcile = YES; _request++; _loading = NO; _more = NO; // old offset is invalid after a write.
  }
  [self render];
  if (_visible && !_loading) [self refresh];
}
- (void)render {
  if (_swipeActive && !_needsRender) {
    // Safety net in case UIKit never reports the end of the swipe.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (!self || !self->_swipeActive || !self->_needsRender || self->_table.isEditing) return;
      for (UITableViewCell *cell in self->_table.visibleCells) if (cell.isEditing || cell.showingDeleteConfirmation) return;
      self->_swipeActive = NO; [self render];
    });
  }
  _needsRender = YES;
  if (!_visible || _searchDismissing || _swipeActive || _table.dragging || _table.decelerating) return;
  _needsRender = NO;
  // Resource progress does not change the immutable rows/query/tag inputs.
  // Refilter only when one changes; retain all records for counts and writes.
  if (_filteredRows != _rows || ![_filteredQuery isEqualToString:_query] || ![_filteredTag isEqualToString:_tag]) {
    NSMutableArray *visible = [NSMutableArray array];
    for (NSDictionary *memo in _rows) {
      BOOL match = !_query.length || [memo[@"content"] rangeOfString:_query options:NSCaseInsensitiveSearch].location != NSNotFound;
      if (_tag.length) match = match && [memo[@"tagList"] containsObject:_tag];
      if (match) [visible addObject:memo];
    }
    _display = [visible copy];
    _filteredRows = _rows; _filteredQuery = [_query copy]; _filteredTag = [_tag copy];
  }
  NSUInteger normal = [_state isEqual:@"NORMAL"] ? _rows.count : _otherStateCount.unsignedIntegerValue;
  NSUInteger archived = [_state isEqual:@"ARCHIVED"] ? _rows.count : _otherStateCount.unsignedIntegerValue;
  NSString *counts = _otherStateCount ? [NSString stringWithFormat:@"共 %lu 条", (unsigned long)(normal+archived)] : [NSString stringWithFormat:@"共 %lu 条", (unsigned long)_rows.count];
  if (_query.length || _tag.length) counts = [NSString stringWithFormat:@"%lu 条匹配", (unsigned long)_display.count];
  NSString *status = !LBMemosClient.shared.configured ? @"未连接" : _loading ? @"正在同步说说…" : _error ? @"未联网" : counts;
  if (_display.count && _loading) status = [counts stringByAppendingString:@" · 同步中"];
  self.navigationItem.subtitle = nil;
  _navSubtitleLabel.text = status;

  BOOL busy = _loading;
  NSString *symbol = busy ? @"arrow.triangle.2.circlepath"
      : (_error ? @"exclamationmark.circle"
      : (!LBMemosClient.shared.configured ? @"key.horizontal"
      : (_rows.count ? @"checkmark.circle" : @"text.bubble")));
  _navSyncIcon.tintColor = busy ? LBTheme.accent
      : (_error ? UIColor.systemRedColor
      : (!LBMemosClient.shared.configured ? LBTheme.muted
      : (_rows.count ? [UIColor colorWithRed:0.1 green:0.75 blue:0.4 alpha:1.0] : LBTheme.muted)));
  if (![_navSyncSymbol isEqualToString:symbol]) {
    BOOL first = _navSyncSymbol == nil;
    _navSyncSymbol = symbol;
    [_navSyncIcon removeAllSymbolEffects];
    if (first) _navSyncIcon.image = [UIImage systemImageNamed:symbol];
    else [_navSyncIcon setSymbolImage:[UIImage systemImageNamed:symbol] withContentTransition:[NSSymbolReplaceContentTransition replaceDownUpTransition]];
    if (busy) {
      [_navSyncIcon addSymbolEffect:[NSSymbolRotateEffect rotateClockwiseEffect]
          options:[NSSymbolEffectOptions optionsWithRepeatBehavior:[NSSymbolEffectOptionsRepeatBehavior behaviorContinuous]]];
    } else if (!first && !_error && LBMemosClient.shared.configured && _rows.count) {
      [_navSyncIcon addSymbolEffect:[NSSymbolBounceEffect effect] options:[NSSymbolEffectOptions optionsWithNonRepeating]];
    }
  }
  if (!_display.count) {
    __weak typeof(self) weakSelf = self;
    BOOL configured = LBMemosClient.shared.configured;
    _table.backgroundView = LBNotice(configured ? @"text.bubble" : @"key.horizontal", !configured ? @"连接Memos开始管理" : _loading ? @"正在读取…" : _error ? @"读取失败" : @"没有匹配的说说",
      !configured ? @"直连Workers，管理本人公开、登录可见及私密说说。" : _error ? _error.localizedDescription : @"新建默认仅自己可见；归档与永久删除是不同操作。",
      !configured ? @"连接Memos" : _error ? @"重试" : nil, !configured ? ^{ LBMemosPresentConnection(weakSelf); } : _error ? ^{ [weakSelf refresh]; } : nil);
  } else _table.backgroundView = nil;
  NSDictionary *progress = [LBMemosClient.shared cacheProgress];
  BOOL caching = [progress[@"running"] boolValue] || [progress[@"failed"] unsignedIntegerValue] > 0 || [progress[@"error"] boolValue];
  if (caching && _display.count) {
    if (!_cacheProgressLabel) {
      _cacheProgressLabel = [UILabel new]; _cacheProgressLabel.numberOfLines = 0; _cacheProgressLabel.textAlignment = NSTextAlignmentCenter;
      _cacheProgressLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1]; _cacheProgressLabel.textColor = LBTheme.muted;
    }
    UILabel *label = _cacheProgressLabel;
    NSString *text = [NSString stringWithFormat:@"附件本地缓存 %@/%@ · 失败%@（下拉重试）", progress[@"completed"] ?: @0, progress[@"total"] ?: @0, progress[@"failed"] ?: @0];
    if ([progress[@"error"] boolValue]) text = [text stringByAppendingString:@"\n部分缓存未完成，请检查网络或本机可用空间。"];
    if (![label.text isEqualToString:text]) label.text = text;
    CGRect frame = CGRectMake(12, 0, MAX(1, _table.bounds.size.width-24), 50);
    if (!CGRectEqualToRect(label.frame, frame)) label.frame = frame;
    if (_table.tableFooterView != label) _table.tableFooterView = label;
  } else if (_more || (_loading && !_display.count) || (_error && _display.count)) {
    UIButtonConfiguration *c = [UIButtonConfiguration glassButtonConfiguration]; c.title = _loading ? @"加载中…" : _error ? @"重试 / 刷新" : @"加载更多"; c.showsActivityIndicator = _loading;
    __weak typeof(self) weakSelf = self;
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) { typeof(self) self = weakSelf; if (!self) return; if (self->_error) [self refresh]; else [self fetch:YES]; }]];
    b.enabled = !_loading; b.frame = CGRectMake(16, 8, MAX(1, _table.bounds.size.width-32), 44); b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _table.bounds.size.width, 60)]; [footer addSubview:b]; _table.tableFooterView = footer;
  } else _table.tableFooterView = nil;
  if (![_lastRenderedRows isEqual:_display]) {
    _lastRenderedRows = [_display copy];
    [UIView performWithoutAnimation:^{ [self->_table reloadData]; }];
  }
}
- (NSArray<NSDictionary *> *)ordered:(NSArray<NSDictionary *> *)rows {
  return [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    BOOL pa = [a[@"pinned"] boolValue], pb = [b[@"pinned"] boolValue];
    if (pa != pb) return pa ? NSOrderedAscending : NSOrderedDescending;
    NSComparisonResult time = [b[@"displayTs"] compare:a[@"displayTs"]];
    return time == NSOrderedSame ? [b[@"id"] compare:a[@"id"]] : time;
  }];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
  if (path.row >= (NSInteger)_display.count) return nil;
  NSDictionary *memo = _display[path.row]; BOOL archived = [memo[@"rowStatus"] isEqual:@"ARCHIVED"];
  __weak typeof(self) weakSelf = self;
  UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:archived ? @"永久删除" : @"删除" handler:^(UIContextualAction *action, UIView *view, void (^finish)(BOOL)) {
    typeof(self) self = weakSelf; if (!self) { finish(NO); return; }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:archived ? @"永久删除说说？" : @"将说说移至归档？" message:archived ? @"正文无法恢复。不会自动删除可能被其他说说引用的附件文件。" : @"删除先移至归档，可恢复；在归档中可再次确认永久删除。" preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) { finish(NO); }]];
    [confirm addAction:[UIAlertAction actionWithTitle:archived ? @"永久删除" : @"移至归档" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
      if (archived) [LBMemosClient.shared deleteArchived:memo done:^(NSError *error) { finish(error == nil); if (error) LBMemosShowError(self, error); }];
      else [LBMemosClient.shared updateMemo:memo fields:@{@"rowStatus":@"ARCHIVED"} done:^(NSDictionary *row, NSError *error) { finish(error == nil); if (error) LBMemosShowError(self, error); }];
    }]];
    if (!archived) [confirm addAction:[UIAlertAction actionWithTitle:@"永久删除（不可恢复）" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
      NSUInteger generation = LBMemosClient.shared.generation;
      [LBMemosClient.shared updateMemo:memo fields:@{@"rowStatus":@"ARCHIVED"} done:^(NSDictionary *row, NSError *error) {
        if (error || generation != LBMemosClient.shared.generation) { finish(NO); if (error) LBMemosShowError(self, error); return; }
        // Legacy server requires archived state first; one preflighted DELETE,
        // never retry or delete a record that has been restored elsewhere.
        [LBMemosClient.shared deleteArchived:row done:^(NSError *deletionError) {
          finish(deletionError == nil); if (deletionError) LBMemosShowError(self, deletionError);
        }];
      }];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
  }];
  UIContextualAction *edit = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"编辑" handler:^(UIContextualAction *a, UIView *view, void (^finish)(BOOL)) {
    finish(YES);
    [weakSelf editMemo:memo];
  }];
  edit.backgroundColor = LBTheme.accent;
  UISwipeActionsConfiguration *actions = [UISwipeActionsConfiguration configurationWithActions:@[edit, action]]; actions.performsFirstActionWithFullSwipe = NO; return actions;
}
// Same gate as the detail page: a verified user of the current connection.
- (void)editMemo:(NSDictionary *)memo {
  LBMemosClient *client = LBMemosClient.shared;
  if (!memo || self.presentedViewController) return;
  if (!client.configured || client.authenticationRequired) { LBMemosPresentConnection(self); return; }
  if (_context != client.generation) return; // row belongs to a previous connection
  if (!client.user) {
    NSUInteger generation = client.generation;
    __weak typeof(self) weakSelf = self;
    [client validate:^(NSDictionary *user, NSError *error) {
      typeof(self) self = weakSelf;
      if (!self || generation != LBMemosClient.shared.generation) return;
      if (error) LBMemosShowError(self, error);
      else if (user && self->_visible) [self editMemo:memo];
    }];
    return;
  }
  LBMemosEditor *editor = [[LBMemosEditor alloc] initWithMemo:memo saved:nil];
  LBNavigationController *nav = [[LBNavigationController alloc] initWithRootViewController:editor];
  nav.modalPresentationStyle = UIModalPresentationPageSheet; nav.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
  [self presentViewController:nav animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
  _swipeActive = YES;
  LBStyleSwipeActions(tableView);
}
- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
  _swipeActive = NO;
  if (!_needsRender) return;
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    typeof(self) self = weakSelf;
    if (self && !self->_swipeActive && self->_needsRender) [self render];
  });
}
- (void)thumbnailTapped:(UITapGestureRecognizer *)tap {
  NSDictionary *resource = objc_getAssociatedObject(tap.view, "resource");
  if (!resource) return;
  NSURL *file = [LBMemosClient.shared cachedResource:resource];
  if (file.isFileURL) {
    [self openImagePreview:file];
    return;
  }
  __weak typeof(self) weakOwner = self;
  NSUInteger generation = LBMemosClient.shared.generation;
  [LBMemosClient.shared downloadResource:resource done:^(NSURL *downloaded, NSError *error) {
    if (downloaded) {
      dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) owner = weakOwner;
        if (owner && owner->_visible && generation == LBMemosClient.shared.generation) [owner openImagePreview:downloaded];
      });
    }
  }];
}
- (void)openImagePreview:(NSURL *)file {
  if (self.presentedViewController || !file.isFileURL) return;
  [[UIImpactFeedbackGenerator feedbackGeneratorWithStyle:UIImpactFeedbackStyleLight forView:self.view] impactOccurred];
  LBReaderImageController *img = [[LBReaderImageController alloc] initWithLocalFile:file];
  UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:img];
  nav.modalPresentationStyle = UIModalPresentationFullScreen;
  [self presentViewController:nav animated:YES completion:nil];
}

- (UIView *)buildThumbnailItem:(NSDictionary *)resource width:(CGFloat)w height:(CGFloat)h {
  UIImageView *iv = [UIImageView new];
  iv.contentMode = UIViewContentModeScaleAspectFill;
  iv.clipsToBounds = YES;
  iv.layer.cornerRadius = 10;
  iv.layer.cornerCurve = kCACornerCurveContinuous;
  iv.layer.borderWidth = 0.5;
  iv.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
  iv.backgroundColor = LBTheme.accentSoft;
  iv.translatesAutoresizingMaskIntoConstraints = NO;
  iv.userInteractionEnabled = YES;
  UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(thumbnailTapped:)];
  [iv addGestureRecognizer:tap];
  objc_setAssociatedObject(iv, "resource", resource, OBJC_ASSOCIATION_COPY_NONATOMIC);
  [NSLayoutConstraint activateConstraints:@[
    [iv.widthAnchor constraintEqualToConstant:w],
    [iv.heightAnchor constraintEqualToConstant:h]
  ]];
  [self loadThumbnail:resource intoView:iv];
  return iv;
}

- (void)loadThumbnail:(NSDictionary *)resource intoView:(UIImageView *)iv {
  NSUInteger generation = LBMemosClient.shared.generation;
  NSString *fingerprint = [LBMemosDiskCache fingerprint:resource];
  if (!fingerprint.length) return;
  NSString *key = [NSString stringWithFormat:@"%lu:%@", (unsigned long)generation, fingerprint];
  UIImage *cached = [_thumbnails objectForKey:key];
  if (cached) { iv.image = cached; return; }
  NSHashTable *waiters = _thumbnailWaiters[key];
  if (waiters) { [waiters addObject:iv]; return; }
  waiters = [NSHashTable weakObjectsHashTable]; [waiters addObject:iv];
  _thumbnailWaiters[key] = waiters;
  __weak typeof(self) weakSelf = self;
  // Originals/downloads already have versioned disk caching and deduplication
  // in the client. Cache decoded thumbnails too; never retain detached cells.
  [LBMemosClient.shared downloadResource:resource done:^(NSURL *file, NSError *error) {
    typeof(self) owner = weakSelf;
    if (!owner || generation != LBMemosClient.shared.generation) return;
    if (!file) { [owner->_thumbnailWaiters removeObjectForKey:key]; return; }
    [owner->_thumbnailQueue addOperationWithBlock:^{
      @autoreleasepool {
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)file,
            (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@NO});
        UIImage *img = nil; NSUInteger cost = 0;
        if (src) {
          NSDictionary *opts = @{
            (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (id)kCGImageSourceThumbnailMaxPixelSize: @(360),
            (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (id)kCGImageSourceShouldCacheImmediately: @YES
          };
          CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
          if (thumb) {
            cost = CGImageGetBytesPerRow(thumb) * CGImageGetHeight(thumb);
            img = [UIImage imageWithCGImage:thumb]; CGImageRelease(thumb);
          }
          CFRelease(src);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
          typeof(self) self = weakSelf;
          if (!self || generation != LBMemosClient.shared.generation) return;
          if (img) {
            [self->_thumbnails setObject:img forKey:key cost:cost];
            for (UIImageView *view in self->_thumbnailWaiters[key]) view.image = img;
          }
          [self->_thumbnailWaiters removeObjectForKey:key];
        });
      }
    }];
  }];
}

- (void)populateThumbnails:(NSDictionary *)memo inCell:(LBCardCell *)cell {
  NSArray *resources = memo[@"resourceList"];
  if (![resources isKindOfClass:NSArray.class] || !resources.count) return;
  NSMutableArray<NSDictionary *> *images = [NSMutableArray array];
  for (NSDictionary *r in resources) {
    NSString *type = [r[@"type"] lowercaseString] ?: @"";
    if ([type hasPrefix:@"image/"]) [images addObject:r];
  }
  if (!images.count) return;

  if (images.count == 1) {
    UIView *item = [self buildThumbnailItem:images.firstObject width:180 height:120];
    [cell.mediaStack addArrangedSubview:item];
  } else if (images.count <= 3) {
    UIStackView *row = [UIStackView new];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6;
    row.alignment = UIStackViewAlignmentCenter;
    for (NSDictionary *img in images) {
      [row addArrangedSubview:[self buildThumbnailItem:img width:76 height:76]];
    }
    [row addArrangedSubview:[UIView new]];
    [cell.mediaStack addArrangedSubview:row];
  } else if (images.count == 4) {
    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 6;
    col.alignment = UIStackViewAlignmentLeading;
    for (int r = 0; r < 2; r++) {
      UIStackView *row = [UIStackView new];
      row.axis = UILayoutConstraintAxisHorizontal;
      row.spacing = 6;
      for (int c = 0; c < 2; c++) {
        [row addArrangedSubview:[self buildThumbnailItem:images[r * 2 + c] width:76 height:76]];
      }
      [row addArrangedSubview:[UIView new]];
      [col addArrangedSubview:row];
    }
    [cell.mediaStack addArrangedSubview:col];
  } else {
    UIStackView *col = [UIStackView new];
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 6;
    col.alignment = UIStackViewAlignmentLeading;
    NSUInteger total = MIN(9, images.count);
    for (NSUInteger i = 0; i < total; i += 3) {
      UIStackView *row = [UIStackView new];
      row.axis = UILayoutConstraintAxisHorizontal;
      row.spacing = 6;
      for (NSUInteger j = i; j < MIN(i + 3, total); j++) {
        UIView *item = [self buildThumbnailItem:images[j] width:68 height:68];
        if (j == 8 && images.count > 9) {
          UILabel *more = [UILabel new];
          more.text = [NSString stringWithFormat:@"+%lu", (unsigned long)(images.count - 9)];
          more.font = [LBTheme rounded:16 weight:UIFontWeightBold];
          more.textColor = UIColor.whiteColor;
          more.textAlignment = NSTextAlignmentCenter;
          more.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
          more.translatesAutoresizingMaskIntoConstraints = NO;
          [item addSubview:more];
          [NSLayoutConstraint activateConstraints:@[
            [more.leadingAnchor constraintEqualToAnchor:item.leadingAnchor],
            [more.trailingAnchor constraintEqualToAnchor:item.trailingAnchor],
            [more.topAnchor constraintEqualToAnchor:item.topAnchor],
            [more.bottomAnchor constraintEqualToAnchor:item.bottomAnchor]
          ]];
        }
        [row addArrangedSubview:item];
      }
      [row addArrangedSubview:[UIView new]];
      [col addArrangedSubview:row];
    }
    [cell.mediaStack addArrangedSubview:col];
  }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _display.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
  LBCardCell *cell = [tableView dequeueReusableCellWithIdentifier:@"card" forIndexPath:path];
  if (path.row >= (NSInteger)_display.count) { [cell finishConfiguration]; return cell; }
  NSDictionary *memo = _display[path.row];
  cell.titleLabel.text = LBRelativeTime([memo[@"displayTs"] longLongValue] * 1000);
  cell.titleLabel.font = [LBTheme rounded:13 weight:UIFontWeightSemibold]; cell.titleLabel.textColor = LBTheme.accent;
  cell.metaLabel.text = nil; cell.bodyLabel.text = LBMemoPlain(memo[@"content"]); cell.bodyLabel.numberOfLines = 7;
  [self populateThumbnails:memo inCell:cell];
  if ([memo[@"pinned"] boolValue]) [cell.extraStack addArrangedSubview:LBChip(@"置顶", LBTheme.accent)];
  NSString *vis = memo[@"visibility"];
  if ([vis isEqual:@"PRIVATE"]) [cell.extraStack addArrangedSubview:LBChip(@"仅自己", LBTheme.muted)];
  else if ([vis isEqual:@"PROTECTED"]) [cell.extraStack addArrangedSubview:LBChip(@"登录可见", UIColor.systemIndigoColor)];
  else [cell.extraStack addArrangedSubview:LBChip(@"公开", UIColor.systemTealColor)];
  NSArray *resources = memo[@"resourceList"];
  if (resources.count) {
    NSUInteger imgs = 0, audios = 0, videos = 0, others = 0;
    for (NSDictionary *r in resources) {
      NSString *type = [r[@"type"] lowercaseString] ?: @"";
      if ([type hasPrefix:@"image/"]) imgs++;
      else if ([type hasPrefix:@"audio/"]) audios++;
      else if ([type hasPrefix:@"video/"]) videos++;
      else others++;
    }
    if (imgs) [cell.extraStack addArrangedSubview:LBChip(@"图片", LBTheme.muted)];
    if (videos) [cell.extraStack addArrangedSubview:LBChip(@"视频", UIColor.systemPurpleColor)];
    if (audios) [cell.extraStack addArrangedSubview:LBChip(@"音频", UIColor.systemOrangeColor)];
    if (others) [cell.extraStack addArrangedSubview:LBChip(@"附件", LBTheme.muted)];
  }
  [cell.extraStack addArrangedSubview:[UIView new]];
  [cell finishConfiguration]; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
  if (path.row >= (NSInteger)_display.count) return;
  [self.navigationController pushViewController:[[LBMemosDetailController alloc] initWithMemo:_display[path.row]] animated:YES];
}
- (void)compose {
  if (!LBMemosClient.shared.configured || LBMemosClient.shared.authenticationRequired) { LBMemosPresentConnection(self); return; }
  if (!LBMemosClient.shared.user) {
    [LBMemosClient.shared validate:^(NSDictionary *user, NSError *error) {
      if (error) LBMemosShowError(self, error); else [self compose];
    }]; return;
  }
  LBMemosEditor *editor = [[LBMemosEditor alloc] initWithMemo:nil saved:nil];
  LBNavigationController *nav = [[LBNavigationController alloc] initWithRootViewController:editor];
  nav.modalPresentationStyle = UIModalPresentationPageSheet; nav.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
  [self presentViewController:nav animated:YES completion:nil];
}
- (void)pickTag {
  [LBMemosClient.shared tags:^(NSArray<NSString *> *tags, NSError *error) {
    if (error) { LBMemosShowError(self, error); return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"筛选标签" message:@"输入完整标签（无需#），也可从下方选择。" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"标签 / 子标签"; field.text = self->_tag; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"筛选" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
      self->_tag = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if ([self->_tag hasPrefix:@"#"]) self->_tag = [self->_tag substringFromIndex:1]; [self refresh];
    }]];
    for (NSString *tag in [tags subarrayWithRange:NSMakeRange(0, MIN(8, tags.count))])
      [a addAction:[UIAlertAction actionWithTitle:[@"#" stringByAppendingString:tag] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { self->_tag = tag; [self refresh]; }]];
    if (!self.presentedViewController) [self presentViewController:a animated:YES completion:nil];
  }];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)search {
  if (!search.active || _searchDismissing) return;
  _nextQuery = [search.searchBar.text copy] ?: @"";
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applySearch) object:nil];
  [self performSelector:@selector(applySearch) withObject:nil afterDelay:0.35];
}
- (void)applySearch { if (_searchDismissing) return; _query = _nextQuery ?: @""; [self render]; }
- (void)willDismissSearchController:(UISearchController *)search {
  _searchDismissing = YES; [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applySearch) object:nil];
}
- (void)didDismissSearchController:(UISearchController *)search { _searchDismissing = NO; _query = @""; _nextQuery = @""; [self render]; }
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate { if (!decelerate && _needsRender) [self render]; }
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { if (_needsRender) [self render]; }
@end

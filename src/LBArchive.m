#import "LBArchive.h"

@interface LBArchiveViewController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation LBArchiveViewController {
  UITableView *_table;
  NSMutableArray<LBSession *> *_sessions;
  NSString *_nextCursor;
  NSError *_error;
  BOOL _loading, _visible, _needsRender;
  NSArray<LBSession *> *_displaySessions;
  NSUInteger _generation, _connectionRevision;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"过期归档";
  self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
  _sessions = [NSMutableArray array];
  _displaySessions = @[];
  _table = LBGlassTable(self, self);
  UIRefreshControl *refresh = [UIRefreshControl new];
  [refresh addTarget:self action:@selector(reloadArchive) forControlEvents:UIControlEventValueChanged];
  _table.refreshControl = refresh;
  [self reloadArchive];
}
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  if (_connectionRevision != LBAPI.shared.connectionRevision) [self reloadArchive];
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  _visible = YES;
  [self render];
}
- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  _visible = NO;
}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
  if (!decelerate && _needsRender) [self render];
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { if (_needsRender) [self render]; }
- (void)reloadArchive {
  _generation++;
  _loading = NO;
  _connectionRevision = LBAPI.shared.connectionRevision;
  [_sessions removeAllObjects];
  _nextCursor = nil;
  _error = nil;
  [self fetchPage:nil];
}
- (void)fetchPage:(NSString *)cursor {
  if (_loading) return;
  _loading = YES;
  NSUInteger generation = _generation;
  [self render];
  [LBAPI.shared fetchArchivedSessions:cursor done:^(NSArray<LBSession *> *sessions, NSString *next, NSError *e) {
    if (generation != self->_generation) return;
    self->_loading = NO;
    [self->_table.refreshControl endRefreshing];
    if (self->_connectionRevision != LBAPI.shared.connectionRevision) {
      [self->_sessions removeAllObjects];
      self->_nextCursor = nil;
      self->_error = [NSError errorWithDomain:@"LBArchive" code:409 userInfo:@{ NSLocalizedDescriptionKey : @"连接已变更，请下拉刷新归档" }];
      [self render];
      return;
    }
    self->_error = e;
    if (!e) {
      NSMutableSet *seen = [NSMutableSet setWithArray:[self->_sessions valueForKey:@"sessionId"]];
      for (LBSession *session in sessions) {
        if (![seen containsObject:session.sessionId]) { [self->_sessions addObject:session]; [seen addObject:session.sessionId]; }
      }
      self->_nextCursor = next;
    }
    [self render];
  }];
}
- (void)loadMore { if (_nextCursor) [self fetchPage:_nextCursor]; else if (_error) [self reloadArchive]; }
- (void)render {
  _needsRender = YES;
  if (!_visible || _table.dragging || _table.decelerating) return;
  _needsRender = NO;
  _displaySessions = [_sessions copy];
  self.navigationItem.subtitle = @"仅站长可见 · 永久保留 · 可手动删除";
  self.navigationItem.prompt = _error && _sessions.count ? _error.localizedDescription : nil;
  if (!_sessions.count) {
    NSString *title = _loading ? @"加载归档…" : _error ? @"暂时无法读取归档" : @"暂无过期会话";
    NSString *body = _error ? _error.localizedDescription : @"会话在首次留言72小时后结束，随后仅站长可只读查看。归档永久保留，左滑可手动删除。已被旧版本清理的消息无法恢复。";
    __weak typeof(self) weakSelf = self;
    _table.backgroundView = LBNotice(@"archivebox", title, body, _error ? @"重试" : nil, _error ? ^{ [weakSelf reloadArchive]; } : nil);
  } else _table.backgroundView = nil;
  if (_nextCursor || _loading || _error) {
    UIButtonConfiguration *config = [UIButtonConfiguration glassButtonConfiguration];
    config.title = _loading ? @"加载中…" : _error ? @"重试" : @"加载更多归档";
    config.showsActivityIndicator = _loading;
    config.contentInsets = NSDirectionalEdgeInsetsMake(12, 16, 12, 16);
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [self loadMore]; }]];
    button.enabled = !_loading;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _table.bounds.size.width, 64)];
    button.frame = CGRectInset(footer.bounds, 24, 8);
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [footer addSubview:button];
    _table.tableFooterView = footer;
  } else _table.tableFooterView = nil;
  [UIView performWithoutAnimation:^{ [self->_table reloadData]; }];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _displaySessions.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
  LBCardCell *cell = [tableView dequeueReusableCellWithIdentifier:@"card" forIndexPath:path];
  LBSession *session = _displaySessions[path.row];
  cell.titleLabel.text = [NSString stringWithFormat:@"#%@", session.shortId];
  cell.metaLabel.text = [NSString stringWithFormat:@"已结束 · %@ · %ld 条消息", LBDateText([NSDate dateWithTimeIntervalSince1970:session.expiresAt / 1000.0]), (long)session.sequence];
  cell.bodyLabel.text = session.last.text;
  cell.bodyLabel.textColor = LBTheme.muted;
  [cell.extraStack addArrangedSubview:LBChip(@"归档 · 只读", LBTheme.accent)];
  [cell.extraStack addArrangedSubview:LBChip(@"永久保留", LBTheme.muted)];
  [cell.extraStack addArrangedSubview:[UIView new]];
  [cell finishConfiguration];
  return cell;
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)path {
  LBSession *session = _displaySessions[path.row];
  __weak typeof(self) weakSelf = self;
  UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除"
      handler:^(UIContextualAction *action, UIView *source, void (^completion)(BOOL)) {
    completion(NO); // Swiping never deletes without an explicit confirmation.
    typeof(self) self = weakSelf;
    if (!self || self->_loading || self->_connectionRevision != LBAPI.shared.connectionRevision) return;
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"删除归档 #%@？", session.shortId]
        message:@"将永久删除这段会话的云端归档、仍残留的消息及邮箱信息。其他设备也将无法再查看，且不可恢复。"
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"永久删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
      if (self->_connectionRevision != LBAPI.shared.connectionRevision) { [self reloadArchive]; return; }
      self->_generation++;
      self->_loading = YES;
      self.modalInPresentation = YES;
      [self render];
      [LBAPI.shared deleteArchivedSession:session.sessionId done:^(NSError *error) {
        self.modalInPresentation = NO;
        self->_loading = NO;
        if (error) { self->_error = error; [self render]; return; }
        [self reloadArchive];
      }];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
  }];
  remove.image = [UIImage systemImageNamed:@"trash"];
  UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[ remove ]];
  config.performsFirstActionWithFullSwipe = NO;
  return config;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
  if (_connectionRevision != LBAPI.shared.connectionRevision) { [self reloadArchive]; return; }
  [self.navigationController pushViewController:[[LBChatViewController alloc] initWithSession:_displaySessions[path.row]] animated:YES];
}
@end

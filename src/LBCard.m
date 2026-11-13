#import "LBLayout.h"

static NSDictionary *LBCachedParagraphAttrs(void) {
  static NSDictionary *attrs;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.lineSpacing = 3.5;
    style.paragraphSpacing = 2.0;
    // Wrap inside the attributed string; the label truncates its last line.
    // A truncating paragraph style makes text measurement treat every
    // paragraph as one line, so the measured row height can come out short.
    style.lineBreakMode = NSLineBreakByWordWrapping;
    attrs = @{
      NSParagraphStyleAttributeName: style,
      NSFontAttributeName: [UIFont systemFontOfSize:15],
      NSForegroundColorAttributeName: LBTheme.ink
    };
  });
  return attrs;
}

// Real text width of a chip (a few short strings per cell, microseconds).
static inline CGFloat LBChipWidth(UIView *view) {
  if ([view isKindOfClass:UILabel.class]) {
    UILabel *l = (UILabel *)view;
    return ceil([l.text ?: @"" sizeWithAttributes:@{ NSFontAttributeName: l.font }].width);
  }
  CGFloat w = view.intrinsicContentSize.width;
  return w > 0 ? w : 18.0;
}

@implementation LBCardCell {
  UIVisualEffectView *_glass;
  UIStackView *_stack, *_head;
  UIView *_trailingHost;
  UIColor *_currentTint;
  UILabel *_moreChip;
  CGFloat _lastChipAvailable;
}
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
  if ((self = [super initWithStyle:style reuseIdentifier:rid])) {
    self.backgroundColor = UIColor.clearColor;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    // The default list background is re-applied for swiped/highlighted states,
    // painting an opaque rectangle behind the rounded card while swiping.
    self.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    self.automaticallyUpdatesBackgroundConfiguration = NO;
    _glass = [LBTheme glassWithTint:[LBTheme.surface colorWithAlphaComponent:0.35] interactive:YES];
    _glass.cornerConfiguration = [UICornerConfiguration configurationWithUniformRadius:[UICornerRadius fixedRadius:24]];
    [self.contentView addSubview:_glass];
    _titleLabel = [UILabel new];
    _titleLabel.font = [LBTheme rounded:17 weight:UIFontWeightSemibold];
    _titleLabel.textColor = LBTheme.ink;
    _titleLabel.numberOfLines = 2;
    [_titleLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];

    _metaLabel = [UILabel new];
    _metaLabel.font = [LBTheme rounded:12 weight:UIFontWeightMedium];
    _metaLabel.textColor = LBTheme.muted;
    _metaLabel.numberOfLines = 1;
    [_metaLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [_metaLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];

    _bodyLabel = [UILabel new];
    _bodyLabel.font = [UIFont systemFontOfSize:15];
    _bodyLabel.textColor = LBTheme.ink;
    _bodyLabel.numberOfLines = 3;
    [_bodyLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisVertical];
    // Line count is bounded, so the body may never be squeezed; previously it
    // tied (750) with the bottom anchors and the solver could cut either one.
    [_bodyLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];

    _extraStack = [UIStackView new];
    _extraStack.axis = UILayoutConstraintAxisHorizontal;
    _extraStack.spacing = 6;
    _extraStack.alignment = UIStackViewAlignmentCenter;
    _mediaStack = [UIStackView new];
    _mediaStack.axis = UILayoutConstraintAxisVertical;
    _mediaStack.spacing = 6;
    _mediaStack.alignment = UIStackViewAlignmentLeading;
    _trailingHost = [UIView new];
    _trailingHost.hidden = YES;
    [_trailingHost setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _head = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _trailingHost ]];
    _head.spacing = 8;
    _head.alignment = UIStackViewAlignmentTop;
    [_head setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [_head setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    _stack = [[UIStackView alloc] initWithArrangedSubviews:@[ _head, _metaLabel, _bodyLabel, _mediaStack, _extraStack ]];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 6;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_glass.contentView addSubview:_stack];
    [_extraStack setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    // Content is never compressible; only the outer cell-bottom link may yield
    // (999) during a transient row height, so the card overflows, never cuts.
    NSLayoutConstraint *glassBottom = [_glass.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6];
    glassBottom.priority = UILayoutPriorityRequired - 1;
    NSLayoutConstraint *stackBottom = [_stack.bottomAnchor constraintEqualToAnchor:_glass.contentView.bottomAnchor constant:-16];

    [NSLayoutConstraint activateConstraints:@[
      [_glass.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
      glassBottom,
      [_glass.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
      [_glass.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
      [_stack.topAnchor constraintEqualToAnchor:_glass.contentView.topAnchor constant:16],
      stackBottom,
      [_stack.leadingAnchor constraintEqualToAnchor:_glass.contentView.leadingAnchor constant:18],
      [_stack.trailingAnchor constraintEqualToAnchor:_glass.contentView.trailingAnchor constant:-18],
    ]];
  }
  return self;
}
static CGFloat LBScreenWidth(UIView *view) {
  UIWindowScene *ws = view.window.windowScene;
  if ([ws respondsToSelector:@selector(screen)] && ws.screen.bounds.size.width > 60) {
    return ws.screen.bounds.size.width;
  }
  return 390.0;
}

- (CGSize)systemLayoutSizeFittingSize:(CGSize)targetSize
        withHorizontalFittingPriority:(UILayoutPriority)horizontalFittingPriority
              verticalFittingPriority:(UILayoutPriority)verticalFittingPriority {
  CGFloat screenW = LBScreenWidth(self);
  CGFloat w = targetSize.width > 60 ? targetSize.width : (self.contentView.bounds.size.width > 60 ? self.contentView.bounds.size.width : screenW);
  CGFloat available = w - 68;
  if (available > 60) {
    _titleLabel.preferredMaxLayoutWidth = available;
    _bodyLabel.preferredMaxLayoutWidth = available;
  }
  return [super systemLayoutSizeFittingSize:targetSize
              withHorizontalFittingPriority:horizontalFittingPriority
                    verticalFittingPriority:verticalFittingPriority];
}

- (void)prepareForReuse {
  [super prepareForReuse];
  [self resetCardContent];
}
// Idempotent; also used before an in-place reconfigure (no prepareForReuse then).
- (void)resetCardContent {
  for (UIView *v in _extraStack.arrangedSubviews) [v removeFromSuperview];
  _moreChip = nil; _lastChipAvailable = 0;
  for (UIView *v in _mediaStack.arrangedSubviews) [v removeFromSuperview];
  self.trailingView = nil;
  [self setCardTint:nil];
  _titleLabel.text = nil;
  _titleLabel.hidden = NO;
  _titleLabel.font = [LBTheme rounded:17 weight:UIFontWeightSemibold];
  _titleLabel.textColor = LBTheme.ink;
  _titleLabel.numberOfLines = 2;
  _head.hidden = NO;
  _metaLabel.text = nil;
  _metaLabel.numberOfLines = 1;
  _metaLabel.hidden = NO;
  _metaLabel.font = [LBTheme rounded:12 weight:UIFontWeightMedium];
  _bodyLabel.attributedText = nil;
  _bodyLabel.text = nil;
  _bodyLabel.font = [UIFont systemFontOfSize:15];
  _bodyLabel.textColor = LBTheme.ink;
  _bodyLabel.numberOfLines = 3;
  _bodyLabel.hidden = NO;
}
- (void)finishConfiguration {
  CGFloat screenW = LBScreenWidth(self);
  CGFloat w = self.contentView.bounds.size.width > 60 ? self.contentView.bounds.size.width : screenW;
  CGFloat available = w - 68;
  if (available > 60) {
    _titleLabel.preferredMaxLayoutWidth = available;
    _bodyLabel.preferredMaxLayoutWidth = available;
  }
  _titleLabel.hidden = !_titleLabel.text.length;
  _head.hidden = !_titleLabel.text.length && _trailingHost.hidden;
  _metaLabel.hidden = !_metaLabel.text.length;
  _mediaStack.hidden = _mediaStack.arrangedSubviews.count == 0;
  if (_bodyLabel.text.length && _bodyLabel.numberOfLines != 1) {
    _bodyLabel.attributedText = [[NSAttributedString alloc] initWithString:_bodyLabel.text attributes:LBCachedParagraphAttrs()];
    _bodyLabel.lineBreakMode = NSLineBreakByTruncatingTail; // ellipsis on the last visible line
    [_bodyLabel invalidateIntrinsicContentSize];
  }
  _bodyLabel.hidden = !_bodyLabel.text.length && !_bodyLabel.attributedText.length;
  [self setNeedsLayout];

  _lastChipAvailable = 0; // configuration may have added badges at the same width
  [self fitChipsOnOneRow:available];
  _extraStack.hidden = _extraStack.arrangedSubviews.count == 0;
}
// Badges always stay on one row: measure real widths against the real card
// width; whatever does not fit collapses into a trailing "+N" chip.
- (void)layoutSubviews {
  [super layoutSubviews];
  // A dequeued cell can still have UIKit's preliminary 320pt width. Refit at
  // the final width (and after rotation) without discarding any original chip.
  [self fitChipsOnOneRow:self.contentView.bounds.size.width - 68];
}
- (void)fitChipsOnOneRow:(CGFloat)available {
  if (available <= 60 || _lastChipAvailable == available) return;
  NSMutableArray<UIView *> *chips = [NSMutableArray array];
  for (UIView *v in _extraStack.arrangedSubviews) {
    if (v == _moreChip) continue;
    if ([v isKindOfClass:UILabel.class] || [v isKindOfClass:UIImageView.class]) [chips addObject:v];
    else if (v.class != UIView.class) return; // custom media strips stay untouched
  }
  _lastChipAvailable = available;
  for (UIView *chip in chips) chip.hidden = NO;
  _moreChip.hidden = YES;
  if (chips.count < 2) return;
  CGFloat spacing = _extraStack.spacing, total = 0;
  for (UIView *v in chips) total += LBChipWidth(v) + spacing;
  if (total - spacing <= available) return;
  if (!_moreChip) {
    _moreChip = LBChip(@"+99", LBTheme.muted);
    [_extraStack addArrangedSubview:_moreChip];
  }
  _moreChip.text = [NSString stringWithFormat:@"  +%lu  ", (unsigned long)chips.count];
  CGFloat reserve = LBChipWidth(_moreChip) + spacing, used = 0;
  NSUInteger keep = 0;
  for (; keep < chips.count; keep++) {
    CGFloat w = LBChipWidth(chips[keep]);
    if (keep > 0 && used + w + reserve > available) break;
    used += w + spacing;
  }
  if (keep >= chips.count) return;
  // Hidden arranged subviews retain identity/order and can reappear on resize.
  for (NSUInteger i = keep; i < chips.count; i++) chips[i].hidden = YES;
  _moreChip.text = [NSString stringWithFormat:@"  +%lu  ", (unsigned long)(chips.count - keep)];
  _moreChip.hidden = NO;
}
- (void)setTrailingView:(UIView *)v {
  [_trailingView removeFromSuperview];
  _trailingView = v;
  _trailingHost.hidden = v == nil;
  if (!v) return;
  v.translatesAutoresizingMaskIntoConstraints = NO;
  [_trailingHost addSubview:v];
  [NSLayoutConstraint activateConstraints:@[
    [v.topAnchor constraintEqualToAnchor:_trailingHost.topAnchor], [v.bottomAnchor constraintEqualToAnchor:_trailingHost.bottomAnchor],
    [v.leadingAnchor constraintEqualToAnchor:_trailingHost.leadingAnchor], [v.trailingAnchor constraintEqualToAnchor:_trailingHost.trailingAnchor],
  ]];
}
- (void)setCardTint:(UIColor *)tint {
  if (_currentTint == tint || [_currentTint isEqual:tint]) return;
  _currentTint = tint;
  UIGlassEffect *g = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
  g.interactive = YES;
  g.tintColor = tint ?: [LBTheme.surface colorWithAlphaComponent:0.35];
  _glass.effect = g;
}
- (void)setHighlighted:(BOOL)h animated:(BOOL)a {
  [super setHighlighted:h animated:LBShouldAnimate(a)];
  if (!LBShouldAnimate(a)) { _glass.transform = CGAffineTransformIdentity; return; }
  if (h) {
    UIImpactFeedbackGenerator *f = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [f impactOccurredWithIntensity:0.65];
  }
  [UIView animateWithDuration:h ? 0.12 : 0.35 delay:0 usingSpringWithDamping:0.65 initialSpringVelocity:0
                      options:UIViewAnimationOptionAllowUserInteraction animations:^{
    self->_glass.transform = h ? CGAffineTransformMakeScale(0.975, 0.975) : CGAffineTransformIdentity;
  } completion:nil];
}
@end

#pragma mark - Small UI helpers shared by the site screens
@interface LBChipLabel : UILabel
@property (nonatomic, strong) UIColor *badgeColor;
@end

@implementation LBChipLabel
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.layer.cornerRadius = 9;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 0.5;
    self.clipsToBounds = YES;
    [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ] withAction:@selector(applyColors)];
  }
  return self;
}
- (void)setBadgeColor:(UIColor *)badgeColor {
  _badgeColor = badgeColor;
  [self applyColors];
}
- (void)applyColors {
  if (!_badgeColor) return;
  BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
  self.textColor = _badgeColor;
  self.backgroundColor = [_badgeColor colorWithAlphaComponent:dark ? 0.20 : 0.14];
  self.layer.borderColor = [_badgeColor colorWithAlphaComponent:dark ? 0.36 : 0.28].CGColor;
}
@end

UILabel *LBChip(NSString *text, UIColor *color) {
  LBChipLabel *l = [LBChipLabel new];
  l.text = [NSString stringWithFormat:@"  %@  ", text];
  l.font = [LBTheme rounded:11 weight:UIFontWeightSemibold];
  l.badgeColor = color;
  [l.heightAnchor constraintEqualToConstant:18].active = YES;
  return l;
}

UITableView *LBGlassTable(UIViewController *vc, id<UITableViewDataSource, UITableViewDelegate> owner) {
  UITableView *t = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
  t.backgroundColor = UIColor.clearColor;
  t.separatorStyle = UITableViewCellSeparatorStyleNone;
  t.dataSource = owner;
  t.delegate = owner;
  t.rowHeight = UITableViewAutomaticDimension;
  t.estimatedRowHeight = 110;
  t.contentInset = UIEdgeInsetsMake(4, 0, 24, 0);
  [t registerClass:LBCardCell.class forCellReuseIdentifier:@"card"];
  LBInstallContentScrollView(vc, t, nil);
  return t;
}

/// Shown above a list when data cannot be loaded (e.g. no GitHub token).
UIView *LBNotice(NSString *icon, NSString *title, NSString *body, NSString *_Nullable button, void (^_Nullable action)(void)) {
  UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icon]];
  iv.tintColor = LBTheme.accent;
  iv.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:40 weight:UIImageSymbolWeightLight];
  iv.contentMode = UIViewContentModeScaleAspectFit;
  iv.translatesAutoresizingMaskIntoConstraints = NO;
  [NSLayoutConstraint activateConstraints:@[
    [iv.widthAnchor constraintEqualToConstant:48],
    [iv.heightAnchor constraintEqualToConstant:48],
  ]];
  [iv setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
  [iv setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
  UILabel *t = [UILabel new];
  t.text = title; t.font = [LBTheme rounded:20 weight:UIFontWeightBold]; t.textColor = LBTheme.ink;
  t.numberOfLines = 0; t.textAlignment = NSTextAlignmentCenter;
  UILabel *b = [UILabel new];
  b.text = body; b.font = [UIFont systemFontOfSize:15]; b.textColor = LBTheme.muted;
  b.numberOfLines = 0; b.textAlignment = NSTextAlignmentCenter;
  NSMutableArray *views = [@[ iv, t, b ] mutableCopy];
  if (button && action) {
    UIButtonConfiguration *bc = [UIButtonConfiguration prominentGlassButtonConfiguration];
    bc.title = button;
    bc.baseBackgroundColor = LBTheme.accent;
    bc.contentInsets = NSDirectionalEdgeInsetsMake(12, 22, 12, 22);
    [views addObject:[UIButton buttonWithConfiguration:bc primaryAction:[UIAction actionWithHandler:^(UIAction *a) { action(); }]]];
  }
  UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:views];
  st.axis = UILayoutConstraintAxisVertical;
  st.alignment = UIStackViewAlignmentCenter;
  st.spacing = 12;
  st.distribution = UIStackViewDistributionFill;
  st.translatesAutoresizingMaskIntoConstraints = NO;
  [t setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisVertical];
  [b setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisVertical];
  [t setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
  [b setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
  // UITableView owns backgroundView's frame. Only a plain container may expand;
  // never return the arranged stack itself (its image would absorb spare height).
  // Inequality edges also give this wrapper a natural fitting height in a card.
  UIView *container = [UIView new];
  container.backgroundColor = UIColor.clearColor;
  [container addSubview:st];
  UILayoutGuide *safe = container.safeAreaLayoutGuide;
  NSLayoutConstraint *preferredWidth = [st.widthAnchor constraintEqualToAnchor:safe.widthAnchor constant:-48];
  preferredWidth.priority = UILayoutPriorityDefaultHigh;
  [NSLayoutConstraint activateConstraints:@[
    [st.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
    [st.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
    [st.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
    [st.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],
    [st.widthAnchor constraintLessThanOrEqualToConstant:360],
    [t.widthAnchor constraintEqualToAnchor:st.widthAnchor],
    [b.widthAnchor constraintEqualToAnchor:st.widthAnchor],
    preferredWidth,
    [st.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor constant:24],
    [st.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-24],
  ]];
  return container;
}

/// Swipe actions are drawn by UIKit as one full-row rectangle, taller than the
/// card (which keeps a 6pt margin above and below) and square-cornered, so it
/// reads as a detached color block next to the rounded card. Clip the action
/// strip to the card's vertical band and corner radius. Only layer masking is
/// used; if UIKit's view names change this simply does nothing.
static void LBMaskSwipeViews(UIView *view, NSUInteger depth) {
  for (UIView *sub in view.subviews) {
    if ([NSStringFromClass(sub.class) containsString:@"SwipeActionPullView"]) {
      CGFloat h = sub.bounds.size.height;
      if (h <= 24) continue;
      CAShapeLayer *mask = [sub.layer.mask isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer *)sub.layer.mask : [CAShapeLayer layer];
      // Very wide so the strip may keep growing while the finger drags.
      CGRect band = CGRectMake(0, 6, 4096, h - 12);
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      mask.frame = CGRectMake(-2048, 0, 8192, h);
      mask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectOffset(band, 2048, 0) cornerRadius:MIN(24, (h - 12) / 2)].CGPath;
      sub.layer.mask = mask;
      [CATransaction commit];
    } else if (depth < 3) {
      LBMaskSwipeViews(sub, depth + 1);
    }
  }
}
void LBStyleSwipeActions(UITableView *table) {
  __weak UITableView *weakTable = table;
  // UIKit inserts the action view right after the will-begin callback.
  dispatch_async(dispatch_get_main_queue(), ^{ if (weakTable) LBMaskSwipeViews(weakTable, 0); });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    if (weakTable) LBMaskSwipeViews(weakTable, 0);
  });
}

#import "LB.h"

@interface LBGlassCardView : UIVisualEffectView
@end

@implementation LBGlassCardView
- (instancetype)initWithEffect:(UIVisualEffect *)effect {
  if ((self = [super initWithEffect:effect])) {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = 0.5;
    [self applyBorderAppearance];
    [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ] withAction:@selector(applyBorderAppearance)];
  }
  return self;
}
- (void)applyBorderAppearance {
  BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
  self.layer.borderColor = (dark ? [UIColor colorWithWhite:1.0 alpha:0.18] : [UIColor colorWithWhite:1.0 alpha:0.35]).CGColor;
}
@end

@implementation LBTheme
static UIColor *dyn(UInt32 light, UInt32 dark) {
  UIColor *(^c)(UInt32) = ^(UInt32 v) {
    return [UIColor colorWithRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
  };
  UIColor *l = c(light), *d = c(dark);
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
    return t.userInterfaceStyle == UIUserInterfaceStyleDark ? d : l;
  }];
}
+ (UIColor *)accent { return dyn(0x98583e, 0xd5a182); }
+ (UIColor *)accentSoft { return [[self accent] colorWithAlphaComponent:0.16]; }
+ (UIColor *)paper { return dyn(0xf4efe6, 0x1d1b18); }
+ (UIColor *)surface { return dyn(0xfcfaf6, 0x2b2823); }
+ (UIColor *)ink { return dyn(0x302b25, 0xefe8dc); }
+ (UIColor *)muted { return dyn(0x80766a, 0xa69c8e); }
+ (UIFont *)mono:(CGFloat)s weight:(UIFontWeight)w { return [UIFont monospacedSystemFontOfSize:s weight:w]; }
+ (UIFont *)rounded:(CGFloat)s weight:(UIFontWeight)w {
  UIFont *f = [UIFont monospacedDigitSystemFontOfSize:s weight:w];
  UIFontDescriptor *d = [f.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
  return d ? [UIFont fontWithDescriptor:d size:s] : f;
}
+ (NSArray *)gradientForSession:(NSString *)sid {
  unsigned h = 5381;
  for (NSUInteger i = 0; i < sid.length; i++) h = h * 33 + [sid characterAtIndex:i];
  CGFloat hue = (h % 360) / 360.0;
  // Keep hues warm-ish but distinct; saturation tuned for both appearances.
  UIColor *a = [UIColor colorWithHue:hue saturation:0.55 brightness:0.92 alpha:1];
  UIColor *b = [UIColor colorWithHue:fmod(hue + 0.09, 1) saturation:0.70 brightness:0.70 alpha:1];
  return @[ (id)a.CGColor, (id)b.CGColor ];
}
+ (UIVisualEffectView *)glassWithTint:(UIColor *)tint interactive:(BOOL)interactive {
  UIGlassEffect *g = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
  g.interactive = interactive;
  g.tintColor = tint;
  LBGlassCardView *v = [[LBGlassCardView alloc] initWithEffect:g];
  return v;
}
@end

#pragma mark - Aurora
@implementation LBAuroraView {
  NSArray<CALayer *> *_blobs;
  BOOL _driftSuspended;
}
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.userInteractionEnabled = NO;
    self.backgroundColor = LBTheme.paper;
    NSMutableArray *a = [NSMutableArray array];
    UInt32 colors[] = {0xe9a27c, 0xc9785a, 0xf1cf9a, 0x9fb7a5};
    for (int i = 0; i < 4; i++) {
      CAGradientLayer *l = [CAGradientLayer layer];
      l.type = kCAGradientLayerRadial;
      UInt32 v = colors[i];
      UIColor *c = [UIColor colorWithRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
      l.colors = @[ (id)[c colorWithAlphaComponent:0.55].CGColor, (id)[c colorWithAlphaComponent:0].CGColor ];
      l.startPoint = CGPointMake(0.5, 0.5);
      l.endPoint = CGPointMake(1, 1);
      [self.layer addSublayer:l];
      [a addObject:l];
    }
    _blobs = a;
    [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ] withAction:@selector(applyAppearance)];
    for (NSString *name in @[ UIApplicationWillResignActiveNotification, UISceneWillDeactivateNotification ])
      [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(suspendDrift:) name:name object:nil];
    for (NSString *name in @[ UIApplicationDidBecomeActiveNotification, UISceneDidActivateNotification, UIAccessibilityReduceMotionStatusDidChangeNotification ])
      [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resumeDrift:) name:name object:nil];
  }
  return self;
}
- (void)stopDrift {
  for (CALayer *layer in _blobs) [layer removeAnimationForKey:@"drift"];
}
- (void)suspendDrift:(NSNotification *)note {
  if ([note.object isKindOfClass:UIScene.class] && note.object != self.window.windowScene) return;
  _driftSuspended = YES;
  [self stopDrift];
}
- (void)resumeDrift:(NSNotification *)note {
  if ([note.object isKindOfClass:UIScene.class] && note.object != self.window.windowScene) return;
  _driftSuspended = NO;
  if (UIAccessibilityIsReduceMotionEnabled()) [self stopDrift];
  [self setNeedsLayout];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)layoutSubviews {
  [super layoutSubviews];
  BOOL animate = self.window && !_driftSuspended && !UIAccessibilityIsReduceMotionEnabled() &&
    UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
    self.window.windowScene.activationState == UISceneActivationStateForegroundActive;
  if (!animate) [self stopDrift];
  CGSize s = self.bounds.size;
  CGFloat d = MAX(s.width, s.height) * 0.85;
  CGPoint centers[] = {{0.15, 0.08}, {0.95, 0.30}, {0.25, 0.75}, {0.85, 0.95}};
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (NSUInteger i = 0; i < _blobs.count; i++) {
    CALayer *l = _blobs[i];
    l.bounds = CGRectMake(0, 0, d, d);
    l.position = CGPointMake(centers[i].x * s.width, centers[i].y * s.height);
    if (animate && ![l animationForKey:@"drift"]) {
      CABasicAnimation *m = [CABasicAnimation animationWithKeyPath:@"transform"];
      CGFloat dx = (i % 2 ? -1 : 1) * s.width * 0.18, dy = (i < 2 ? 1 : -1) * s.height * 0.10;
      m.toValue = [NSValue valueWithCATransform3D:CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), 1.15, 1.15, 1)];
      m.duration = 9 + i * 2.5;
      m.autoreverses = YES;
      m.repeatCount = HUGE_VALF;
      m.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
      [l addAnimation:m forKey:@"drift"];
    }
  }
  [CATransaction commit];
}
- (void)applyAppearance {
  BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
  for (CALayer *l in _blobs) l.opacity = dark ? 0.45 : 1.0;
}
- (void)didMoveToWindow {
  [super didMoveToWindow];
  [self applyAppearance];
  // Detached views can remain retained by navigation/tab controllers.
  if (!self.window) [self stopDrift];
  else _driftSuspended = UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
    self.window.windowScene.activationState != UISceneActivationStateForegroundActive;
  [self setNeedsLayout];
}
@end

#pragma mark - Avatar
@implementation LBAvatarView {
  CAGradientLayer *_g;
  UILabel *_l;
}
- (instancetype)initWithFrame:(CGRect)f {
  if ((self = [super initWithFrame:f])) {
    _g = [CAGradientLayer layer];
    _g.startPoint = CGPointMake(0, 0);
    _g.endPoint = CGPointMake(1, 1);
    [self.layer addSublayer:_g];
    _l = [UILabel new];
    _l.font = [LBTheme mono:13 weight:UIFontWeightBold];
    _l.textColor = UIColor.whiteColor;
    _l.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_l];
    self.clipsToBounds = YES;
  }
  return self;
}
- (void)setSession:(NSString *)sid {
  // Cell reuse changes identity, not a user-requested color transition.
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _g.colors = [LBTheme gradientForSession:sid];
  [CATransaction commit];
  _l.text = [[sid substringToIndex:MIN(2, sid.length)] uppercaseString];
}
- (void)layoutSubviews {
  [super layoutSubviews];
  _g.frame = self.bounds;
  _l.frame = self.bounds;
  self.layer.cornerRadius = self.bounds.size.width / 2;
}
@end

NSString *LBRelativeTime(long long ms) {
  NSTimeInterval d = [NSDate date].timeIntervalSince1970 - ms / 1000.0;
  if (d < 60) return @"刚刚";
  if (d < 3600) return [NSString stringWithFormat:@"%d 分钟前", (int)(d / 60)];
  NSDate *date = [NSDate dateWithTimeIntervalSince1970:ms / 1000.0];
  // Creating a formatter per call was measurable while scrolling the memo list.
  static NSDateFormatter *today, *other;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    today = [NSDateFormatter new]; today.dateFormat = @"HH:mm";
    other = [NSDateFormatter new]; other.dateFormat = @"M月d日 HH:mm";
    for (NSDateFormatter *f in @[ today, other ]) {
      f.locale = NSLocale.autoupdatingCurrentLocale;
      f.timeZone = NSTimeZone.localTimeZone; // auto-updating
    }
  });
  return [([[NSCalendar currentCalendar] isDateInToday:date] ? today : other) stringFromDate:date];
}

NSString *LBRemaining(long long expiresAtMs) {
  NSTimeInterval d = expiresAtMs / 1000.0 - [NSDate date].timeIntervalSince1970;
  if (d <= 0) return @"已过期";
  if (d < 3600) return [NSString stringWithFormat:@"剩 %d 分钟", (int)(d / 60) + 1];
  return [NSString stringWithFormat:@"剩 %d 小时", (int)(d / 3600)];
}

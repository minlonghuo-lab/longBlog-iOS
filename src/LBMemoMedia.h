#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
// Call on the main thread ONLY in response to an explicit Play tap, then present.
// Returns a self-contained AVKit controller (including a native failure view).
// Cached originals are borrowed from LBMemosCache, never deleted by this helper.
BOOL LBMemoIsPlayable(NSDictionary *resource);
UIViewController *LBMemoMediaPlayer(NSDictionary *resource);
// Reusable inline child. Parent must addChild/view/didMove and retain until reset.
// Construction never starts a network asset; playback begins only after a tap.
@interface LBMemoInlineMediaController : UIViewController
- (instancetype)initWithResource:(NSDictionary *)resource;
@property (nonatomic, copy, nullable) void (^willPlay)(LBMemoInlineMediaController *controller);
@property (nonatomic, readonly, getter=isPresentingFullscreen) BOOL presentingFullscreen;
- (void)setPageVisible:(BOOL)visible;
- (void)pausePlayback;
- (void)invalidateMedia;
@end
NS_ASSUME_NONNULL_END

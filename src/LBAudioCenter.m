#import "LBAudioCenter.h"
#import "LB.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <math.h>

// All ownership and system-session state is main-queue confined. The player is
// weak: remote controls/notification blocks must never keep a closed item alive.
static __weak AVPlayer *LBAudioPlayer;
static BOOL LBAudioSessionActive, LBAudioInterrupted;
static id LBAudioPlayTarget, LBAudioPauseTarget, LBAudioToggleTarget;
static NSArray *LBAudioObservers;

static void LBReleaseAudioSession(void) {
  if (!LBAudioSessionActive) return;
  LBAudioSessionActive = NO;
  [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
}
static BOOL LBAcquireAudioSession(void) {
  if (LBAudioInterrupted) return NO;
  if (LBAudioSessionActive) return YES;
  AVAudioSession *session = AVAudioSession.sharedInstance;
  // Ordinary foreground playback, not perpetual ducking/mixing of other apps.
  if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:NULL] ||
      ![session setActive:YES error:NULL]) return NO;
  LBAudioSessionActive = YES; return YES;
}

@interface LBAudioCenter ()
+ (void)deactivatePlaybackForPlayer:(AVPlayer *)player;
+ (MPRemoteCommandHandlerStatus)remoteAction:(NSInteger)action player:(AVPlayer *)player;
@end

@implementation LBAudioCenter

static MPMediaItemArtwork *sharedArtwork(void) {
  static MPMediaItemArtwork *artwork;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(180, 180), YES, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[] = { 0.60, 0.35, 0.24, 1.0, 0.84, 0.63, 0.51, 1.0 };
    CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, NULL, 2);
    CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, 0), CGPointMake(180, 180), 0);
    CGGradientRelease(grad);
    CGColorSpaceRelease(cs);
    UIImage *symbol = [UIImage systemImageNamed:@"waveform" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:64 weight:UIImageSymbolWeightBold]];
    if (symbol) {
      [[UIColor whiteColor] setFill];
      CGRect rect = CGRectMake(45, 45, 90, 90);
      [symbol drawInRect:rect];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:CGSizeMake(180, 180) requestHandler:^UIImage * _Nonnull(CGSize size) {
      return img;
    }];
  });
  return artwork;
}

+ (void)activatePlaybackWithTitle:(NSString *)title duration:(NSTimeInterval)duration player:(AVPlayer *)player {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self activatePlaybackWithTitle:title duration:duration player:player]; }); return;
  }
  if (!player) return;
  if (LBAudioPlayer != player) {
    [LBAudioPlayer pause]; [self deactivatePlayback];
    LBAudioPlayer = player;
    [UIApplication.sharedApplication beginReceivingRemoteControlEvents];
    MPRemoteCommandCenter *commands = MPRemoteCommandCenter.sharedCommandCenter;
    __weak AVPlayer *weakPlayer = player;
    LBAudioPlayTarget = [commands.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
      return [self remoteAction:0 player:weakPlayer];
    }];
    LBAudioPauseTarget = [commands.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
      return [self remoteAction:1 player:weakPlayer];
    }];
    LBAudioToggleTarget = [commands.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
      return [self remoteAction:2 player:weakPlayer];
    }];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    id interruption = [nc addObserverForName:AVAudioSessionInterruptionNotification object:AVAudioSession.sharedInstance queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
      AVPlayer *p = weakPlayer; if (!p || p != LBAudioPlayer) return;
      BOOL began = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan;
      LBAudioInterrupted = began;
      if (began) { [p pause]; LBReleaseAudioSession(); }
      // Never auto-resume after interruption; a fresh Play tap/command is needed.
      [self updatePlaybackProgressWithPlayer:p duration:CMTimeGetSeconds(p.currentItem.duration)];
    }];
    id route = [nc addObserverForName:AVAudioSessionRouteChangeNotification object:AVAudioSession.sharedInstance queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
      AVPlayer *p = weakPlayer; if (!p || p != LBAudioPlayer) return;
      if ([note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue] == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        [p pause]; LBReleaseAudioSession(); // headphones unplugged: no loudspeaker surprise
        [self updatePlaybackProgressWithPlayer:p duration:CMTimeGetSeconds(p.currentItem.duration)];
      }
    }];
    id ended = [nc addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:player.currentItem queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
      AVPlayer *p = weakPlayer; if (!p || p != LBAudioPlayer) return;
      [p pause]; LBReleaseAudioSession();
      [self updatePlaybackProgressWithPlayer:p duration:CMTimeGetSeconds(p.currentItem.duration)];
    }];
    LBAudioObservers = @[interruption, route, ended];
  }
  if (!LBAcquireAudioSession()) [player pause];
  [self updateNowPlayingWithTitle:title duration:duration player:player];
}

+ (MPRemoteCommandHandlerStatus)remoteAction:(NSInteger)action player:(AVPlayer *)player {
  // MPRemoteCommand callbacks are not guaranteed to run on the main queue.
  if (!NSThread.isMainThread) {
    __block MPRemoteCommandHandlerStatus status;
    dispatch_sync(dispatch_get_main_queue(), ^{ status = [self remoteAction:action player:player]; });
    return status;
  }
  if (!player || player != LBAudioPlayer || !player.currentItem) return MPRemoteCommandHandlerStatusCommandFailed;
  BOOL pause = action == 1 || (action == 2 && player.rate > 0);
  if (pause) { [player pause]; LBReleaseAudioSession(); }
  else {
    if (!LBAcquireAudioSession()) return MPRemoteCommandHandlerStatusCommandFailed;
    [player play];
  }
  [self updatePlaybackProgressWithPlayer:player duration:CMTimeGetSeconds(player.currentItem.duration)];
  return MPRemoteCommandHandlerStatusSuccess;
}

+ (void)updateNowPlayingWithTitle:(NSString *)title duration:(NSTimeInterval)duration player:(AVPlayer *)player {
  if (!player) return;
  double now = CMTimeGetSeconds(player.currentTime);
  if (!isfinite(now) || now < 0) now = 0;
  if (!isfinite(duration) || duration <= 0) duration = 0;

  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  info[MPMediaItemPropertyTitle] = title.length ? title : @"说说音频";
  info[MPMediaItemPropertyArtist] = @"longBlog";
  info[MPMediaItemPropertyArtwork] = sharedArtwork();
  info[MPMediaItemPropertyPlaybackDuration] = @(duration);
  info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(now);
  info[MPNowPlayingInfoPropertyPlaybackRate] = @(player.rate);
  info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @(1.0);

  [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

+ (void)updatePlaybackProgressWithPlayer:(AVPlayer *)player duration:(NSTimeInterval)duration {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updatePlaybackProgressWithPlayer:player duration:duration]; }); return;
  }
  if (!player || player != LBAudioPlayer) return;
  if (player.rate == 0) LBReleaseAudioSession();
  NSDictionary *current = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
  NSString *title = current[MPMediaItemPropertyTitle] ?: @"说说音频";
  [self updateNowPlayingWithTitle:title duration:duration player:player];
}

+ (void)deactivatePlaybackForPlayer:(AVPlayer *)player {
  if (!NSThread.isMainThread) {
    dispatch_async(dispatch_get_main_queue(), ^{ [self deactivatePlaybackForPlayer:player]; }); return;
  }
  if (player && player == LBAudioPlayer) [self deactivatePlayback];
}

+ (void)deactivatePlayback {
  if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self deactivatePlayback]; }); return; }
  LBAudioPlayer = nil; LBAudioInterrupted = NO;
  for (id observer in LBAudioObservers) [NSNotificationCenter.defaultCenter removeObserver:observer];
  LBAudioObservers = nil;
  [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
  MPRemoteCommandCenter *commands = MPRemoteCommandCenter.sharedCommandCenter;
  if (LBAudioPlayTarget) [commands.playCommand removeTarget:LBAudioPlayTarget];
  if (LBAudioPauseTarget) [commands.pauseCommand removeTarget:LBAudioPauseTarget];
  if (LBAudioToggleTarget) [commands.togglePlayPauseCommand removeTarget:LBAudioToggleTarget];
  LBAudioPlayTarget = nil; LBAudioPauseTarget = nil; LBAudioToggleTarget = nil;
  [UIApplication.sharedApplication endReceivingRemoteControlEvents];
  LBReleaseAudioSession();
}

@end

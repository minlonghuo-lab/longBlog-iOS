#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LBAudioCenter : NSObject

+ (void)activatePlaybackWithTitle:(NSString *)title
                         duration:(NSTimeInterval)duration
                           player:(AVPlayer *)player;

+ (void)updatePlaybackProgressWithPlayer:(AVPlayer *)player
                                duration:(NSTimeInterval)duration;

+ (void)deactivatePlayback;

@end

NS_ASSUME_NONNULL_END

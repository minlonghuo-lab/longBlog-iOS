// Compile-only REAL API calls; not a UIKit runtime or playback test.
#import "LBMemoMedia.h"
#import "LBMemoContentView.h"
void LBInlineMediaAPIFixture(UIViewController *parent, UIView *host, NSDictionary *resource) {
  LBMemoInlineMediaController *child = [[LBMemoInlineMediaController alloc] initWithResource:resource];
  [parent addChildViewController:child]; [host addSubview:child.view];
  [child didMoveToParentViewController:parent];
  child.willPlay = ^(LBMemoInlineMediaController *playing) { [playing pausePlayback]; };
  [child setPageVisible:YES];
  BOOL fullscreen = child.isPresentingFullscreen; (void)fullscreen;
  [child setPageVisible:NO]; [child invalidateMedia];
  [child willMoveToParentViewController:nil]; [child.view removeFromSuperview]; [child removeFromParentViewController];
  LBMemoContentView *content = [[LBMemoContentView alloc] initWithPreview:^(NSURL *file) { (void)file; }];
  content.installMedia = ^(UIView *view, NSDictionary *metadata) { (void)view; (void)metadata; };
  content.resetMedia = ^{};
  UIViewController *legacy = LBMemoMediaPlayer(resource); (void)legacy;
}

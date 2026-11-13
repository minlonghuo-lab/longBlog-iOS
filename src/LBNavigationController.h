#import <UIKit/UIKit.h>

@interface LBNavigationController : UINavigationController
// Called after public content-scroll registration and navigation completion.
// Does not replace the navigation or scroll delegates.
- (void)reconcileChrome;
@end

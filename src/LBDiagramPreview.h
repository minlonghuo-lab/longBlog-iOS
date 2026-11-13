#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// Only accepts an inert SVG data-image produced by LBMermaid.imageSVG.
// No source URL, account credentials, scripts or native bridge enter this viewer.
@interface LBDiagramPreviewController : UIViewController
+ (nullable instancetype)previewWithDataURL:(NSString *)dataURL memoGeneration:(nullable NSNumber *)generation;
- (void)close;
@end
NS_ASSUME_NONNULL_END

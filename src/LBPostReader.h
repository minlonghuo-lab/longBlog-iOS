#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Local, isolated-world article renderer. Does not receive API/GitHub credentials.
@interface LBPostReaderViewController : UIViewController
- (instancetype)initWithPost:(NSDictionary *)post;
@property (nonatomic, readonly) BOOL memoPreview;
@end

@interface LBReaderImageController : UIViewController
- (instancetype)initWithURL:(NSURL *)url;
- (instancetype)initWithLocalFile:(NSURL *)file;
@end
NS_ASSUME_NONNULL_END

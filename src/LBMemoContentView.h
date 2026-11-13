#import "LBMemos.h"
NS_ASSUME_NONNULL_BEGIN
// Owns only local, nonpersistent rendering state; credentials never enter WebKit.
@interface LBMemoContentView : UIView
- (instancetype)initWithPreview:(void (^)(NSURL *file))preview;
@property (nonatomic, copy, nullable) void (^playMedia)(NSDictionary *resource); // Legacy fallback only.
@property (nonatomic, copy, nullable) void (^installMedia)(UIView *host, NSDictionary *resource);
@property (nonatomic, copy, nullable) void (^resetMedia)(void);
@property (nonatomic, copy, nullable) void (^openDiagram)(NSString *dataURL, NSUInteger generation);
@property (nonatomic, copy, nullable) void (^resetDiagram)(void);
- (void)displayMemo:(NSDictionary *)memo generation:(NSUInteger)generation;
- (void)setPageVisible:(BOOL)visible;
- (void)invalidateContent;
@end
NS_ASSUME_NONNULL_END

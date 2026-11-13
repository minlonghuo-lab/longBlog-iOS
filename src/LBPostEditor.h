#import "LB.h"

NS_ASSUME_NONNULL_BEGIN

/// UI-only completion feedback; userInfo["message"] contains no article body.
/// Storage change notifications remain the only article invalidation signal.
extern NSNotificationName const LBPostEditorDidFinish;

@interface LBPostEditor : UIViewController

- (instancetype)initWithPost:(nullable NSDictionary *)post
                       saved:(nullable void (^)(NSDictionary *post))saved;

@end

/// Recovery snapshots live under Application Support/Drafts and never use the network.
/// Saved articles (including drafts) live in LBMdStore; editing does not change
/// publication state. Publishing and unpublishing are explicit store operations.
/// The list returns light metadata items; the reader loads the canonical Markdown
/// body (including bodyFormat=html) and resolves local attachments read-only.
NSArray<NSDictionary *> *LBListLocalDrafts(void);
NSDictionary * _Nullable LBLoadLocalDraftPost(NSString *draftPath);
NSString *LBDraftsDirectory(void);

NS_ASSUME_NONNULL_END

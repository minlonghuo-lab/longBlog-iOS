#import "LB.h"

NS_ASSUME_NONNULL_BEGIN

/// OpenAI-compatible chat completions client (OpenAI, DeepSeek, self-hosted
/// proxies…). Base URL and model are preferences; the API key lives only in
/// the device Keychain. Callbacks always arrive on the main queue; deltas may
/// be coalesced. Keychain reads and request encoding for streams run off-main.
@interface LBAI : NSObject
+ (instancetype)shared;
@property (nonatomic, copy) NSString *baseURL;          // e.g. https://api.openai.com/v1
@property (nonatomic, copy) NSString *model;            // e.g. gpt-4o-mini
@property (nonatomic, copy, nullable) NSString *apiKey; // Keychain "ai-api-key"
/// Synchronous Keychain access; do not call while building an interactive menu.
- (BOOL)configured;
/// Asynchronous Keychain-backed check. Completion is always on the main queue.
- (void)checkConfigured:(void (^)(BOOL ready))completion;
/// Full endpoint, or nil when baseURL is not an HTTPS URL.
+ (nullable NSURL *)endpointForBase:(NSString *)base;
/// Streams the reply; preparation is asynchronous. Returns a thread-safe cancel
/// block. Cancelling suppresses queued deltas AND done, even validation errors.
- (void (^)(void))streamSystem:(NSString *)system prompt:(NSString *)prompt maxTokens:(NSInteger)maxTokens
                       onDelta:(void (^)(NSString *text))onDelta
                          done:(void (^)(NSString *_Nullable full, NSError *_Nullable error))done;
@end

/// Sheet that streams one AI result and lets the author apply, copy or retry it.
@interface LBAIResultViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)title applyTitle:(NSString *)applyTitle
                       system:(NSString *)system prompt:(NSString *)prompt
                        apply:(void (^)(NSString *text))apply;
@end

NS_ASSUME_NONNULL_END

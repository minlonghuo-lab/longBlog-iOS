// Compile-only fixture for ACTUAL cache helper code. Synthetic data only.
// Linux cannot execute this arm64 Mach-O; do not claim an iOS runtime test.
// Compile independently, never link alongside LBMemosDiskCache.o.
#import "../src/LBMemosDiskCache.m"

void LBMemosCacheBoundaryFixtures(void);
void LBMemosCacheBoundaryFixtures(void) {
  NSDictionary *r = @{@"id":@8, @"creatorId":@7, @"size":@5, @"createdTs":@1, @"updatedTs":@2, @"filename":@"fixture.jpg", @"type":@"image/jpeg"};
  NSString *key = [LBMemosDiskCache fingerprint:r];
  NSCAssert(key.length == 64, @"hashed fingerprint");
  NSCAssert([[LBMemosDiskCache fingerprint:[r copy]] isEqual:key], @"unchanged reuse");
  for (NSString *field in @[@"id", @"creatorId", @"size", @"updatedTs", @"filename", @"type"]) {
    NSMutableDictionary *other = [r mutableCopy];
    other[field] = [r[field] isKindOfClass:NSString.class] ? [r[field] stringByAppendingString:@"x"] : @([r[field] unsignedLongLongValue] + 1);
    NSCAssert(![[LBMemosDiskCache fingerprint:other] isEqual:key], @"version changes key");
    other[field] = NSNull.null; NSCAssert([LBMemosDiskCache fingerprint:other] == nil, @"null rejected");
  }
  NSMutableDictionary *bad = [r mutableCopy]; bad[@"id"] = @YES;
  NSCAssert([LBMemosDiskCache fingerprint:bad] == nil, @"boolean id rejected");
  bad[@"id"] = @1.5; NSCAssert([LBMemosDiskCache fingerprint:bad] == nil, @"fraction rejected");
  bad[@"id"] = @9007199254740992.0; NSCAssert([LBMemosDiskCache fingerprint:bad] == nil, @"unsafe integer rejected");
  NSDictionary *memo = @{@"id":@9, @"creatorId":@7, @"rowStatus":@"NORMAL", @"visibility":@"PRIVATE", @"content":@"synthetic", @"pinned":@NO, @"createdTs":@1, @"updatedTs":@2, @"displayTs":@1, @"resourceList":@[r]};
  NSCAssert(LBCRows(@[memo], @7, @"NORMAL"), @"valid snapshot");
  NSCAssert(!LBCRows(@[memo], @8, @"NORMAL"), @"wrong account rejected");
  NSCAssert(!LBCRows(@[memo], @7, @"ARCHIVED"), @"wrong state rejected");
  NSCAssert(!LBCRows(@[memo, memo], @7, @"NORMAL"), @"duplicate row rejected");
  LBMemosDiskCache *a = [[LBMemosDiskCache alloc] initWithBase:@"https://a.invalid" userID:@7];
  LBMemosDiskCache *b = [[LBMemosDiskCache alloc] initWithBase:@"https://a.invalid" userID:@8];
  NSCAssert(![a.root isEqual:b.root], @"accounts isolated");
  LBMemosDiskCache *replacement = [[LBMemosDiskCache alloc] initWithBase:@"https://a.invalid" userID:@7];
  NSCAssert(a.io == replacement.io, @"same namespace instances share serial IO");
  NSCAssert(a.io != b.io, @"other account uses independent IO");
  NSCAssert([a lifecycleError] == nil, @"new cache is active");
  if (NSThread.isMainThread) {
    [a invalidate];
    NSCAssert([a lifecycleError] != nil && a.invalidated, @"retired instance rejects operations");
    NSCAssert([replacement lifecycleError] == nil, @"retirement does not retire replacement");
    NSCAssert([a resourceURL:r] == nil, @"retired instance cannot return originals");
  }
  NSCAssert([a.root.lastPathComponent length] == 64, @"account hash filename");
  NSURL *ta = [LBMemosDiskCache bindingURLForBase:@"https://a.invalid" token:@"synthetic-A"];
  NSURL *tb = [LBMemosDiskCache bindingURLForBase:@"https://a.invalid" token:@"synthetic-B"];
  NSCAssert(![ta isEqual:tb], @"exact credential binding");
  NSCAssert(![ta.path containsString:@"synthetic-A"], @"no plaintext token");
  NSCAssert([[a URLForResource:r].pathExtension isEqual:@"jpg"], @"safe native file type extension");
  bad = [r mutableCopy]; bad[@"filename"] = @"fixture.../../../path";
  NSCAssert([[a URLForResource:bad].lastPathComponent hasPrefix:[LBMemosDiskCache fingerprint:bad]], @"no path injection");
}

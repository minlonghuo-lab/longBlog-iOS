// Compile-only fixture coverage of the ACTUAL ObjC boundary functions.
// No claim of execution on iOS: this Linux environment cannot run Mach-O.
// Compile separately; do NOT link this TU together with LBMemosClient.o.
#import "../../src/LBMemosClient.m"

void LBMemosClientBoundaryFixtures(void);
void LBMemosClientBoundaryFixtures(void) {
  NSDictionary *resource = @{@"id":@8, @"creatorId":@7, @"filename":@"a.jpg", @"type":@"image/jpeg", @"size":@5, @"createdTs":@1, @"updatedTs":@2, @"externalLink":@"https://evil.invalid/leak"};
  NSDictionary *memo = @{@"id":@9, @"creatorId":@7, @"content":@"synthetic PRIVATE fixture", @"visibility":@"PRIVATE", @"rowStatus":@"NORMAL", @"createdTs":@1, @"updatedTs":@2, @"displayTs":@1, @"pinned":@NO, @"resourceList":@[resource]};
  NSCAssert(LBMemo(memo) != nil, @"valid legacy memo");
  NSCAssert(LBMemo(NSNull.null) == nil, @"reject null memo");
  NSCAssert(LBMemo(@[]) == nil, @"reject array memo");
  for (NSString *key in @[@"id", @"creatorId", @"content", @"visibility", @"rowStatus", @"createdTs", @"updatedTs", @"displayTs", @"pinned", @"resourceList"]) {
    NSMutableDictionary *bad = [memo mutableCopy]; bad[key] = NSNull.null;
    NSCAssert(LBMemo(bad) == nil, @"reject null mandatory field");
    [bad removeObjectForKey:key]; NSCAssert(LBMemo(bad) == nil, @"reject missing mandatory field");
  }
  NSCAssert(!LBNumber(@YES, YES), @"bool is not ID");
  NSCAssert(!LBNumber(@0, YES), @"positive IDs");
  NSCAssert(!LBNumber(@1.5, YES), @"integer IDs");
  NSCAssert(!LBNumber(@9007199254740992.0, YES), @"JS safe integer");
  NSCAssert(LBNumber(@9007199254740991LL, YES), @"max safe integer");
  NSCAssert(([LBIDs(@[@1,@2,@1]) isEqual:@[@1,@2]]), @"dedup replacement IDs");
  NSCAssert([LBSafeName(@"中文 照片.jpg") isEqual:@"中文 照片.jpg"], @"preserve Unicode display/upload filename");
  NSCAssert(LBIDs(@[@YES]) == nil, @"reject boolean resource IDs");
  NSCAssert([LBIDs(@[]) isEqual:@[]], @"empty full replacement supported");
  NSCAssert(LBEqualOriginal(LBMemo(memo), LBMemo(memo)), @"same original");
  for (NSString *key in @[@"content", @"visibility", @"rowStatus", @"pinned", @"updatedTs", @"resourceList"]) {
    NSMutableDictionary *changed = [memo mutableCopy];
    if ([key isEqual:@"content"]) changed[key] = @"new text";
    else if ([key isEqual:@"visibility"]) changed[key] = @"PUBLIC";
    else if ([key isEqual:@"rowStatus"]) changed[key] = @"ARCHIVED";
    else if ([key isEqual:@"pinned"]) changed[key] = @YES;
    else if ([key isEqual:@"updatedTs"]) changed[key] = @3;
    else changed[key] = @[];
    NSCAssert(!LBEqualOriginal(LBMemo(memo), LBMemo(changed)), @"conflict field must differ");
  }
  NSCAssert(LBResource(resource)[@"externalLink"] == nil, @"never propagate external URL");
  NSCAssert([LBSafeType(@"text/html\r\nAuthorization: secret") isEqual:@"application/octet-stream"], @"no MIME header injection");
  NSCAssert(![LBSafeName(@"../../x\r\n.jpg") containsString:@".."], @"no traversal");
  NSCAssert([LBBase(@"https://EXAMPLE.com:443/") isEqual:@"https://example.com"], @"canonical origin");
  for (NSString *base in @[@"http://example.com", @"https://u:p@example.com", @"https://example.com/path", @"https://example.com?token=x", @"https://example.com#x", @"https://example.com:0", @"https://example.com:65536", @"https://@example.com"]) NSCAssert(LBBase(base) == nil, @"root HTTPS origin only");
}

// Compile-only ObjC fixtures: invokes the REAL private parsing/window helpers.
// No UIKit execution is claimed; Python source/spec tests run on Linux.
#import "../src/LBMemoMedia.m"
#include <assert.h>
#include <limits.h>
void LBMemoMediaBoundaryFixtures(void) {
  @autoreleasepool {
    int64_t n = -1, begin = -1, end = -1;
    assert(LBMMDecimal(@"33554432", &n) && n == LBMMCap);
    for (NSString *bad in @[@"", @"-1", @"+1", @"1 ", @"1x", @"33554433", @"9999999999999999"]) assert(!LBMMDecimal(bad, &n));
    assert(LBMMContentRange(@"bytes 10-19/100", 10, 10, 100));
    for (NSString *bad in @[@"bytes 9-19/100", @"bytes 10-20/100", @"bytes 10-19/101", @"bytes 10-19/*", @"bytes 10-19/100 extra", @"bytes 10-19/100/100"]) assert(!LBMMContentRange(bad, 10, 10, 100));
    assert(!LBMMContentRange(@"bytes 0-0/1", LLONG_MAX, LLONG_MAX, 1));
    assert(LBMMWindow(10, 12, NSIntegerMax, NO, 100, &begin, &end) && begin == 12 && end == 100);
    assert(LBMMWindow(10, 12, 1, YES, 100, &begin, &end) && end == 100);
    assert(LBMMWindow(100, 100, 0, NO, 100, &begin, &end) && end == 100);
    assert(!LBMMWindow(10, 9, 1, NO, 100, &begin, &end));
    assert(!LBMMWindow(10, 12, 1, NO, 100, &begin, &end));
    assert(!LBMMWindow(LLONG_MAX, LLONG_MAX, NSIntegerMax, YES, 100, &begin, &end));
    assert(!LBMMInteger(@YES, YES) && !LBMMInteger(@1.25, YES));
    assert(!LBMMInteger(@9007199254740992ULL, YES));
    assert(LBMMFileURL(@"https://example.invalid:443/", @8));
    for (NSString *bad in @[@"http://example.invalid", @"https://u@example.invalid", @"https://example.invalid?", @"https://example.invalid/#x", @"https://example.invalid/path", @"https://example.invalid:65536"]) assert(!LBMMFileURL(bad, @8));
    NSDictionary *resource = @{@"id":@8, @"creatorId":@7, @"size":@100, @"type":@"audio/mpeg"};
    assert(LBMemoIsPlayable(resource));
    NSMutableDictionary *changed = [resource mutableCopy]; changed[@"size"] = @(LBMMCap + 1); assert(!LBMemoIsPlayable(changed));
    changed = [resource mutableCopy]; changed[@"type"] = @"application/pdf"; assert(!LBMemoIsPlayable(changed));
  }
}

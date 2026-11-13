// iOS Foundation fixture. This includes the actual production implementation;
// it is NOT a Python/C model of NSURL or the archive algorithm. Compile strictly
// on the SDK; invoke LBRunMDArchiveURLFixtures() from an iOS test runner to execute.
// No real workspace is accessed. Only synthetic temporary article data is used.
#import "../src/LBMdStore.m"
#include <assert.h>

int LBRunMDArchiveURLFixtures(void) {
  @autoreleasepool {
    NSString *embedded = @"\n\r\n<details open><summary>fixture</summary><table><tr><td rowspan=\"2\">A</td></tr></table></details>";
    NSDictionary *formatMeta = @{@"id":@"EmbeddedID", @"title":@"Fixture", @"bodyFormat":@"html", @"singleSourceVersion":@1};
    NSString *serialized = [LBMdStore serializeFrontmatter:formatMeta body:embedded];
    NSDictionary *parsed = [LBMdStore parseFrontmatterAndBody:serialized];
    assert([parsed[@"bodyFormat"] isEqual:@"html"]);
    assert([parsed[@"markdown"] isEqual:embedded]);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSError *error = nil;
    assert([fm createDirectoryAtURL:temporary withIntermediateDirectories:YES attributes:nil error:&error]);
    NSString *path = temporary.path.stringByStandardizingPath;
    NSArray<NSURL *> *roots = @[
      [NSURL fileURLWithPath:path],
      [NSURL fileURLWithPath:path isDirectory:YES],
      [NSURL fileURLWithPath:[path stringByAppendingString:@"/"] isDirectory:YES],
      [NSURL URLWithString:[[NSURL fileURLWithPath:path isDirectory:YES].absoluteString stringByAppendingString:@"/"]]
    ];
    NSData *md = [@"---\nid: \"FixtureID\"\ntitle: \"Fixture\"\npublish: false\n---\n\nfixture only\n" dataUsingEncoding:NSUTF8StringEncoding];
    assert([md writeToURL:[temporary URLByAppendingPathComponent:@"FixtureID.md"] options:NSDataWritingAtomic error:&error]);
    for (NSURL *root in roots) {
      NSURL *child = MDRawURL(root, @"FixtureID.md");
      assert(child != nil);
      assert([[NSData dataWithContentsOfURL:child] isEqual:md]);
      assert(MDRawURL(root, @"../outside") == nil);
      assert(MDRawURL(root, @"/outside") == nil);
      // Exact Apple NSURL.path behavior remains observable in the runner without
      // assuming the SDK strips a bookmark's trailing slash.
      NSString *canonical = root.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
      assert([canonical isEqual:path]);
    }
    NSDictionary *meta = @{@"title":@"Fixture", @"publish":@NO};
    // Use an isDirectory:YES URL as returned by UIDocumentPicker/bookmark.
    assert(MDArchiveMany(roots[1], @{@"FixtureID":meta}, &error));
    assert(MDArchiveMany(roots[2], @{@"FixtureID":meta}, &error));
    assert([MDRead(roots[3], @"FixtureID.md") isEqual:md]);
    // Simulate a completed directory install whose manifest switch was lost.
    NSURL *manifest = [temporary URLByAppendingPathComponent:MDLayoutName()];
    assert([fm removeItemAtURL:manifest error:&error]);
    assert([md writeToURL:[temporary URLByAppendingPathComponent:@"FixtureID.md"] options:NSDataWritingAtomic error:&error]);
    assert(MDArchiveMany(roots[1], @{@"FixtureID":meta}, &error));
    // Existing unequal target is a real filesystem conflict, never overwritten.
    NSData *edited = [@"external edit" dataUsingEncoding:NSUTF8StringEncoding];
    assert([fm removeItemAtURL:manifest error:&error]);
    assert([edited writeToURL:[temporary URLByAppendingPathComponent:@"FixtureID.md"] options:NSDataWritingAtomic error:&error]);
    assert(!MDArchiveMany(roots[1], @{@"FixtureID":meta}, &error));
    assert([MDRead(roots[1], @"FixtureID.md") isEqual:edited]);
    // Parent symlink rejected, even if its target is inside the workspace.
    assert([fm createSymbolicLinkAtPath:[path stringByAppendingPathComponent:@"link"] withDestinationPath:path error:&error]);
    assert(MDRawURL(roots[1], @"link/FixtureID.md") == nil);
    assert([fm removeItemAtURL:temporary error:&error]);
  }
  return 0;
}

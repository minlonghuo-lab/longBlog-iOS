// iOS Foundation fixture: calls the actual production parser, not a model.
// Strictly compile against the iOS SDK; execution requires an iOS test runner
// invoking LBRunLaunchMetadataFixtures(). Do not compile LBMdStore.m separately
// in the same runner: its implementation is included here, as in existing fixtures.
// No file, bookmark, keychain, network, or LBMdStore.shared access is performed.
#import "../src/LBMdStore.m"
#include <assert.h>

static NSDictionary *LBLaunchMetadataParse(NSString *fields) {
  NSString *body = @"# Fixture\n正文 **unchanged**\n---\npublish: true\n";
  NSString *markdown = [NSString stringWithFormat:@"---\n%@\n---\n\n%@", fields, body];
  NSDictionary *parsed = [LBMdStore parseFrontmatterAndBody:markdown];
  assert([parsed[@"markdown"] isEqual:body]);
  return parsed;
}

int LBRunLaunchMetadataFixtures(void) {
  @autoreleasepool {
    // The reported startup-crash shapes must not reach numeric selectors.
    NSDictionary *invalid = LBLaunchMetadataParse(@"publish: [true]\npinned: []\nsingleSourceVersion: [1]");
    assert([invalid[@"publish"] isKindOfClass:NSNumber.class]);
    assert([invalid[@"pinned"] isKindOfClass:NSNumber.class]);
    assert([invalid[@"singleSourceVersion"] isKindOfClass:NSNumber.class]);
    assert(![invalid[@"publish"] boolValue]);
    assert(![invalid[@"pinned"] boolValue]);
    assert([invalid[@"singleSourceVersion"] integerValue] == 0);
    assert([invalid[@"singleSourceVersion"] intValue] == 0);

    // No array shape is interpreted as truthy or as a supported source version.
    for (NSString *literal in @[@"[true]", @"[]", @"[1]", @"[false]", @"[0, 1]", @"['true']", @"[\"1\"]"]) {
      NSString *fields = [NSString stringWithFormat:@"publish: %@\npinned: %@\nsingleSourceVersion: %@", literal, literal, literal];
      NSDictionary *parsed = LBLaunchMetadataParse(fields);
      assert(![parsed[@"publish"] boolValue]);
      assert(![parsed[@"pinned"] boolValue]);
      assert([parsed[@"singleSourceVersion"] integerValue] == 0);
      assert([parsed[@"singleSourceVersion"] intValue] == 0);
    }

    // Keep the parser's pre-existing scalar representation AND Foundation
    // conversion semantics; quoted strings are intentionally not reinterpreted.
    NSArray *scalars = @[
      @[@"true", @YES], @[@"false", @NO],
      @[@"\"true\"", @"true"], @[@"\"false\"", @"false"],
      @[@"1", @"1"], @[@"0", @"0"], @[@"2", @"2"], @[@"-1", @"-1"],
      @[@"\"1\"", @"1"], @[@"\"0\"", @"0"], @[@"\"YES\"", @"YES"],
      @[@"\"not-a-number\"", @"not-a-number"]
    ];
    for (NSArray *test in scalars) {
      NSString *literal = test[0]; id expected = test[1];
      NSString *fields = [NSString stringWithFormat:@"publish: %@\npinned: %@\nsingleSourceVersion: %@", literal, literal, literal];
      NSDictionary *parsed = LBLaunchMetadataParse(fields);
      for (NSString *key in @[@"publish", @"pinned", @"singleSourceVersion"]) {
        assert([parsed[key] isEqual:expected]);
        assert([parsed[key] isKindOfClass:[expected isKindOfClass:NSString.class] ? NSString.class : NSNumber.class]);
      }
      assert([parsed[@"publish"] boolValue] == [expected boolValue]);
      assert([parsed[@"pinned"] boolValue] == [expected boolValue]);
      assert([parsed[@"singleSourceVersion"] integerValue] == [expected integerValue]);
    }

    NSDictionary *missing = LBLaunchMetadataParse(@"title: Fixture");
    for (NSString *key in @[@"publish", @"pinned", @"singleSourceVersion"]) assert(missing[key] == nil);
    assert(![missing[@"publish"] boolValue] && ![missing[@"pinned"] boolValue]);
    assert([missing[@"singleSourceVersion"] integerValue] == 0);

    // The new guard does not flatten ordinary arrays or affect text coercion.
    NSDictionary *mixed = LBLaunchMetadataParse(@"publish: true\npinned: []\nsingleSourceVersion: 1\ntags: [one, two]\ntitle: [a, b]");
    assert([mixed[@"publish"] boolValue]);
    assert(![mixed[@"pinned"] boolValue]);
    assert([mixed[@"singleSourceVersion"] integerValue] == 1);
    assert(([mixed[@"tags"] isEqual:@[@"one", @"two"]]));
    assert([mixed[@"title"] isEqual:@"a, b"]);

    // Embedded HTML retains exact body bytes, including leading blanks/CRLF.
    NSString *html = @"\r\n\r\n<details>正文</details>\r\n";
    NSString *source = [@"---\r\nbodyFormat: \"html\"\r\npublish: [true]\r\npinned: []\r\nsingleSourceVersion: [1]\r\n---\r\n" stringByAppendingString:html];
    NSDictionary *htmlParsed = [LBMdStore parseFrontmatterAndBody:source];
    assert([htmlParsed[@"markdown"] isEqual:html]);
    assert(![htmlParsed[@"publish"] boolValue] && ![htmlParsed[@"pinned"] boolValue]);
    assert([htmlParsed[@"singleSourceVersion"] integerValue] == 0);

    NSString *plain = @"\n# No frontmatter\r\n正文\n";
    assert([[LBMdStore parseFrontmatterAndBody:plain][@"markdown"] isEqual:plain]);
  }
  return 0;
}

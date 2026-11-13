// Compile against the actual static validator, not a reimplementation.
// Invoke LBDiagramBoundaryFixtures() in a device test target to execute.
#import "../src/LBDiagramPreview.m"

void LBDiagramBoundaryFixtures(void) {
  NSString *svg = @"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 240 90\"><text x=\"2\" y=\"30\">测试</text></svg>";
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"];
  NSString *(^url)(NSString *) = ^NSString *(NSString *text) { return [@"data:image/svg+xml;charset=utf-8," stringByAppendingString:[text stringByAddingPercentEncodingWithAllowedCharacters:allowed]]; };
  CGSize size = CGSizeZero;
  NSCAssert(LBDiagramCheckedURL(url(svg), &size) != nil && size.width == 240 && size.height == 90, @"safe image admitted");
  for (NSString *bad in @[@"https://example.invalid/image.svg", @"data:image/png;base64,AA", @"data:image/svg+xml;charset=utf-8,%ZZ", @"data:image/svg+xml;charset=utf-8,\" onerror=\"x", url([@"<!DOCTYPE svg>" stringByAppendingString:svg]), url([svg stringByReplacingOccurrencesOfString:@"</svg>" withString:@"<script>bad()</script></svg>"]), url([svg stringByReplacingOccurrencesOfString:@"240 90" withString:@"20001 90"]), url([svg stringByReplacingOccurrencesOfString:@"240 90" withString:@"0 90"]), url([svg stringByReplacingOccurrencesOfString:@"</svg>" withString:@"<use href=\"https://evil.invalid/a\"/></svg>"]), url([svg stringByReplacingOccurrencesOfString:@"</svg>" withString:@"<rect onclick=\"bad()\"/></svg>"]), url([svg stringByReplacingOccurrencesOfString:@"</svg>" withString:@"<foreignObject/></svg>"])]) {
    NSCAssert(LBDiagramCheckedURL(bad, &size) == nil, @"unsafe data rejected");
  }
}

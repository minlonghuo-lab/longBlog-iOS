"""Certificate layout source contracts, not UIKit screenshots."""
from pathlib import Path
import unittest
S=(Path(__file__).resolve().parents[1]/'src/LBDashboard.m').read_text()
class Certificates18(unittest.TestCase):
 def test_dedicated_vertical_text(self):
  body=S.split('- (UIStackView *)certificateRow:')[1].split('#pragma mark Stable hierarchy')[0]
  self.assertIn('@[domain, status, checked]',body)
  self.assertIn('UILayoutConstraintAxisVertical',body)
  self.assertIn('NSLineBreakByCharWrapping',body)
  self.assertIn('UIStackViewAlignmentTop',body)
  self.assertIn('constraintEqualToConstant:22',body)
 def test_reuse_rows_not_effect_rebuild(self):
  body=S.split('- (void)reconcileCertificateHosts')[1].split('#pragma mark Value updates')[0]
  self.assertIn('if ([_certHosts isEqualToArray:hosts]) return',body)
  self.assertIn('row = [self certificateRow:host]',body)
  self.assertNotIn('line:@"lock"',body)
 def test_checked_separated_from_expiry(self):
  self.assertIn('[detail rangeOfString:@" · "]',S)
  self.assertIn('[self setText:primary label:status]',S)
  self.assertIn('[self setText:secondary label:checked]',S)
  self.assertIn('[self updateCertificateRow:_certRows[h]',S)
if __name__=='__main__':unittest.main()

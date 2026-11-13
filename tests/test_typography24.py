#!/usr/bin/env python3
"""Offline typography and micro-layout source contracts for v2.4 enhancements."""
from pathlib import Path
import unittest

SRC = Path(__file__).resolve().parents[1] / 'src'

def read(name):
    return (SRC / name).read_text()

class Typography24Contracts(unittest.TestCase):
    def test_body_label_rhythmic_line_spacing(self):
        card = read('LBCard.m')
        self.assertIn('style.lineSpacing = 3.5;', card)
        self.assertIn('style.paragraphSpacing = 2.0;', card)
        self.assertIn('NSParagraphStyleAttributeName: style', card)
        self.assertIn('_bodyLabel.attributedText =', card)
        self.assertIn('_bodyLabel.numberOfLines != 1', card)
        # Verify clean reuse resets attributed text
        self.assertIn('_bodyLabel.attributedText = nil;', card)

    def test_flow_badges_adaptive_wrapping(self):
        # 2.14.7: badges stay on a single row; overflow collapses into "+N".
        card = read('LBCard.m')
        self.assertIn('- (void)fitChipsOnOneRow:(CGFloat)available', card)
        self.assertIn('[self fitChipsOnOneRow:available];', card)
        self.assertIn('+%lu', card)
        self.assertNotIn('row2', card)
        self.assertNotIn('_extraStack.axis = UILayoutConstraintAxisVertical;', card)

    def test_chip_label_dynamic_trait_colors(self):
        card = read('LBCard.m')
        self.assertIn('@interface LBChipLabel : UILabel', card)
        self.assertIn('registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ]', card)
        self.assertIn('dark ? 0.20 : 0.14', card)
        self.assertIn('dark ? 0.36 : 0.28', card)
        self.assertIn('LBChipLabel *l = [LBChipLabel new];', card)

    def test_glass_card_dark_specular_rim_light(self):
        theme = read('LBTheme.m')
        self.assertIn('dark ? [UIColor colorWithWhite:1.0 alpha:0.18] : [UIColor colorWithWhite:1.0 alpha:0.35]', theme)

if __name__ == '__main__':
    unittest.main(verbosity=2)

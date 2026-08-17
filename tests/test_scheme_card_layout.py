from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).parents[1] / "App" / "ViewController.m").read_text(encoding="utf-8")


def method(return_type: str, name: str) -> str:
    match = re.search(
        rf"^- \({re.escape(return_type)}\){re.escape(name)}[^\n]*\{{",
        SOURCE,
        re.MULTILINE,
    )
    if not match:
        return ""
    start = match.start()
    end = SOURCE.find("\n- (", match.end())
    return SOURCE[start:] if end < 0 else SOURCE[start:end]


class SchemeCardLayoutTests(unittest.TestCase):
    def test_scheme_names_use_two_lines_and_shrink_when_needed(self):
        self.assertIn("_nameLabel.numberOfLines = 2;", SOURCE)
        self.assertIn("_nameLabel.adjustsFontSizeToFitWidth = NO;", SOURCE)
        self.assertIn("_nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;", SOURCE)
        self.assertIn("_nameLabel.heightAnchor constraintEqualToConstant:36", SOURCE)
        body = method("void", "layoutSubviews")
        self.assertIn("boundingRectWithSize", body)
        self.assertIn("availableWidth", body)
        self.assertIn("availableHeight", body)
        self.assertIn("fittedSize", body)
        self.assertIn("while (fittedSize > 8.0)", body)

    def test_custom_samples_fit_actual_glyph_bounds_inside_margins(self):
        body = method("void", "drawRect:")
        # The first drawRect belongs to the main preview; find the scheme sample implementation.
        sample_start = SOURCE.index("@implementation FCFontSchemeSampleView")
        sample_end = SOURCE.index("@end", sample_start)
        body = SOURCE[sample_start:sample_end]
        self.assertIn("_fitsPreviewToBounds", body)
        self.assertIn("CTLineGetBoundsWithOptions", body)
        self.assertIn("kCTLineBoundsUseGlyphPathBounds", body)
        self.assertIn("availableWidth", body)
        self.assertIn("fittedSize", body)
        self.assertIn("horizontalInset", body)

    def test_only_custom_and_lock_cards_enable_auto_fit(self):
        body = method("void", "prepareSchemePreview:")
        self.assertIn("setFitsPreviewToBounds", body)
        self.assertIn("customMode", body)
        self.assertIn("hasPrimary", body)
        self.assertIn("customMode || !hasPrimary", body)

    def test_saved_scheme_fonts_and_required_samples_are_preserved(self):
        body = method("void", "prepareSchemePreview:")
        self.assertIn('hasChinese ? @"汉" : @"Aa"', body)
        self.assertIn('hasPrimary ? @"Aa" : @"123"', body)
        self.assertIn("[weakCard loadFontAtPath:path]", body)


if __name__ == "__main__":
    unittest.main()

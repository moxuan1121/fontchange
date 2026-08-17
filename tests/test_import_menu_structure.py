from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).parents[1] / "App" / "ViewController.m").read_text(encoding="utf-8")


def method(name: str) -> str:
    match = re.search(rf"^- \(void\){re.escape(name)}[^\n]*\{{", SOURCE, re.MULTILINE)
    if not match:
        return ""
    start = match.start()
    end = SOURCE.find("\n- (", match.end())
    return SOURCE[start:] if end < 0 else SOURCE[start:end]


class ImportMenuStructureTests(unittest.TestCase):
    def test_single_import_button_uses_unified_zip_ttc_picker(self):
        body = method("showImportMenu")
        self.assertIn("presentPickerForSlot:0", body)
        self.assertNotIn('@"导入全局字体 ZIP"', body)

    def test_in_app_zip_primary_menu_is_grouped(self):
        body = method("showInAppZIPMenuForURL:")
        self.assertIn('@"导入全局字体 ZIP"', body)
        self.assertIn('@"为当前方案设置锁屏字体"', body)
        self.assertIn('@"高级自定义"', body)
        self.assertNotIn('@"新建仅锁屏字体方案"', body)
        self.assertNotIn('@"新建仅中文字体"', body)
        self.assertNotIn('@"新建仅英数字体"', body)

    def test_in_app_advanced_menu_has_three_zip_purposes(self):
        body = method("showInAppZIPAdvancedMenuForURL:")
        self.assertIn('@"新建仅锁屏字体方案"', body)
        self.assertIn('@"新建仅中文字体"', body)
        self.assertIn('@"新建仅英数字体"', body)
        for slot in (3, 4, 5):
            self.assertIn(f"importSharedZIPURL:url slot:{slot}", body)

    def test_in_app_picker_dispatches_zip_and_ttc_after_selection(self):
        picker = method("documentPicker:")
        self.assertIn("handlePickedImportURL:source", picker)
        handler = method("handlePickedImportURL:")
        self.assertIn("showInAppTTCImportMenuForURL:url", handler)
        self.assertIn("stageSharedZIPURL:url", handler)
        self.assertIn("showInAppZIPMenuForURL:stagedURL", handler)

    def test_in_app_ttc_choices_keep_existing_behavior(self):
        menu = method("showInAppTTCImportMenuForURL:")
        self.assertIn('@"为当前方案设置锁屏字体"', menu)
        self.assertIn('@"新建仅锁屏字体方案"', menu)
        self.assertIn("self.pickingSlot = 2", menu)
        self.assertIn("self.pickingSlot = 3", menu)

    def test_shared_zip_primary_menu_is_grouped(self):
        body = method("showSharedZIPMenuForURL:")
        self.assertIn('@"导入全局字体 ZIP"', body)
        self.assertIn('@"高级自定义"', body)
        self.assertNotIn('@"为当前方案设置锁屏字体"', body)
        self.assertNotIn('@"新建仅锁屏字体方案"', body)
        self.assertNotIn('@"新建仅中文字体"', body)
        self.assertNotIn('@"新建仅英数字体"', body)

    def test_shared_zip_advanced_menu_has_four_purposes(self):
        body = method("showSharedZIPAdvancedMenuForURL:")
        self.assertIn('@"为当前方案设置锁屏字体"', body)
        self.assertIn('@"新建仅锁屏字体方案"', body)
        self.assertIn('@"新建仅中文字体"', body)
        self.assertIn('@"新建仅英数字体"', body)
        for slot in (2, 3, 4, 5):
            self.assertIn(f"importSharedZIPURL:url slot:{slot}", body)

    def test_shared_zip_is_staged_before_any_menu_and_cleaned(self):
        handler = method("handleExternalURL:")
        self.assertIn("stageSharedZIPURL:url", handler)
        self.assertIn("showSharedZIPMenuForURL:stagedURL", handler)
        self.assertLess(handler.index("stageSharedZIPURL:url"), handler.index("showSharedZIPMenuForURL:stagedURL"))
        self.assertIn("cleanupPendingSharedZIP", method("showSharedZIPMenuForURL:"))
        self.assertIn("cleanupPendingSharedZIP", method("showSharedZIPAdvancedMenuForURL:"))
        self.assertIn("cleanupPendingSharedZIP", method("importSharedZIPURL:"))

    def test_shared_zip_staging_preserves_original_filename(self):
        match = re.search(r"^- \(NSURL \*\)stageSharedZIPURL:[^\n]*\{", SOURCE, re.MULTILINE)
        self.assertIsNotNone(match)
        body = SOURCE[match.start():]
        body = body[:body.index("\n- (")]
        self.assertIn("source.lastPathComponent", body)
        self.assertIn("createDirectoryAtPath:stagingDirectory", body)
        self.assertIn("self.pendingSharedZIPPath = stagingDirectory", body)

    def test_ttc_share_choices_remain_available(self):
        menu = method("showTTCImportMenuForURL:")
        self.assertIn('@"加入当前方案"', menu)
        self.assertIn('@"新建仅锁屏方案"', menu)
        self.assertIn("self.pickingSlot = 2", menu)
        self.assertIn("self.pickingSlot = 3", menu)
        self.assertIn("showTTCImportMenuForURL:url", method("handleExternalURL:"))


if __name__ == "__main__":
    unittest.main()

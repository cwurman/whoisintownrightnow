import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, MagicMock

import photo_ocr


class OCRTests(unittest.TestCase):
    def setUp(self):
        self.extraction = {"photo_type": "food", "caption": "Food on a plate", "ocr_text": "Invented menu description",
                           "visible_foods": ["food"], "visible_features": [], "uncertainties": [], "use_for_search": True}
        self.photo = {"photo_url": "https://lh3.googleusercontent.com/example=w600-h450-p-k-no"}

    def test_nonmenu_cannot_add_generated_text_to_ocr(self):
        value, details = photo_ocr.apply_ocr_policy(self.extraction, self.photo)
        self.assertEqual(value["ocr_text"], "")
        self.assertEqual(details["model_ocr_text"], "Invented menu description")
        self.assertEqual(self.extraction["ocr_text"], "Invented menu description")

    def test_missing_native_engine_does_not_fall_back_to_generated_ocr(self):
        self.extraction["photo_type"] = "menu"
        with tempfile.TemporaryDirectory() as temp, patch.object(photo_ocr, "BINARY", Path(temp) / "missing"):
            value, details = photo_ocr.apply_ocr_policy(self.extraction, self.photo)
        self.assertEqual(value["ocr_text"], "")
        self.assertEqual(details["ocr_status"], "local_engine_unavailable")

    def test_native_ocr_replaces_model_text_and_preserves_provenance(self):
        self.extraction["photo_type"] = "menu"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / "ocr"
            binary.touch()
            with patch.object(photo_ocr, "BINARY", binary), patch.object(photo_ocr, "CACHE", root / "cache"), \
                 patch.object(photo_ocr, "urlopen") as download, patch.object(photo_ocr.subprocess, "run") as native:
                download.return_value.__enter__.return_value.read.return_value = b"fixture image"
                native.return_value = MagicMock(stdout=json.dumps({"text": "SHISHITO PEPPERS", "engine": "test OCR", "lines": []}))
                value, details = photo_ocr.apply_ocr_policy(self.extraction, self.photo)
        self.assertEqual(value["ocr_text"], "SHISHITO PEPPERS")
        self.assertEqual(details["ocr_status"], "completed")
        self.assertTrue(details["ocr_image_sha256"])
        self.assertIn("w1600-h1200", details["ocr_image_url"])


if __name__ == "__main__":
    unittest.main()

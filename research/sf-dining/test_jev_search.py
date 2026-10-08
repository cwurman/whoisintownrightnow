"""Jev integration tests; all API answers in these tests are local fixtures."""
from copy import deepcopy
import unittest

from jev_search import apply_answers, make_request, validate_response
from photo_search import search


class JevTests(unittest.TestCase):
    def setUp(self):
        self.candidates = search("kebab", limit=3)
        self.request = make_request("kebab", self.candidates)
        self.answers = {}
        for name, question in self.request["questions"].items():
            if question["type"] == "choice":
                value = "dish_photos" if name == "widget" else "p0"
                self.answers[name] = {"type": "choice", "choice": value, "confidence": .9}
            else:
                self.answers[name] = {"type": "score", "score": 2, "confidence": .9}
        self.response = {"model": "fixture", "answers": self.answers}

    def test_payload_is_text_and_selected_photo_belongs_to_result(self):
        validate_response(self.response, self.request)
        result = apply_answers(self.candidates, self.response)
        self.assertEqual(result["widget"], "dish_photos")
        for restaurant in result["results"]:
            photo = restaurant["jev"]["selected_photo"]
            if photo:
                self.assertIn(photo["photo_id"], [p["photo_id"] for p in restaurant["photos"]])
        for candidate in self.request["state"]["candidates"].values():
            for photo in candidate["photos"].values():
                self.assertNotIn("url", photo)

    def test_unknown_photo_and_missing_answers_are_rejected(self):
        invalid = deepcopy(self.response)
        del invalid["answers"]["widget"]
        with self.assertRaises(ValueError):
            validate_response(invalid, self.request)
        invalid = deepcopy(self.response)
        photo_key = next(k for k in invalid["answers"] if k.endswith("_photo"))
        invalid["answers"][photo_key]["choice"] = "p99"
        with self.assertRaises(ValueError):
            validate_response(invalid, self.request)

    def test_uncertain_ui_uses_compact_layout_and_input_is_not_mutated(self):
        original = deepcopy(self.candidates)
        self.answers["widget"]["confidence"] = .1
        for name, answer in self.answers.items():
            if name.endswith("_photo"):
                answer["confidence"] = .1
        result = apply_answers(self.candidates, self.response)
        self.assertEqual(result["widget"], "compact")
        self.assertTrue(all(r["jev"]["selected_photo"] is None for r in result["results"]))
        self.assertEqual(self.candidates, original)


if __name__ == "__main__":
    unittest.main()

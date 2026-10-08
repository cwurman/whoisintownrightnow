"""Regression checks using real collected evidence and a mocked extraction API."""
import argparse
from contextlib import closing, redirect_stdout, redirect_stderr
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError

import extract_photo_text as worker
from photo_search import DATA, DB, read_annotations, search


class SearchTests(unittest.TestCase):
    def test_menu_ocr_is_retrievable_and_linked_to_its_photo(self):
        results = search("shishito peppers", photos_only=True)
        canela = next(r for r in results if r["name"] == "Canela Bistro Bar")
        self.assertEqual(canela["match_type"], "all_terms")
        evidence = next(e for e in canela["matched_evidence"] if e["kind"] == "photo_ocr")
        self.assertIn("FLASH-FRIED SHISHITO PEPPERS", evidence["text"])
        self.assertEqual(evidence["restaurant_id"], canela["restaurant_id"])
        self.assertTrue(any(p["photo_id"] == evidence["photo_id"] for p in canela["photos"]))
        self.assertNotIn("pizza", results[0]["name"].lower())

    def test_scene_description_finds_previously_uncaptioned_photo(self):
        first = next(r for r in search("mint green", scope="focus", photos_only=True, limit=100) if r["name"] == "La Vaca Birria")
        self.assertEqual(first["name"], "La Vaca Birria")
        self.assertEqual(first["matched_evidence"][0]["kind"], "photo_vision_caption")
        self.assertEqual(first["query_coverage"], 1)

    def test_observation_uncertainty_survives_retrieval(self):
        first = next(r for r in search("dog patio", photos_only=True, limit=100) if r["name"] == "Fable")
        self.assertEqual(first["name"], "Fable")
        self.assertTrue(first["photos"][0]["uncertainties"])
        self.assertEqual(len({p["photo_id"] for p in first["photos"]}), len(first["photos"]))

    def test_excluded_images_are_not_added_to_index(self):
        excluded = [a["photo_id"] for a in read_annotations().values() if not a["extraction"]["use_for_search"]]
        self.assertGreaterEqual(len(excluded), 2)
        with closing(sqlite3.connect(DB)) as con:
            for pid in excluded:
                self.assertEqual(con.execute("SELECT count(*) FROM evidence WHERE id IN (?,?)", (pid + ":vision", pid + ":ocr")).fetchone()[0], 0)

    def test_scopes_and_input_are_safe(self):
        for query in ["sushi", '" OR * --', "kebab", "shishito peppers"]:
            self.assertTrue(all(r["area_priority"] == "focus" for r in search(query, scope="focus")))
        self.assertEqual(search("the and food"), [])
        self.assertEqual(search('"*'), [])
        self.assertTrue(search("keb", prefix_last=True, photos_only=True))

    def test_caption_and_ocr_from_one_photo_count_once(self):
        canela = next(r for r in search("tapas menu", photos_only=True, limit=100) if r["name"] == "Canela Bistro Bar")
        photo_ids = [e["photo_id"] for e in canela["matched_evidence"]]
        self.assertLess(len(set(photo_ids)), len(photo_ids))
        self.assertEqual(canela["matched_sources"], len(set(photo_ids)))


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.photo = {"photo_id": "test-photo", "restaurant_id": "test-place", "restaurant_name": "Test Place",
                      "photo_url": "https://example.com/photo.jpg", "source_url": "https://example.com/place",
                      "area_priority": "focus", "has_source_caption": False, "status": "pending"}
        self.extraction = {"photo_type": "interior", "caption": "Wooden chairs", "visible_foods": [],
                           "visible_features": ["wooden chairs"], "ocr_text": "", "uncertainties": [], "use_for_search": True}
        self.response = {"id": "test-response", "status": "completed", "model": "test-model", "usage": {},
                         "output": [{"type": "reasoning"}, {"type": "message", "content": [
                             {"type": "output_text", "text": json.dumps(self.extraction)}]}]}

    def test_request_and_response_contract(self):
        body = worker.request_body(self.photo, "test-model")
        self.assertFalse(body["store"])
        self.assertTrue(body["text"]["format"]["strict"])
        self.assertNotIn("Test Place", json.dumps(body))
        self.assertEqual(worker.parse_response(self.response), self.extraction)
        for response in [{"status": "incomplete"}, {"status": "completed", "output": []},
                         {"status": "completed", "output": [{"content": [{"type": "refusal"}]}]}]:
            with self.assertRaises(ValueError):
                worker.parse_response(response)

    def test_selection_uses_live_completion_and_attempts(self):
        queue = [self.photo, {**self.photo, "photo_id": "outside", "area_priority": "other_sf"},
                 {**self.photo, "photo_id": "captioned", "has_source_caption": True}]
        self.assertEqual(worker.select_jobs(queue, {}, set(), "nearby", False, False), [self.photo])
        self.assertEqual(worker.select_jobs(queue, {"test-photo": {}}, set(), "nearby", False, False), [])
        self.assertEqual(worker.select_jobs(queue, {}, {"test-photo"}, "nearby", False, False), [])
        self.assertEqual(worker.select_jobs(queue, {}, {"test-photo"}, "nearby", False, True), [self.photo])

    def test_worker_saves_and_resumes_without_resubmitting(self):
        self.run_worker_scenario(fail=False)

    def test_uncertain_failure_is_not_silently_retried(self):
        self.run_worker_scenario(fail=True)

    def run_worker_scenario(self, fail):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            (data / "photo-vision-queue.jsonl").write_text(json.dumps(self.photo) + "\n")
            args = argparse.Namespace(scope="nearby", all_photos=False, retry_attempted=False, limit=1,
                                      model="test-model", dry_run=False)
            with patch.object(worker, "DATA", data), patch.object(worker, "OUTPUT", data / "results.jsonl"), \
                 patch.object(worker, "ATTEMPTS", data / "attempts.jsonl"), \
                 patch.dict("os.environ", {"OPENAI_API_KEY": "fake-test-key"}), \
                 patch.object(worker, "urlopen") as api, redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                if fail:
                    api.side_effect = URLError("test timeout")
                else:
                    api.return_value.__enter__.return_value = io.StringIO(json.dumps(self.response))
                self.assertEqual(worker.run(args), 1 if fail else 0)
                self.assertEqual(api.call_count, 1)
                self.assertEqual(worker.run(args), 0)
                self.assertEqual(api.call_count, 1)
                if not fail:
                    result = json.loads((data / "results.jsonl").read_text())
                    self.assertEqual(result["photo_id"], self.photo["photo_id"])
                    self.assertEqual(result["extraction"], self.extraction)


if __name__ == "__main__":
    unittest.main()

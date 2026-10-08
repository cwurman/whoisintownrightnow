#!/usr/bin/env python3
"""Extract structured captions and menu OCR from a bounded, resumable photo queue."""
import argparse
from copy import deepcopy
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import sys
import time
from threading import Lock
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from photo_schema import PROMPT, PROMPT_VERSION, SCHEMA, validate
from photo_search import DATA, read_annotations
from photo_ocr import apply_ocr_policy

OUTPUT = DATA / "photo-vision.jsonl"
ATTEMPTS = DATA / "photo-vision-attempts.jsonl"
KEY_PATH = Path.home() / ".config" / "sf-dining" / "openai-api-key"
WRITE_LOCK = Lock()


def now():
    return datetime.now(timezone.utc).isoformat()


def append_record(path, value):
    with WRITE_LOCK, path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, ensure_ascii=False) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def request_body(photo, model):
    schema = deepcopy(SCHEMA)
    schema["properties"]["ocr_text"] = {"type": "string", "enum": [""]}
    body = {
        "model": model,
        "store": False,
        "max_output_tokens": 4000,
        "input": [{"role": "user", "content": [
            {"type": "input_text", "text": PROMPT},
            {"type": "input_image", "image_url": photo["photo_url"], "detail": "auto"},
        ]}],
        "text": {"format": {"type": "json_schema", "name": "restaurant_photo",
                             "strict": True, "schema": schema}},
    }
    if model == "gpt-5-nano" or model.startswith("gpt-5-nano-"):
        body["reasoning"] = {"effort": "minimal"}
        body["max_output_tokens"] = 1800
    return body


def parse_response(response):
    if response.get("status") != "completed":
        raise ValueError(f"Response not complete: {response.get('status')}")
    parts = []
    for item in response.get("output", []):
        for content in item.get("content", []):
            if content.get("type") == "refusal":
                raise ValueError("Model refused the extraction")
            if content.get("type") == "output_text":
                parts.append(content["text"])
    if not parts:
        raise ValueError("Response has no extraction text")
    return validate(json.loads("".join(parts)))


def select_jobs(queue, completed, attempted, scope, all_photos, retry_attempted):
    areas = {"focus": {"focus"}, "nearby": {"focus", "nearby"},
             "all": {"focus", "nearby", "other_sf"}}[scope]
    jobs = [p for p in queue if p["area_priority"] in areas
            and p["photo_id"] not in completed
            and (all_photos or not p["has_source_caption"])
            and (retry_attempted or p["photo_id"] not in attempted)]
    return sorted(jobs, key=lambda p: ({"focus": 0, "nearby": 1, "other_sf": 2}[p["area_priority"]],
                                      p["has_source_caption"], p["photo_id"]))


def run(args):
    queue = [json.loads(line) for line in (DATA / "photo-vision-queue.jsonl").read_text().splitlines() if line.strip()]
    completed = read_annotations(OUTPUT)
    attempted = {json.loads(line)["photo_id"] for line in ATTEMPTS.read_text().splitlines() if line.strip()} if ATTEMPTS.exists() else set()
    jobs = select_jobs(queue, completed, attempted, args.scope, args.all_photos, args.retry_attempted)
    batch = jobs[:args.limit]
    print(json.dumps({"dry_run": args.dry_run, "scope": args.scope, "model": args.model,
                      "eligible_pending": len(jobs), "selected": len(batch),
                      "completed_photos": len(completed), "attempted_without_result": len(attempted - completed.keys()),
                      "preview": [{"restaurant_name": p["restaurant_name"], "photo_id": p["photo_id"]} for p in batch[:5]]}, indent=2), flush=True)
    if args.dry_run or not batch:
        return 0
    key = os.environ.get("OPENAI_API_KEY") or (KEY_PATH.read_text().strip() if KEY_PATH.exists() else None)
    if not key:
        print("OPENAI_API_KEY is not configured. No API requests sent.", file=sys.stderr)
        return 2
    throttle_lock = Lock()
    next_start = [0.0]
    rate = getattr(args, "requests_per_minute", 0)

    def throttle():
        if rate:
            with throttle_lock:
                delay = next_start[0] - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                next_start[0] = time.monotonic() + 60 / rate

    def process_photo(photo):
        attempt = {"photo_id": photo["photo_id"], "restaurant_id": photo["restaurant_id"],
                   "model": args.model, "started_at": now(), "status": "started"}
        # Persist before sending. An interrupted/uncertain request is not silently resubmitted.
        append_record(ATTEMPTS, attempt)
        response = None
        try:
            request = Request("https://api.openai.com/v1/responses",
                              data=json.dumps(request_body(photo, args.model)).encode("utf-8"),
                              headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
                              method="POST")
            for retry in range(4):
                throttle()
                try:
                    with urlopen(request, timeout=60) as http:
                        response = json.load(http)
                    break
                except HTTPError as error:
                    try:
                        details = json.load(error).get("error", {})
                    except (ValueError, AttributeError):
                        details = {}
                    error.parsed_details = details
                    # A rate-limit rejection did not run inference; only this explicit
                    # rejection is safe to retry automatically. Never retry timeouts.
                    if error.code != 429 or details.get("code") != "rate_limit_exceeded" or retry == 3:
                        raise
                    append_record(ATTEMPTS, {**attempt, "status": "rate_limited", "retry": retry + 1, "finished_at": now()})
                    time.sleep(2 ** (retry + 1))
            extraction = parse_response(response)
            extraction, ocr_details = apply_ocr_policy(extraction, photo)
            validate(extraction)
            annotation = {"photo_id": photo["photo_id"], "restaurant_id": photo["restaurant_id"],
                          "photo_url": photo["photo_url"], "status": "completed",
                          "method": "openai_responses_vision", "model": response.get("model", args.model),
                          "prompt_version": PROMPT_VERSION, "processed_at": now(),
                          "response_id": response.get("id"), "usage": response.get("usage"),
                          "image_input": "public_url", "human_verified": False, "extraction": extraction,
                          "ocr_processing": ocr_details}
            append_record(OUTPUT, annotation)
            append_record(ATTEMPTS, {**attempt, "status": "completed", "finished_at": now(),
                                     "response_id": response.get("id"), "usage": response.get("usage")})
            print(json.dumps({"photo_id": photo["photo_id"], "status": "completed",
                              "photo_type": extraction["photo_type"], "use_for_search": extraction["use_for_search"]}), flush=True)
            return True
        except Exception as error:
            # No automatic retries: timeouts may already have incurred a charge.
            failure = {**attempt, "status": "failed_or_uncertain", "finished_at": now(),
                       "error_type": type(error).__name__, "error": str(error)[:400]}
            if isinstance(error, HTTPError):
                failure["http_status"] = error.code
                failure["request_id"] = error.headers.get("x-request-id")
                try:
                    details = getattr(error, "parsed_details", None)
                    if details is None:
                        details = json.load(error).get("error", {})
                    failure["api_error_code"] = details.get("code")
                    failure["api_error_message"] = str(details.get("message", ""))[:400].replace(key, "[redacted]")
                except (ValueError, AttributeError):
                    pass
            if response:
                failure.update(response_id=response.get("id"), usage=response.get("usage"),
                               incomplete_details=response.get("incomplete_details"))
            append_record(ATTEMPTS, failure)
            print(json.dumps(failure), file=sys.stderr)
            print("Stopped; prior completed photos are saved. Inspect the attempts log before explicitly retrying.", file=sys.stderr)
            return False
    workers = getattr(args, "workers", 1)
    pending_photos = iter(batch)
    failed = False
    with ThreadPoolExecutor(max_workers=workers) as pool:
        active = {pool.submit(process_photo, photo) for photo in [next(pending_photos, None) for _ in range(workers)] if photo}
        while active:
            done, active = wait(active, return_when=FIRST_COMPLETED)
            statuses = [future.result() for future in done]
            failed = failed or not all(statuses)
            if not failed:
                for _ in done:
                    photo = next(pending_photos, None)
                    if photo is not None:
                        active.add(pool.submit(process_photo, photo))
    if failed:
        return 1
    print("Batch saved. Run photo_search.py build to refresh the search index.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="A model available to your API project with vision and structured outputs")
    parser.add_argument("--scope", choices=["focus", "nearby", "all"], default="nearby")
    parser.add_argument("--limit", type=int, default=10, help="Maximum photo requests in this run (default: 10)")
    parser.add_argument("--workers", type=int, default=1, help="Concurrent requests (1 to 8)")
    parser.add_argument("--requests-per-minute", type=int, default=140, help="Pace request starts (default: 140/min)")
    parser.add_argument("--all-photos", action="store_true", help="Also analyze photos that already have source captions")
    parser.add_argument("--retry-attempted", action="store_true", help="Explicitly retry unfinished attempts; they may already have incurred charges")
    parser.add_argument("--dry-run", action="store_true", help="Show selection without sending requests or writing files")
    args = parser.parse_args()
    if not 1 <= args.limit <= 1000:
        parser.error("limit must be between 1 and 1000")
    if not 1 <= args.workers <= 8:
        parser.error("workers must be between 1 and 8")
    if not 1 <= args.requests_per_minute <= 1000:
        parser.error("requests-per-minute must be between 1 and 1000")
    if args.dry_run:
        return run(args)
    # Prevent two workers from submitting the same pending queue simultaneously.
    with (DATA / ".photo-vision.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("Another extraction worker is running")
        return run(args)


if __name__ == "__main__":
    sys.exit(main())

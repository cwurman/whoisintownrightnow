#!/usr/bin/env python3
"""Report current photo coverage and estimated costs from returned API usage."""
from collections import Counter
from datetime import datetime, timezone
import json

from photo_search import DATA, read_annotations


def report():
    restaurants = json.loads((DATA / "maps-demo.json").read_text())["restaurants"]
    annotations = read_annotations()
    photos = [(r, p) for r in restaurants for p in r["photos"]]
    scopes = {}
    for name, areas in [("focus", {"focus"}), ("nearby", {"focus", "nearby"}),
                        ("all", {"focus", "nearby", "other_sf"})]:
        items = [(r, p) for r, p in photos if r["area_priority"] in areas]
        inspected = [annotations[p["photo_id"]] for r, p in items if p["photo_id"] in annotations]
        scopes[name] = {
            "photo_references": len(items),
            "existing_source_captions": sum(bool(p["caption"]) for r, p in items),
            "vision_processed": len(inspected),
            "useful_vision_descriptions": sum(a["extraction"]["use_for_search"] for a in inspected),
            "excluded_by_vision": sum(not a["extraction"]["use_for_search"] for a in inspected),
            "ocr_records": sum(bool(a["extraction"]["ocr_text"].strip()) and a["extraction"]["use_for_search"] for a in inspected),
            "pending_without_source_caption": sum(not p["caption"] and p["photo_id"] not in annotations for r, p in items),
            "source_caption_or_completed_analysis": sum(bool(p["caption"]) or p["photo_id"] in annotations for r, p in items),
        }
    attempts_path = DATA / "photo-vision-attempts.jsonl"
    attempts = [json.loads(line) for line in attempts_path.read_text().splitlines() if line.strip()] if attempts_path.exists() else []
    responses = {a["response_id"]: a for a in attempts if a.get("response_id") and a.get("usage")}
    total = Counter()
    unpriced = []
    estimated = 0.0
    for rid, a in responses.items():
        usage = a["usage"]
        incoming = usage["input_tokens"]
        cached = usage.get("input_tokens_details", {}).get("cached_tokens", 0)
        outgoing = usage["output_tokens"]
        total.update(input_tokens=incoming, cached_input_tokens=cached, output_tokens=outgoing)
        if a["model"].startswith("gpt-5-nano"):
            estimated += ((incoming - cached) * .05 + cached * .005 + outgoing * .40) / 1_000_000
        else:
            unpriced.append(rid)
    last_attempts = {a["photo_id"]: a for a in attempts}
    unresolved = [a for pid, a in last_attempts.items() if pid not in annotations]
    return {
        "as_of": datetime.now(timezone.utc).isoformat(), "scopes": scopes,
        "extraction_methods": dict(Counter(a["method"] for a in annotations.values())),
        "photo_types": dict(Counter(a["extraction"]["photo_type"] for a in annotations.values())),
        "local_ocr_status": dict(Counter(a.get("ocr_processing", {}).get("ocr_status", "assistant_pilot") for a in annotations.values())),
        "unresolved_attempts": [{k: a.get(k) for k in ["photo_id", "status", "http_status", "api_error_code"]} for a in unresolved],
        "openai_usage": dict(total), "responses_with_usage": len(responses),
        "estimated_openai_cost_usd": round(estimated, 6), "unpriced_response_ids": unpriced,
        "pricing_source": "https://developers.openai.com/api/docs/models/gpt-5-nano",
        "cost_note": "Estimate from returned token usage at standard GPT-5 nano rates, not a billing invoice. Requests without returned usage are not measurable here.",
    }


if __name__ == "__main__":
    result = report()
    (DATA / "photo-processing-status.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))

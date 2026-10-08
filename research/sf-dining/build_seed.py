#!/usr/bin/env python3
"""Build a restaurant-candidate seed from DataSF's public inspection records.

No credentials, paid APIs, or third-party review/photo collection required.
Records are permit-level candidates, not verified active restaurants.
"""

import argparse
from collections import Counter, defaultdict
from datetime import date, datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import urllib.request

SOURCE_URL = "https://data.sfgov.org/api/views/tvy3-wexg/rows.json?accessType=DOWNLOAD"
DATASET_URL = "https://data.sfgov.org/d/tvy3-wexg"
PERMIT_PATTERN = re.compile(r"^H(24|25|26|28|29|87|88|89)R?\b")
# Broad SF-area bounds; this is NOT a municipal-boundary polygon.
BBOX = (-122.52, 37.70, -122.35, 37.84)


def clean(value):
    return re.sub(r"\s+", " ", value or "").strip()


def coordinates(row):
    try:
        lat, lon = float(row["latitude"]), float(row["longitude"])
    except (ValueError, TypeError, KeyError):
        return None
    if not (BBOX[0] <= lon <= BBOX[2] and BBOX[1] <= lat <= BBOX[3]):
        return None
    return {"latitude": lat, "longitude": lon}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--as-of", type=date.fromisoformat, default=date.today())
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).parent / "data")
    args = parser.parse_args()

    request = urllib.request.Request(SOURCE_URL, headers={"User-Agent": "SF-Dining-Data-Research/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        source_bytes = response.read()
    payload = json.loads(source_bytes)
    view = payload["meta"]["view"]
    fields = [column["fieldName"] for column in view["columns"]]
    required = {"permit_number", "permit_type", "dba", "inspection_date", "latitude", "longitude"}
    if not required.issubset(fields):
        raise ValueError("DataSF schema changed: required fields are missing")
    if view.get("licenseId") != "PDDL":
        raise ValueError("DataSF license changed; inspect it before refreshing this seed")
    rows = [dict(zip(fields, values)) for values in payload["data"]]

    excluded = Counter()
    by_permit = defaultdict(list)
    for row in rows:
        if not PERMIT_PATTERN.match(row.get("permit_type") or ""):
            excluded["outside_selected_permit_types"] += 1
            continue
        raw_date = (row.get("inspection_date") or "")[:10]
        try:
            inspected = date.fromisoformat(raw_date)
        except ValueError:
            excluded["missing_or_invalid_inspection_date"] += 1
            continue
        if inspected > args.as_of:
            excluded["future_inspection_date"] += 1
            continue
        if not clean(row.get("permit_number")):
            excluded["missing_permit_number"] += 1
            continue
        by_permit[clean(row["permit_number"])].append(row)

    candidates = []
    skipped_permits = Counter()
    for permit, history in by_permit.items():
        # Use the latest valid observation; do not infer a current open/closed status.
        latest = max(history, key=lambda r: (
            r.get("inspection_date") or "", r.get("data_as_of") or "", r.get(":id") or ""
        ))
        point = coordinates(latest)
        if not point:
            skipped_permits["missing_or_outside_sf_area_coordinates"] += 1
            continue
        name = clean(latest.get("dba"))
        address = clean(latest.get("street_address_clean") or latest.get("street_address"))
        if not name or not address:
            skipped_permits["missing_name_or_address"] += 1
            continue
        code = PERMIT_PATTERN.match(latest["permit_type"]).group(1)
        kind = {"24": "restaurant", "25": "restaurant", "26": "restaurant",
                "28": "takeout", "29": "fast_food", "87": "bar_with_food",
                "88": "bakery", "89": "bakery"}[code]
        candidates.append({
            "candidate_id": "datasf:tvy3-wexg:" + permit,
            "name": name,
            "address": address,
            "locality_context": "San Francisco",
            "neighborhood": latest.get("analysis_neighborhood") or None,
            "coordinates": point,
            "candidate_kind": kind,
            "source_permit_number": permit,
            "source_permit_type": latest["permit_type"],
            "last_inspected_at": latest["inspection_date"],
            "source_record_as_of": latest.get("data_as_of"),
            "source_url": DATASET_URL,
            "source_license": "PDDL",
            "verification_status": "candidate_only",
            "current_operating_status": "unknown",
        })

    candidates.sort(key=lambda r: (r["neighborhood"] or "", r["name"], r["candidate_id"]))
    assert len({r["candidate_id"] for r in candidates}) == len(candidates)
    assert candidates, "No candidates found; inspect source changes"
    name_address = Counter((r["name"].casefold(), r["address"].casefold()) for r in candidates)
    observed_dates = [r["inspection_date"] for r in rows if r.get("inspection_date")]
    summary = {
        "retrieved_at": datetime.now(timezone.utc).isoformat(),
        "as_of_date": args.as_of.isoformat(),
        "source_url": SOURCE_URL,
        "dataset_url": DATASET_URL,
        "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
        "source_license": view.get("licenseId"),
        "source_row_count": len(rows),
        "latest_source_record_as_of": max(r.get("data_as_of") or "" for r in rows),
        "latest_raw_inspection_date": max(observed_dates),
        "latest_accepted_inspection_date": max(r["last_inspected_at"] for r in candidates),
        "excluded_row_counts": dict(excluded),
        "excluded_permit_counts": dict(skipped_permits),
        "candidate_permit_count": len(candidates),
        "unique_normalized_name_address_pairs": len(name_address),
        "duplicate_name_address_groups": sum(n > 1 for n in name_address.values()),
        "candidate_kind_counts": dict(Counter(r["candidate_kind"] for r in candidates).most_common()),
        "neighborhood_counts": dict(Counter(r["neighborhood"] or "Unknown" for r in candidates).most_common()),
        "bbox_west_south_east_north": BBOX,
        "limitations": [
            "Permit-level candidates, not a count of active restaurants or exhaustive city coverage.",
            "Multiple permits can represent the same venue; branches and shared premises need entity matching.",
            "No current opening hours, menus, cuisine, reviews, ratings, or photos are supplied by this seed.",
            "Inspection outcomes are deliberately not used as operating-status or restaurant-quality signals.",
            "Future-dated selected inspection records are excluded before choosing a permit's latest observation.",
            "Coordinates are screened against a broad bounding box, not an exact municipal boundary.",
        ],
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "sf-candidates.json").write_text(json.dumps(candidates, indent=2) + "\n")
    (args.output_dir / "seed-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

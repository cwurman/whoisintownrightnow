#!/usr/bin/env python3
"""Normalize saved Google Maps DOM exports; no network requests required."""
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re

DATA = Path(__file__).parent / "data"
FOCUS_NEIGHBORHOODS = {"The Castro", "Mission District", "Mission Dolores", "Noe Valley"}
NEARBY_NEIGHBORHOODS = {
    "Dolores Heights", "Eureka Valley", "Upper Market", "Duboce Triangle",
    "Bernal Heights", "Holly Park", "Fairmount", "Glen Park", "Cole Valley",
    "Lower Haight", "Haight-Ashbury", "Potrero Hill", "Hayes Valley",
}


def place_id(url):
    match = re.search(r"!19s([^?&!]+)", url)
    return match.group(1) if match else None


def identity(url):
    return "google:" + (place_id(url) or hashlib.sha256(url.encode()).hexdigest()[:16])


def main():
    raw = json.loads((DATA / "google-maps-details.json").read_text())
    searches_path = DATA / "google-maps-searches.json"
    searches = (json.loads(searches_path.read_text()) if searches_path.exists() else
                [json.loads((DATA / "google-maps-public-sample.json").read_text())])
    listings = defaultdict(list)
    for search in searches:
        for listing in search["results"]:
            if listing["links"]:
                listings[identity(listing["links"][0]["url"])].append((search, listing))
    # Do not silently lose evidence if a collector accidentally saves a duplicate.
    assert len({identity(item["source_url"]) for item in raw}) == len(raw), "Merge duplicate place visits before normalization"
    restaurants, evidence = [], []
    for item in raw:
        url = item["source_url"]
        rid = identity(url)
        labels = item["accessible_labels"]
        def field(prefix):
            return next((x["label"][len(prefix):].strip() for x in labels if x["label"].startswith(prefix)), None)
        website = next((x["url"] for x in labels if x["label"].startswith("Website:")), None)
        name = item.get("listing_name") or item["name"]
        # Anchor metadata to the name, avoiding sponsored ad headings.
        header = re.search(re.escape(name) + r"\n([0-5]\.\d)\n\(([\d,]+)\)([^\n]*)\n([^\n]+)", item["visible_text"])
        category = header.group(4).split("·")[0].strip() if header else None
        price = (header.group(3).lstrip("·").strip() or None) if header else None
        coords = re.search(r"!3d(-?[\d.]+)!4d(-?[\d.]+)", url)
        neighborhood = re.search(r"^[A-Z0-9+]+ (.+), San Francisco, CA$", field("Plus code:") or "")
        address = field("Address:")
        restaurant = {"restaurant_id": rid, "google_place_id": place_id(url),
                      "name": name, "address": address,
                      "city": "San Francisco" if address and ", San Francisco," in address else None,
                      "neighborhood": neighborhood.group(1) if neighborhood else None,
                      "neighborhood_origin": "Google Maps plus-code locality label" if neighborhood else None,
                      "latitude": float(coords.group(1)) if coords else None,
                      "longitude": float(coords.group(2)) if coords else None,
                      "category": category, "price_display": price,
                      "phone": field("Phone:"), "website": website,
                      "rating": float(header.group(1)) if header else None,
                      "google_review_count": int(header.group(2).replace(",", "")) if header else None,
                      "discovery_queries": list(dict.fromkeys(s["query"] for s, _ in listings[rid])),
                      "appeared_as_sponsored": any(l.get("sponsored", False) for _, l in listings[rid]),
                      "source_url": url, "retrieved_at": item["retrieved_at"],
                      "reviews": [], "photos": []}
        restaurant["area_priority"] = (
            "focus" if restaurant["neighborhood"] in FOCUS_NEIGHBORHOODS else
            "nearby" if restaurant["neighborhood"] in NEARBY_NEIGHBORHOODS else "other_sf"
        )
        evidence.append({"evidence_id": rid + ":metadata", "restaurant_id": rid,
                         "kind": "restaurant_metadata",
                         "text": ". ".join(filter(None, [name, category, restaurant["neighborhood"], address, price])),
                         "source_url": url, "retrieved_at": item["retrieved_at"]})
        photo_map = {}
        for review in item["reviews"]:
            review_id = rid + ":review:" + review["review_id"]
            normalized = {"evidence_id": review_id, "restaurant_id": rid,
                          "kind": "customer_review_excerpt", "text": review["text"],
                          "author": review["author"], "rating_label": review.get("rating_label"),
                          "may_be_truncated": review["is_truncated"], "source_url": url,
                          "source_review_id": review["review_id"], "retrieved_at": item["retrieved_at"]}
            if review.get("text"):
                restaurant["reviews"].append(normalized)
                evidence.append(normalized)
            for photo in review["photos"]:
                label = (photo.get("label") or "").strip()
                if not photo.get("url") or label.lower() == "video" or re.match(r"\+\s*\d+ more photos", label):
                    continue
                key = re.sub(r"=w\d+.*$", "", photo["url"])
                if key in photo_map:
                    continue
                caption = None if not label or re.match(r"Photo \d+ on .+ review", label) else label
                record = {"photo_id": rid + ":photo:" + hashlib.sha256(key.encode()).hexdigest()[:16],
                          "restaurant_id": rid,
                          "url": photo["url"], "source_accessibility_label": label,
                          "caption": caption, "caption_origin": "Google Maps rendered accessibility label",
                          "visually_verified": False, "author": review["author"],
                          "source_review_id": review["review_id"], "source_url": url,
                          "retrieved_at": item["retrieved_at"]}
                photo_map[key] = record
                if caption:
                    evidence.append({"evidence_id": record["photo_id"], "restaurant_id": rid,
                                     "kind": "photo_source_caption", "text": caption,
                                     "photo_url": photo["url"], "source_url": url,
                                     "author": review["author"], "source_review_id": review["review_id"],
                                     "retrieved_at": item["retrieved_at"],
                                     "caption_origin": record["caption_origin"],
                                     "visually_verified": False})
        restaurant["photos"] = list(photo_map.values())
        restaurants.append(restaurant)
    restaurants.sort(key=lambda r: ({"focus": 0, "nearby": 1, "other_sf": 2}[r["area_priority"]], r["neighborhood"] or "", r["name"].casefold()))
    summary = {"restaurants": len(restaurants),
               "search_batches": len(searches),
               "search_queries": len({s["query"] for s in searches}),
               "listing_appearances": sum(len(s["results"]) for s in searches),
               "review_excerpts": sum(len(r["reviews"]) for r in restaurants),
               "unique_review_photo_urls": sum(len(r["photos"]) for r in restaurants),
               "photos_with_descriptive_source_labels": sum(p["caption"] is not None for r in restaurants for p in r["photos"]),
               "searchable_evidence_records": len(evidence),
               "restaurants_with_photos": sum(bool(r["photos"]) for r in restaurants),
               "restaurants_with_review_text": sum(bool(r["reviews"]) for r in restaurants),
               "area_priority_counts": dict(Counter(r["area_priority"] for r in restaurants)),
               "collection_cost_usd": 0,
               "first_retrieved_at": min(r["retrieved_at"] for r in restaurants),
               "last_retrieved_at": max(r["retrieved_at"] for r in restaurants),
               "neighborhood_counts": dict(sorted(Counter(r["neighborhood"] or "Unspecified" for r in restaurants).items())),
               "category_counts": dict(sorted(Counter(r["category"] or "Unspecified" for r in restaurants).items())),
               "limitations": ["Query-selected demo sample, not exhaustive or representative SF coverage.",
                               "Discovery queries do not establish cuisine, dietary suitability, or neighborhood membership.",
                               "Only overview review excerpts collected; not all reviews or complete review text.",
                               "Photo captions are existing source labels, not newly generated vision descriptions.",
                               "Photo URLs are remote references; image bytes were not downloaded or visually checked.",
                               "Neighborhoods use the source plus-code locality label, not official boundary geometry.",
                               "Area priority uses named neighborhoods, not distance from the user's location.",
                               "Prices, ratings, and review counts are snapshots, not live values.",
                               "Jev reranking is not implemented or evaluated in this dataset preparation."]}
    assert len({r["restaurant_id"] for r in restaurants}) == len(restaurants)
    assert len({r["evidence_id"] for r in evidence}) == len(evidence)
    assert all(r["address"] for r in restaurants)
    assert all(r["city"] == "San Francisco" and r["google_place_id"] for r in restaurants)
    assert all(r["latitude"] is not None and r["longitude"] is not None for r in restaurants)
    assert all(r["rating"] is not None and r["category"] for r in restaurants)
    assert all(e["restaurant_id"] in {r["restaurant_id"] for r in restaurants} for e in evidence)
    (DATA / "maps-demo.json").write_text(json.dumps({"summary": summary, "restaurants": restaurants}, indent=2, ensure_ascii=False) + "\n")
    (DATA / "maps-evidence.json").write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n")
    (DATA / "maps-collection-summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    focus = [r for r in restaurants if r["area_priority"] == "focus"]
    nearby = [r for r in restaurants if r["area_priority"] in {"focus", "nearby"}]
    for filename, selected in [("maps-focus-demo.json", focus), ("maps-nearby-demo.json", nearby)]:
        selected_ids = {r["restaurant_id"] for r in selected}
        subset = {"summary": {
            "restaurants": len(selected),
            "review_excerpts": sum(len(r["reviews"]) for r in selected),
            "photo_references": sum(len(r["photos"]) for r in selected),
            "focus_neighborhoods": sorted(FOCUS_NEIGHBORHOODS),
            "nearby_neighborhoods": sorted(NEARBY_NEIGHBORHOODS) if filename == "maps-nearby-demo.json" else [],
            "membership_basis": "Google Maps source locality labels; not official boundaries or user-distance calculations",
        }, "restaurants": selected,
        "evidence": [e for e in evidence if e["restaurant_id"] in selected_ids]}
        (DATA / filename).write_text(json.dumps(subset, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

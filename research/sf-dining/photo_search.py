#!/usr/bin/env python3
"""Offline photo/review retrieval baseline. No model calls; Jev can rerank its evidence."""
import argparse
from collections import Counter, defaultdict
from contextlib import closing
import json
from pathlib import Path
import re
import sqlite3

from photo_schema import validate

ROOT = Path(__file__).parent
DATA = ROOT / "data"
DB = DATA / "photo-search.sqlite3"
STOP = set("a an the i want would like somewhere place places restaurant restaurants with and or for in of to near me please show find eat food".split())
ALIASES = {"kebab": ["kebab", "kabob", "kabab"], "kabob": ["kebab", "kabob", "kabab"]}
PHOTO_KINDS = {"photo_source_caption", "photo_vision_caption", "photo_ocr"}


def read_annotations(path=DATA / "photo-vision.jsonl"):
    records = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("status") == "completed":
                validate(row["extraction"])
                records[row["photo_id"]] = row
    return records


def build():
    restaurants = json.loads((DATA / "maps-demo.json").read_text())["restaurants"]
    base = json.loads((DATA / "maps-evidence.json").read_text())
    photos = {p["photo_id"]: p for r in restaurants for p in r["photos"]}
    annotations = read_annotations()
    evidence = []
    for item in base:
        row = dict(item)
        if row["kind"] == "photo_source_caption":
            row["photo_id"] = row["evidence_id"]
            row["image_inspected"] = False
        evidence.append(row)
    for pid, annotation in annotations.items():
        if pid not in photos:
            raise ValueError(f"Annotation references unknown photo {pid}")
        p = photos[pid]
        if annotation["restaurant_id"] != p["restaurant_id"] or annotation["photo_url"] != p["url"]:
            raise ValueError(f"Annotation source mismatch: {pid}")
        extracted = annotation["extraction"]
        if not extracted["use_for_search"]:
            continue
        common = {"restaurant_id": p["restaurant_id"], "photo_id": pid,
                  "photo_url": p["url"], "source_url": p["source_url"],
                  "author": p["author"], "source_review_id": p["source_review_id"],
                  "image_inspected": True, "human_verified": False,
                  "extraction_method": annotation["method"], "photo_type": extracted["photo_type"],
                  "uncertainties": extracted["uncertainties"], "processed_at": annotation["processed_at"]}
        text = ". ".join(dict.fromkeys(filter(None, [extracted["caption"], *extracted["visible_foods"], *extracted["visible_features"]])))
        if text:
            evidence.append({**common, "evidence_id": pid + ":vision", "kind": "photo_vision_caption", "text": text})
        if extracted["ocr_text"].strip():
            evidence.append({**common, "evidence_id": pid + ":ocr", "kind": "photo_ocr", "text": extracted["ocr_text"],
                             "ocr_engine": annotation.get("ocr_processing", {}).get("ocr_engine", annotation["method"])})
    ids = [e["evidence_id"] for e in evidence]
    assert len(ids) == len(set(ids)), "Duplicate evidence IDs"
    tmp = DB.with_suffix(".tmp.sqlite3")
    tmp.unlink(missing_ok=True)
    with closing(sqlite3.connect(tmp)) as con, con:
        con.executescript("""
          CREATE TABLE restaurants (id TEXT PRIMARY KEY, name TEXT, area TEXT, data TEXT NOT NULL);
          CREATE TABLE evidence (id TEXT PRIMARY KEY, restaurant_id TEXT NOT NULL, kind TEXT NOT NULL, data TEXT NOT NULL);
          CREATE VIRTUAL TABLE evidence_fts USING fts5(evidence_id UNINDEXED, text, tokenize='porter unicode61 remove_diacritics 2');
        """)
        con.executemany("INSERT INTO restaurants VALUES (?,?,?,?)",
                        [(r["restaurant_id"], r["name"], r["area_priority"], json.dumps(r, ensure_ascii=False)) for r in restaurants])
        con.executemany("INSERT INTO evidence VALUES (?,?,?,?)",
                        [(e["evidence_id"], e["restaurant_id"], e["kind"], json.dumps(e, ensure_ascii=False)) for e in evidence])
        con.executemany("INSERT INTO evidence_fts VALUES (?,?)", [(e["evidence_id"], e["text"]) for e in evidence])
    tmp.replace(DB)
    (DATA / "search-evidence.jsonl").write_text("".join(json.dumps(e, ensure_ascii=False) + "\n" for e in evidence))
    # The job queue includes already-captioned photos because vision can still improve them.
    queue = [{"photo_id": p["photo_id"], "restaurant_id": r["restaurant_id"], "restaurant_name": r["name"],
              "area_priority": r["area_priority"], "photo_url": p["url"], "source_url": p["source_url"],
              "has_source_caption": bool(p["caption"]),
              "status": "completed" if p["photo_id"] in annotations else "pending"}
             for r in restaurants for p in r["photos"]]
    queue.sort(key=lambda p: ({"focus": 0, "nearby": 1, "other_sf": 2}[p["area_priority"]], p["has_source_caption"], p["photo_id"]))
    (DATA / "photo-vision-queue.jsonl").write_text("".join(json.dumps(p, ensure_ascii=False) + "\n" for p in queue))
    summary = {"restaurants": len(restaurants), "indexed_evidence": len(evidence), "evidence_kinds": dict(Counter(e["kind"] for e in evidence)),
               "photos_total": len(photos), "vision_completed": len(annotations),
               "vision_useful": sum(a["extraction"]["use_for_search"] for a in annotations.values()),
               "pending_uncaptioned": sum(not q["has_source_caption"] and q["status"] == "pending" for q in queue),
               "pending_uncaptioned_by_area": dict(Counter(q["area_priority"] for q in queue
                                                          if not q["has_source_caption"] and q["status"] == "pending")),
               "pending_vision_all": sum(q["status"] == "pending" for q in queue),
               "engine": "SQLite FTS5 lexical baseline; not Jev or semantic embeddings",
               "default_scope": "nearby"}
    (DATA / "photo-search-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def search(query, scope="nearby", limit=10, photos_only=False, prefix_last=False):
    if scope not in {"focus", "nearby", "all"}:
        raise ValueError("Invalid scope")
    terms = list(dict.fromkeys(t for t in re.findall(r"\w+", query.lower()[:300]) if t not in STOP))[:16]
    if not terms:
        return []
    # Quote user tokens; never interpolate user input as FTS operators or SQL.
    term_expressions = {t: " OR ".join('"' + v.replace('"', '""') + '"' +
                         ('*' if prefix_last and t == terms[-1] and len(t) >= 3 else '')
                         for v in ALIASES.get(t, [t])) for t in terms}
    expression = " OR ".join(f"({expr})" for expr in term_expressions.values())
    areas = {"focus": ["focus"], "nearby": ["focus", "nearby"], "all": ["focus", "nearby", "other_sf"]}[scope]
    photo_filter = " AND e.kind IN ('photo_source_caption','photo_vision_caption','photo_ocr')" if photos_only else ""
    sql = f"""SELECT r.data, e.data, bm25(evidence_fts) FROM evidence_fts
        JOIN evidence e ON e.id=evidence_fts.evidence_id JOIN restaurants r ON r.id=e.restaurant_id
        WHERE evidence_fts MATCH ? AND r.area IN ({','.join('?' for _ in areas)}) {photo_filter}
        ORDER BY bm25(evidence_fts)"""
    with closing(sqlite3.connect(f"file:{DB}?mode=ro", uri=True)) as con:
        hits = con.execute(sql, [expression, *areas]).fetchall()
        matched_terms = defaultdict(set)
        for term, expr in term_expressions.items():
            for (eid,) in con.execute("SELECT evidence_id FROM evidence_fts WHERE evidence_fts MATCH ?", [expr]):
                matched_terms[eid].add(term)
    grouped = {}
    for raw_restaurant, raw_evidence, bm25 in hits:
        r, e = json.loads(raw_restaurant), json.loads(raw_evidence)
        e["matched_query_terms"] = sorted(matched_terms[e["evidence_id"]])
        rid = r["restaurant_id"]
        if rid not in grouped:
            grouped[rid] = {"restaurant_id": rid, "name": r["name"], "neighborhood": r["neighborhood"],
                            "area_priority": r["area_priority"], "source_url": r["source_url"], "hits": []}
        weight = .65 if e["kind"] == "restaurant_metadata" else (1.15 if e["kind"] in PHOTO_KINDS else 1.0)
        grouped[rid]["hits"].append((max(0, -bm25) * weight, e))
    output = []
    for r in grouped.values():
        hits = sorted(r.pop("hits"), key=lambda h: h[0], reverse=True)
        # A caption and OCR from one image count as one source, with bounded corroboration.
        sources = {}
        for score, e in hits:
            key = e.get("photo_id") or e.get("source_review_id") or e["evidence_id"]
            sources.setdefault(key, score)
        scores = sorted(sources.values(), reverse=True)
        covered = set().union(*(matched_terms[e["evidence_id"]] for _, e in hits))
        r["matched_query_terms"] = [t for t in terms if t in covered]
        r["query_coverage"] = len(covered) / len(terms)
        r["match_type"] = "all_terms" if len(covered) == len(terms) else "partial"
        r["score"] = round(sum(s * w for s, w in zip(scores[:3], [1, .2, .1])), 6)
        r["matched_sources"] = len(sources)
        r["matched_evidence"] = [e for _, e in hits[:6]]
        matched_photos = {}
        for _, e in hits:
            if e.get("photo_url"):
                matched_photos.setdefault(e["photo_id"], {"photo_id": e["photo_id"], "url": e["photo_url"],
                    "match_text": e["text"], "evidence_kind": e["kind"], "source_url": e["source_url"],
                    "image_inspected": e.get("image_inspected", False), "uncertainties": e.get("uncertainties", [])})
        r["photos"] = list(matched_photos.values())[:4]
        output.append(r)
    return sorted(output, key=lambda r: (-r["query_coverage"], -r["score"], r["name"]))[:limit]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("build")
    query = sub.add_parser("search")
    query.add_argument("query")
    query.add_argument("--scope", choices=["focus", "nearby", "all"], default="nearby")
    query.add_argument("--limit", type=int, default=10)
    query.add_argument("--photos-only", action="store_true")
    query.add_argument("--prefix-last", action="store_true", help="Allow a partial final word for live typing")
    args = parser.parse_args()
    if args.command == "build":
        result = build()
    else:
        if not 1 <= args.limit <= 100:
            parser.error("limit must be between 1 and 100")
        result = search(args.query, args.scope, args.limit, args.photos_only, args.prefix_last)
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()

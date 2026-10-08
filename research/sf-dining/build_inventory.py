#!/usr/bin/env python3
"""Build readable Maps inventories from the normalized, geographically grouped data."""
import json
from pathlib import Path

ROOT = Path(__file__).parent


def cell(value):
    return str(value or "—").replace("|", "\\|").replace("\n", " ")


def main():
    datasets = [
        ("maps-demo.json", "inventory.md", "SF dining inventory — preferred areas first"),
        ("maps-focus-demo.json", "focus-inventory.md", "Castro, Mission, and Noe Valley inventory"),
        ("maps-nearby-demo.json", "nearby-inventory.md", "Castro, Mission, Noe Valley, and surrounding areas"),
    ]
    for source, filename, title in datasets:
        data = json.loads((ROOT / "data" / source).read_text())
        rows = data["restaurants"]
        reviews = sum(len(r["reviews"]) for r in rows)
        photos = sum(len(r["photos"]) for r in rows)
        captions = sum(bool(p["caption"]) for r in rows for p in r["photos"])
        lines = [
            f"# {title}", "", "Collected September 25, 2026 (Pacific time), through the public Maps interface.", "",
            f"**{len(rows)} places · {reviews:,} review excerpts · {photos:,} photo references · {captions:,} descriptive source labels.**", "",
            "Includes restaurants, cafes/delis, and food-serving bars. Neighborhoods are source locality labels; area priority is not a distance calculation from your location. Photo URLs are remote references, and descriptions are unverified source accessibility labels.", "",
            f"Structured data: [JSON](data/{source}).", "",
            "| Restaurant | Area priority | Source neighborhood | Source category | Reviews | Photos | Descriptive labels |",
            "| --- | --- | --- | --- | ---: | ---: | ---: |",
        ]
        for r in rows:
            name = cell(r["name"]).replace("[", "\\[").replace("]", "\\]")
            link = f"[{name}]({r['source_url']})"
            values = [link, r["area_priority"], cell(r["neighborhood"]), cell(r["category"]),
                      str(len(r["reviews"])), str(len(r["photos"])), str(sum(bool(p["caption"]) for p in r["photos"]))]
            lines.append("| " + " | ".join(values) + " |")
        (ROOT / filename).write_text("\n".join(lines) + "\n")
        print(f"{filename}: {len(rows)} places")


if __name__ == "__main__":
    main()

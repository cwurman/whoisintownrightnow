#!/usr/bin/env python3
"""Small, bounded public-website scrape for a local SF restaurant demo."""

from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
from io import BytesIO
import json
from pathlib import Path
import re
import time
from urllib.parse import urljoin, urlsplit, urlunsplit, unquote
from urllib.robotparser import RobotFileParser

from bs4 import BeautifulSoup
from pypdf import PdfReader
import requests

ROOT = Path(__file__).parent
DATA = ROOT / "data"
AGENT = "SFRestaurantDemoBot/0.1"
MAX_BYTES = 12_000_000
TARGETS = [
    ("sf-kebab", "SF Kebab", ["https://sfkebab.com/", "https://sfkebab.com/menu.html"]),
    ("beit-rima", "Beit Rima", ["https://beitrimasf.com/", "https://beitrimasf.com/menu/"]),
    ("dalida", "Dalida", ["https://www.dalidasf.com/"]),
    ("kitchen-istanbul", "Kitchen Istanbul", ["https://www.kitchenistanbulsf.com/", "https://www.kitchenistanbulsf.com/memories"]),
    ("souvla", "Souvla", ["https://www.souvla.com/", "https://www.souvla.com/menus/", "https://www.souvla.com/faq/"]),
    ("a-mano", "a Mano", ["https://www.amanosf.com/", "https://www.amanosf.com/menus/"]),
    ("foreign-cinema", "Foreign Cinema", ["https://foreigncinema.com/", "https://foreigncinema.com/menus/"]),
    ("good-good-culture-club", "Good Good Culture Club", ["https://goodgoodcultureclub.com/", "https://goodgoodcultureclub.com/pages/front-patio", "https://goodgoodcultureclub.com/pages/events-1"]),
    ("burma-superstar", "Burma Superstar", ["https://www.burmasuperstar.com/", "https://www.burmasuperstar.com/dinein-menu"]),
]


def tidy(value):
    return re.sub(r"\s+", " ", value or "").strip()


def identity(url):
    p = urlsplit(url)
    return urlunsplit((p.scheme, p.netloc, p.path, "", ""))


def short_id(text):
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def read_response(session, url):
    with session.get(url, timeout=25, stream=True) as response:
        response.raise_for_status()
        parts, length = [], 0
        for part in response.iter_content(65536):
            length += len(part)
            if length > MAX_BYTES:
                raise ValueError("Response exceeds the demo size limit")
            parts.append(part)
        return response.url, response.headers.get("Content-Type", ""), b"".join(parts)


def scrape(target):
    slug, name, seeds = target
    session = requests.Session()
    session.headers["User-Agent"] = AGENT
    robots = {}
    errors, pages, photos, documents = [], [], {}, {}

    def allowed(url):
        split = urlsplit(url)
        origin = f"{split.scheme}://{split.netloc}"
        if origin not in robots:
            rp = RobotFileParser(origin + "/robots.txt")
            try:
                response = session.get(rp.url, timeout=12)
                if response.status_code == 404:
                    rp.parse([])
                elif response.status_code == 200:
                    rp.parse(response.text.splitlines())
                else:
                    errors.append({"url": rp.url, "error": f"robots_unavailable_{response.status_code}"})
                    robots[origin] = None
                    return False
            except requests.RequestException as exc:
                errors.append({"url": rp.url, "error": type(exc).__name__})
                robots[origin] = None
                return False
            robots[origin] = rp
        rp = robots[origin]
        return rp is not None and rp.can_fetch(AGENT, url)

    def add_photo(raw_url, page_url, alt="", context="", discovery="img"):
        url = urljoin(page_url, (raw_url or "").strip())
        if not url.startswith("https://"):
            return
        parts = urlsplit(url)
        if re.search(r"\.(svg|gif|ico)$", parts.path, re.I):
            return
        if any(token in (parts.path + " " + alt).lower() for token in ["logo", "favicon", "spacer", "tracking", "pixel", "loading"]):
            return
        key = identity(url)
        photo = photos.setdefault(key, {
            "photo_id": slug + ":photo:" + short_id(key), "url": url,
            "source_pages": [], "alt_text": [], "page_context": [],
            "discovery": [], "visual_description": None,
            "dish_identity_verified": False, "source_type": "restaurant_website",
        })
        for field, value in [("source_pages", page_url), ("alt_text", tidy(alt)), ("page_context", tidy(context)[:350]), ("discovery", discovery)]:
            if value and value not in photo[field]:
                photo[field].append(value)

    for requested_url in seeds:
        if not allowed(requested_url):
            errors.append({"url": requested_url, "error": "robots_disallowed_or_unavailable"})
            continue
        try:
            actual_url, content_type, body = read_response(session, requested_url)
            soup = BeautifulSoup(body, "html.parser")
            title = tidy(soup.title.get_text()) if soup.title else name
            links = []
            for a in soup.select("a[href]"):
                href = urljoin(actual_url, a["href"])
                label = tidy(a.get_text(" "))
                if urlsplit(href).scheme not in ("https", "http"):
                    continue
                if any(word in (href + " " + label).lower() for word in ["menu", "patio", "gallery", "location", "contact", "about", "memories"]):
                    links.append({"url": href, "label": label})
                if ".pdf" in urlsplit(href).path.lower():
                    documents.setdefault(href, {"label": label, "linked_from": actual_url})
            for img in soup.find_all("img"):
                raw = img.get("data-src") or img.get("data-lazy-src") or img.get("src")
                if not raw or raw.startswith("data:"):
                    srcset = img.get("data-srcset") or img.get("srcset") or ""
                    if srcset:
                        raw = srcset.split(",")[-1].strip().split()[0]
                figure = img.find_parent("figure")
                caption = figure.find("figcaption") if figure else None
                add_photo(raw, actual_url, img.get("alt", ""), caption.get_text(" ") if caption else "")
            for node in soup.select("[style]"):
                for raw in re.findall(r"url\(['\"]?([^)'\"]+)", node["style"]):
                    add_photo(raw, actual_url, discovery="background")
            for node in soup.select('meta[property="og:image"]'):
                add_photo(node.get("content"), actual_url, discovery="og:image")
            for tag in soup.select("script,style,noscript,svg,nav,header,form"):
                tag.decompose()
            text = "\n".join(line for line in (tidy(x) for x in soup.get_text("\n").splitlines()) if line)
            pages.append({
                "page_id": slug + ":page:" + short_id(actual_url), "url": actual_url,
                "title": title, "text": text, "links": links,
                "content_sha256": hashlib.sha256(body).hexdigest(),
                "source_type": "restaurant_website", "content_type": content_type,
            })
        except Exception as exc:
            errors.append({"url": requested_url, "error": f"{type(exc).__name__}: {str(exc)[:180]}"})
        time.sleep(0.3)

    def menu_priority(item):
        url, meta = item
        words = (unquote(url) + " " + meta["label"]).lower()
        bad = any(word in words for word in ["wine", "spirit", "drink", "beverage", "allergen", "nutrition", "press", "catering", "dessert", "children"])
        good = any(word in words for word in ["food", "dinner", "main", "dinein", "menu"])
        return (bad, not good, url)

    pdfs = []
    for url, meta in sorted(documents.items(), key=menu_priority):
        if len(pdfs) >= 2 or menu_priority((url, meta))[0]:
            continue
        if not allowed(url):
            errors.append({"url": url, "error": "robots_disallowed_or_unavailable"})
            continue
        try:
            actual_url, _, body = read_response(session, url)
            reader = PdfReader(BytesIO(body))
            if len(reader.pages) > 8:
                raise ValueError("PDF exceeds demo page limit")
            pdf_id = slug + "-" + short_id(actual_url)
            path = ROOT / "raw-menus" / (pdf_id + ".pdf")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(body)
            text = "\n\n".join(page.extract_text(extraction_mode="layout") or "" for page in reader.pages)
            pdfs.append({"document_id": pdf_id, "url": actual_url, **meta,
                         "text": text, "page_count": len(reader.pages),
                         "local_path": str(path.relative_to(ROOT)),
                         "source_type": "restaurant_website_menu"})
        except Exception as exc:
            errors.append({"url": url, "error": f"{type(exc).__name__}: {str(exc)[:180]}"})
        time.sleep(0.3)

    return {"restaurant_id": slug, "name": name, "city_context": "San Francisco",
            "scope_note": "Website-level record; shared brand menus and branch-specific facts require explicit location matching.",
            "retrieved_at": datetime.now(timezone.utc).isoformat(),
            "pages": pages, "menu_documents": pdfs, "photos": list(photos.values()),
            "customer_reviews": [], "errors": errors}


def main():
    DATA.mkdir(parents=True, exist_ok=True)
    records = []
    with ThreadPoolExecutor(max_workers=3) as pool:
        tasks = {pool.submit(scrape, target): target[1] for target in TARGETS}
        for task in as_completed(tasks):
            result = task.result()
            records.append(result)
            print(json.dumps({"name": result["name"], "pages": len(result["pages"]),
                              "pdfs": len(result["menu_documents"]), "photos": len(result["photos"]),
                              "errors": result["errors"]}), flush=True)
    records.sort(key=lambda r: r["restaurant_id"])
    (DATA / "scraped-restaurants.json").write_text(json.dumps(records, indent=2, ensure_ascii=False) + "\n")
    summary = {"restaurants_attempted": len(records),
               "restaurants_with_content": sum(bool(r["pages"] or r["menu_documents"]) for r in records),
               "html_pages": sum(len(r["pages"]) for r in records),
               "menu_pdfs": sum(len(r["menu_documents"]) for r in records),
               "photo_urls": sum(len(r["photos"]) for r in records),
               "customer_reviews": 0,
               "note": "Photo URLs are discovered candidates, not yet visually classified or verified as food photos. No paid service used."}
    (DATA / "scrape-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

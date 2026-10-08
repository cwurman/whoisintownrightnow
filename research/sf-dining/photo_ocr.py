"""Use local OCR for menus; never index generated scene descriptions as OCR."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urlparse
from urllib.request import urlopen

ROOT = Path(__file__).parent
BINARY = ROOT / ".bin" / "menu-ocr"
CACHE = ROOT / "photo-cache"


def apply_ocr_policy(extraction, photo):
    value = deepcopy(extraction)
    model_text = value["ocr_text"]
    value["ocr_text"] = ""
    details = {"model_ocr_text": model_text, "ocr_status": "not_a_menu"}
    if value["photo_type"] != "menu" or not value["use_for_search"]:
        return value, details
    if not BINARY.exists():
        details["ocr_status"] = "local_engine_unavailable"
        return value, details
    try:
        url = photo["photo_url"]
        if urlparse(url).hostname != "lh3.googleusercontent.com":
            raise ValueError("Unsupported menu photo host")
        # Ask the same public image host for a larger rendition for small menu text.
        url = re.sub(r"=w\d+-h\d+.*$", "=w1600-h1200-p-k-no", url)
        CACHE.mkdir(exist_ok=True)
        target = CACHE / (hashlib.sha256(url.encode()).hexdigest()[:24] + ".jpg")
        if not target.exists():
            with urlopen(url, timeout=20) as response:
                content = response.read(10_000_001)
            if len(content) > 10_000_000:
                raise ValueError("Image exceeds the menu OCR size bound")
            target.write_bytes(content)
        result = subprocess.run([str(BINARY), str(target)], capture_output=True, text=True, timeout=30, check=True)
        ocr = json.loads(result.stdout)
        value["ocr_text"] = ocr["text"][:12000].strip()
        if value["ocr_text"]:
            value["uncertainties"].append("Automatic OCR may misread small or handwritten text; menu items and prices may be outdated.")
        details.update(ocr_status="completed", ocr_engine=ocr["engine"], ocr_lines=ocr["lines"],
                       ocr_image_url=url, ocr_image_sha256=hashlib.sha256(target.read_bytes()).hexdigest())
    except Exception as error:
        details.update(ocr_status="failed", ocr_error=type(error).__name__)
    return value, details

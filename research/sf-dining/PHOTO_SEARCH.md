# Search evidence from restaurant photos

Restaurant photos are converted into text during ingestion, then searched alongside metadata and customer review excerpts. Each piece of evidence retains its restaurant, original photo URL, and source review relationship so the UI can display the exact matching photo.

| Source | Searchable content | How it is produced |
| --- | --- | --- |
| Existing caption | 1,652 descriptive source labels | Preserved Google Maps accessibility text; not independently verified |
| Vision description | Visible dishes, seating, lighting, and decor | GPT-5 nano, plus the original eight-image assistant pilot |
| Menu OCR | Words in photographed menus | Local Apple Vision on larger image renditions; the original Canela pilot uses an assistant transcription |

The collection contains 3,373 distinct photo references for 500 SF dining places. The processing run fills missing descriptions first, ordered by Castro/Mission/Noe, surrounding neighborhoods, then other SF. Existing descriptive captions are reused to avoid unnecessary API spending. Not every image is useful: storage shots, selfies, unreadable images, or fully wrapped parcels can be excluded.

**Current counts and estimated cost:** [photo-processing-status.json](data/photo-processing-status.json). **Indexed evidence counts:** [photo-search-summary.json](data/photo-search-summary.json). These reports distinguish existing captions, analyzed photos, excluded images, and pending work.

## Try the search

From the repository root:

```sh
python3 research/sf-dining/photo_search.py build
python3 research/sf-dining/photo_search.py search "shishito peppers" --photos-only
python3 research/sf-dining/photo_search.py search "mint green" --scope focus --photos-only
python3 research/sf-dining/photo_search.py search "keb" --prefix-last --photos-only
```

The initial verified examples include Canela's tapas menu for “shishito peppers,” La Vaca Birria's dining-room photo for “mint green,” and Fable's seating-area photo for “dog patio.” A dog in a photo does not establish a pet policy, and a menu photo does not establish current availability. The original pilot images and hashes are in `photo-pilot/manifest.json`; additional checked samples are in `photo-qa/`.

`focus` selects the source neighborhood labels Castro, Mission District, Mission Dolores, and Noe Valley. `nearby`, the default, adds the surrounding groups. `all` includes all 500 restaurants. These groups express neighborhood preference; they are not distances from the user's home. Canela's source label is Duboce Triangle, which belongs to the nearby group.

The local baseline uses SQLite FTS5. Restaurants covering every query term rank ahead of partial matches, followed by weighted relevance. Reviews and photo evidence receive more weight than general metadata. Up to three distinct sources contribute with diminishing weights; a caption and OCR from one photo count as one source. `--prefix-last` allows an unfinished last word. Full-token search avoids treating “peppers” as a prefix of “pepperoni.”

This stage is lexical retrieval. `all_terms` describes word coverage, potentially across several records; it does not prove that all requested conditions hold. Negation, dietary requirements, and compound intent need further evaluation.

## Jev is connected

[JEV_SEARCH.md](JEV_SEARCH.md) documents the live TypeSafe integration. It reranks retrieved candidates, chooses a presentation such as compact rows or dish photos, and selects a matching photo from each result's existing photo IDs.

```sh
python3 research/sf-dining/jev_search.py "kebab" --scope nearby
python3 research/sf-dining/jev_search.py "mediterranean food"
python3 research/sf-dining/jev_search.py "mint green"
```

Jev receives text evidence, not image pixels. The returned widget choices are ready for a future interface to consume. A search service and app UI have not yet been built.

## Model and cost

The user requested the cheapest OpenAI model for this task. The worker uses **GPT-5 nano** with minimal reasoning and a maximum of 1,800 output tokens per image. Its published standard rates are $0.05 per million input tokens, $0.005 per million cached input tokens, and $0.40 per million output tokens. It supports image inputs and structured output. [Model documentation and pricing](https://developers.openai.com/api/docs/models/gpt-5-nano)

The initial live sample exposed two problems: some usable food images were rejected, and scene descriptions sometimes appeared in the OCR field. The prompt now explicitly allows recognizable food even without an exact dish name. Generated OCR is discarded; only native OCR from images classified as menus is indexed. Four pilot records were corrected after direct assistant visual inspection. All annotations remain non-human-verified.

The model produces concise descriptions and records uncertainty about exact dishes or ingredients. It is imperfect: visual descriptions can still misidentify foods, and OCR can misread handwriting or small print. Do not turn appearance into guarantees about ingredients, allergens, noise, pet policies, or current availability. Raw generated OCR is retained separately for auditing and excluded from search.

Costs are calculated from returned API token usage, not from a billing invoice. Successful response IDs are deduplicated so postprocessing does not double-count charges. Requests without returned usage cannot be priced locally. Local Apple Vision OCR adds no API charge.

## Reproduce or resume processing

The API worker reads `OPENAI_API_KEY`, falling back to the owner-only local file `~/.config/sf-dining/openai-api-key`. The supplied credential is stored outside the repository. TypeSafe uses a separate protected file and environment variable, as documented in JEV_SEARCH.md.

Compile the local menu OCR utility on macOS:

```sh
mkdir -p research/sf-dining/.bin
xcrun swiftc research/sf-dining/menu_ocr.swift -o research/sf-dining/.bin/menu-ocr
```

Preview the pending queue, then run a bounded batch:

```sh
python3 research/sf-dining/extract_photo_text.py --model gpt-5-nano --scope nearby --limit 10 --dry-run
python3 research/sf-dining/extract_photo_text.py --model gpt-5-nano --scope nearby --limit 1000 --workers 6
python3 research/sf-dining/photo_search.py build
python3 research/sf-dining/photo_status.py
```

Completed photos are skipped. The default selection includes only images without a useful source caption. `--scope all` includes the remaining SF records; `--all-photos` explicitly includes already-captioned photos. `--limit` caps requests per run. Up to eight concurrent workers are supported, with request starts paced at 140/min by default. A process lock prevents two workers from processing the queue simultaneously.

Only explicit `rate_limit_exceeded` HTTP 429 rejections are retried automatically, with bounded backoff. Timeouts, incomplete responses, and other errors stop new submissions; already-running requests finish and save their results. Inspect `data/photo-vision-attempts.jsonl` before using `--retry-attempted`, which can resubmit uncertain requests and incur another charge. Successful records are flushed to `data/photo-vision.jsonl` immediately.

Menu OCR requests a larger rendition of the same public Google-hosted image, saves it under `photo-cache/`, and records the rendition URL, file hash, OCR engine, and recognized lines. Without the compiled native utility, menu OCR is explicitly marked unavailable and omitted; generated OCR is not used as a fallback. Most non-menu photos remain remote references rather than local downloads.

The image worker uses the Responses API's [image input](https://developers.openai.com/api/docs/guides/images-vision) and [structured output](https://developers.openai.com/api/docs/guides/structured-outputs) formats. It sends only the extraction prompt and public photo URL, with `store: false`; restaurant names and reviews are not supplied for guessing image contents.

## Files and validation

- `data/photo-vision.jsonl`: append-only extraction and postprocessing records; the latest completed record for each photo is used.
- `data/photo-vision-attempts.jsonl`: request lifecycle, failures, response IDs, and returned token usage.
- `data/search-evidence.jsonl`: combined evidence export for search and Jev.
- `data/photo-search.sqlite3`: local FTS5 search index.
- `data/photo-vision-queue.jsonl`: saved job queue; live annotations determine what is already complete.
- `data/photo-processing-status.json`: processing coverage and cost estimate.

Run regression checks against the current index:

```sh
python3 -m unittest discover -s research/sf-dining -p 'test_*.py' -v
```

The checks cover OCR and scene retrieval, uncertainty preservation, neighborhood filtering, excluded images, safe query parsing, source deduplication, structured API response handling, resume behavior, uncertain failures, native OCR substitution, and Jev's photo/layout choices. Mocked API tests do not consume credits. Live examples are separately saved as evidence of actual API integration.

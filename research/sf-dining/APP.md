# Supper: local restaurant search

Run from the repository root with Python 3 (no package installation or frontend build required):

```sh
python3 research/sf-dining/server.py --port 8787
```

Open [localhost:8787](http://localhost:8787). The server binds only to `127.0.0.1`. Stop it with Ctrl-C.

## Working features

- Live search across the collected metadata, review excerpts, photo descriptions, and menu OCR. Defaults to the 273 nearby places; neighborhood filters cover Castro, Mission/Mission Dolores, and Noe Valley. The area selector can search the full 500-place dataset.
- Independent food/drink galleries, space galleries, menu image + OCR panels, and customer review widgets. Multiple types can appear in one row when query intent and source evidence support them. Broad cuisine searches stay compact.
- Auto, list, food, space, menu, and review views. Manual choices remain active through small edits and release after a substantial change to the query.
- Restaurant details, matching evidence, full photo viewer, original source links, websites, phone links, and Google Maps links.
- Saved places persist in this browser and synchronize across tabs. The saved view respects the active search and geographic filters.
- Sorting by recommendation or collected Google rating; progressive display in groups of 12; responsive layout; keyboard search shortcut `/`; accessible native dialogs; reduced-motion support.

## How it works

`server.py` serves an explicit static-file allowlist and four endpoints: catalog, local search, restaurant details, and Jev reranking. It does not expose the research directory, credentials, or arbitrary local files. Paid inference accepts only same-origin requests to the loopback host.

`web_search.py` adapts the original dataset and SQLite search into a shared widget contract. Search terms retrieve candidates locally, with a small synonym expansion. Each restaurant contains source-backed modules; automatic modules only use matching evidence. Manual views can browse other collected photos and reviews. Photo groups use extraction types where present, and caption rules for older source-caption records.

One Jev request asks independent show/hide questions for the four widget types, relevance scores for the first 10 candidates, and photo choices within each candidate's available modules. Criteria are explicit per question. No generated components, invented restaurant facts, or cross-restaurant photo selections are accepted. The remaining candidates preserve local ordering. Rating sort is never overridden by relevance scores.

Jev has a 3-second timeout with no retry, two concurrent call slots, and a 150-entry server response cache, in addition to the existing validated request cache on disk. Failures return the same local result shape. The TypeSafe key remains in the existing protected file outside the repository. Search does not make new OpenAI image-processing calls.

`web/app.js` retrieves local matches after 140 ms, then waits a further 260 ms before requesting Jev. Every new input immediately invalidates the old request sequence and aborts its browser request. Only the newest response may update the screen. A 24-entry browser cache includes query, area, neighborhoods, and sort in its key. Abort protects browser state; a server call already dispatched may finish and populate the cache.

`web/state.js` retains each automatic widget in a confidence dead band. A strong signal changes it immediately; moderate signals must agree across two distinct query texts. A manual view remains pinned until normalized edit distance exceeds 30%. Empty queries reset automatic widgets. These are demo thresholds, not calibrated probability guarantees. The UI registry is ordinary code, and restaurant DOM nodes retain stable restaurant IDs.

## Verification

```sh
python3 -m unittest discover -s research/sf-dining -p 'test_*.py' -v
node --test research/sf-dining/web/state.test.mjs
```

25 Python checks cover the original pipeline plus geographic filters, menu evidence, source ownership, candidate/photo validation, consistent timeout fallback, ranking, cache isolation, and malformed input. Five JavaScript checks cover combined widgets, transition stability, manual overrides, empty queries, and cache keys/eviction. Tests use fixtures and make no paid API calls.

Live Jev requests and browser interaction were also exercised for dish, broad cuisine, decor, menu, and review queries. Source photo availability still depends on Google-hosted URLs; unavailable images display a placeholder. The corpus is a September 2026 sample with three review excerpts per restaurant and machine-generated photo descriptions, not live menus/hours or verified dietary guidance. Compound matching remains limited by the collected evidence and lexical candidate retrieval.

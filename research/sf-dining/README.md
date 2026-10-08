# SF restaurant search demo: data collection

## Run the app

The [Supper interface](APP.md) is built and connected to this dataset and live Jev. Run `python3 research/sf-dining/server.py --port 8787` from the repository root, then open [localhost:8787](http://localhost:8787).

Research and live collection: September 25, 2026 (Pacific time).

The public-browser collection now contains **500 distinct SF dining places**, using the same rendered Google Maps interface throughout. It includes restaurants, cafes/delis, and food-serving bars. No API key or paid extraction service was needed. The user subsequently prioritized Castro, Mission, and Noe Valley: the full dataset is ordered by area priority, and two smaller geographic views are exported for the demo.

## Collected now

- `data/maps-focus-demo.json`: **192 places** labeled The Castro, Mission District, Mission Dolores, or Noe Valley. Includes restaurant records and their searchable evidence.
- `data/maps-nearby-demo.json`: **273 places**, adding 81 in named surrounding areas such as Dolores Heights, Duboce Triangle, Bernal Heights, Glen Park, Cole Valley, Lower Haight, and Potrero Hill. The exact area list is in the file's summary.
- `data/maps-demo.json`: **500** normalized records, **1,500** review excerpts, and **3,373** distinct review-photo references. Records include addresses, coordinates, source neighborhood labels, categories, ratings, price displays where present, contact fields, and collection timestamps. `area_priority` is `focus`, `nearby`, or `other_sf`; records are sorted in that order.
- `data/maps-evidence.json`: **3,652** searchable records: 500 restaurant metadata records, 1,500 customer review excerpts, and 1,652 descriptive photo labels. Every record links back to its restaurant and source.
- `data/maps-collection-summary.json`: verified totals, category and neighborhood distributions, and limitations.
- `inventory.md`, `focus-inventory.md`, `nearby-inventory.md`: human-readable inventories with source links and review/photo counts.
- `data/maps-validation-report.json`: final identity, geography, evidence-linking, closure, and completeness checks.
- `data/google-maps-searches.json`: 110 saved search batches covering 104 distinct queries and 739 listing appearances. Includes retries; appearances are not unique restaurants.
- `data/google-maps-details.json`: raw rendered place-page content, review excerpts, accessibility labels, and photo references for all 500 retained places.
- `data/google-maps-public-sample.json`: preserved initial six-listing Mediterranean discovery export; its listing-stage review count is historical, not the current collection total.
- `data/google-maps-collection-errors.json`: historical failed attempts and rejected search results. Several selector failures were recovered later; this is an attempt log, not a list of missing final records.
- `data/google-maps-excluded-details.json`: 11 fully collected records held out for non-dining scope, weak meal evidence, a temporary closure, or ambiguous co-located identities. They do not contribute to the 500-place count.

The collection used the normal rendered Maps interface. The search page displayed a limited-view notice, but opening each place exposed its overview reviews and photo references. No account, paid API, private endpoint, or access-control workaround was used. This is a small, query-selected sample, not a complete review corpus. Existing Google photo accessibility labels are preserved with their origin; they have not been independently verified by a vision model. Review excerpts may be shortened. Google-generated review summaries are excluded from the normalized evidence.

Normalize the saved browser sample again with:

```sh
python3 research/sf-dining/prepare_maps_sample.py
```

## Current coverage and quality

The collection began citywide and shifted to cuisine and street-level searches around Castro, Mission, and Noe Valley after the user's direction. Search terms are preserved as discovery provenance; they do not establish a restaurant's actual neighborhood or dietary suitability. Place identity comes from the Maps place ID, and neighborhood labels come from the rendered plus-code field. Area groups are a browsing preference, not distances from the user's home or an official boundary analysis. The 500-place pool includes 227 places outside the focus/nearby groups.

All 500 records have an SF address, coordinates, a category, rating, review count, neighborhood label, and three overview review excerpts. There are 455 price displays, 457 websites, and 471 phone numbers. Review photos are available for 497 places; asu mare peruvian restaurant, MrBeast Burger, and Veg-O-licious have none in the collected overview. Generic photo labels, video thumbnails, and “+ N more photos” aggregate tiles are excluded from searchable photo captions. Image references are deduplicated after removing URL size suffixes.

Validation confirmed 500 distinct place IDs and street addresses, unique evidence IDs and photo URLs, source-name correspondence, SF addresses and coordinate bounds, required fields, photo-to-review relationships, and rating ranges. Source-marked temporary/permanent closures were screened out. These checks do not independently establish current operation, image contents, or review accuracy.

This remains a shallow review sample: three overview excerpts per place. A separate photo-processing pipeline now adds visual descriptions and menu OCR; its current coverage is recorded in `data/photo-processing-status.json`. Deeper reviews are still needed for stronger compound-query matching. Missing keywords do not establish that a restaurant lacks a dish or amenity.

## Photo text and local search

[Photo processing is complete](PROCESSING_COMPLETE.md): zero caption gaps across 3,373 photo references, 3,368 searchable photo descriptions, five exclusions, and 99 menu OCR records. Estimated OpenAI processing cost was $0.1931 using GPT-5 nano.

[PHOTO_SEARCH.md](PHOTO_SEARCH.md) documents the working photo-text search and resumable extraction pipeline. `photo_search.py` indexes the 1,652 existing source captions plus new visual descriptions and menu OCR alongside metadata and reviews. `data/search-evidence.jsonl` is the combined export; `data/photo-search-summary.json` records current indexed counts. The original Maps exports remain unchanged.

The original eight-image assistant pilot is preserved in `photo-pilot/`. Live bulk processing uses GPT-5 nano with minimal reasoning, following the user's request for the cheapest OpenAI model. Local Apple Vision performs menu OCR on larger renditions without another API charge. `data/photo-vision.jsonl` retains extraction methods, uncertainty, API usage, and OCR provenance. Annotations remain non-human-verified. Credentials are configured in protected files outside the repository.

[JEV_SEARCH.md](JEV_SEARCH.md) documents the original live TypeSafe CLI integration. The [app](APP.md) extends it with independently selectable photo, menu, and review widgets, stable live typing, and a local HTTP server.

## Continuing the same browser collection

1. Use the visible Google Maps search box for a focused SF cuisine, dish, setting, or area query.
2. Read rendered result articles; save their place links, source text, rating labels, and whether the listing is sponsored.
3. Skip place IDs already collected, then open each remaining visible result link. Wait for the correct place heading and overview review elements to load.
4. Save rendered overview text, labeled address/contact fields, customer review text, review IDs/authors, and review-photo button labels/URLs. Persist each completed restaurant immediately.
5. Normalize the saved exports with the command above. Generated Maps review summaries and sponsored copy are not included as customer-review evidence. Sponsored discovery appearances remain flagged as provenance.

`maps-browser-collector.mjs` exports `createMapsBatch`, taking an existing documented Browser tab, saved arrays, filesystem handle, output callback, and target count. It searches through the visible UI, follows observed place links, reads rendered DOM, and saves each completed record. The caller must initialize the documented Browser runtime and inspect unexpected UI changes; direct-to-place search results need separate handling. Use short query batches to avoid execution timeouts. The normalizer runs offline against saved exports, and `build_inventory.py` regenerates the three readable inventories.

## Optional API expansion researched earlier

Outscraper exposes separate [listing](https://docs.outscraper.com/endpoints/google-maps-search/), [review](https://docs.outscraper.com/endpoints/google-maps-reviews/), and [photo](https://docs.outscraper.com/endpoints/google-maps-photos/) endpoints. Use an API key in the `X-API-KEY` header. No such key was present in this task's environment or root environment files. These endpoint requests have not been run.

| Stage | Endpoint | Bounded request |
| --- | --- | --- |
| Discover | `GET https://api.outscraper.com/google-maps-search` | Query SF restaurants by cuisine/neighborhood; set `limit`, `totalLimit`, and `dropDuplicates=true` explicitly. |
| Reviews | `GET https://api.outscraper.com/google-maps-reviews` | Query returned place IDs; `limit=1`, `reviewsLimit=25` for the initial test; `sort=most_relevant`. |
| Photos | `GET https://api.outscraper.com/google-maps-photos` | Query the same IDs; `limit=1`, `photosLimit=20`. |

Use asynchronous jobs and save returned job IDs before polling. Do not resubmit a job simply because it is still running. Never use `reviewsLimit=0`: that requests unlimited reviews. An initial batch of 20 restaurants, up to 25 reviews and 20 photos each, fits the published per-service free quantities if those allowances are unused. Exact address/coordinate checks should exclude results outside SF and distinguish branches.

Published [Outscraper pricing](https://outscraper.com/pricing/) lists the first 500 businesses, 500 reviews, and 500 images free in their respective tiers. The next tiers are $3/1,000 businesses, $3/1,000 reviews, and $2/1,000 images.

Illustrative collection estimates, assuming unused free allowances and no extra enrichments:

| Batch | Businesses | Reviews | Photo records | Estimated extraction charge |
| --- | ---: | ---: | ---: | ---: |
| Initial test | 20 | 500 | 400 | $0 |
| Broader demo | 100 | 5,000 | 2,000 | $16.50 |
| Deeper demo | 200 | 20,000 | 4,000 | $65.50 |

These are calculations from published tiers, not quotes or total project costs. They exclude image downloading/hosting, vision captioning, embeddings, Jev, refreshes, taxes, and any account/payment minimum. Record counts are caps, not guaranteed availability. No paid Outscraper requests were made. Actual OpenAI image-processing usage is reported separately in `data/photo-processing-status.json`.

## Other researched options

| Source | Relevant capabilities | Implication for this demo |
| --- | --- | --- |
| [Google Places API](https://developers.google.com/maps/documentation/places/web-service/reference/rest/v1/places) | Official place metadata; up to five reviews and ten photo references per place response. | Easy metadata integration with a key, but too small a sample for deep dish-level review retrieval. |
| [Yelp Places plans](https://docs.developer.yelp.com/docs/plans) | Premium lists up to seven review excerpts, twelve photos, and twenty daily AI API calls in early access. | Standard plans do not provide a complete review corpus. Account-specific access needs checking. |
| [Yelp AI API](https://docs.developer.yelp.com/docs/yelp-ai-api) | Query-contextual summaries, review snippets, photo references, and structured businesses. | A possible retrieval provider; latency and actual account limits were not benchmarked. |
| [Yelp Insights](https://docs.developer.yelp.com/docs/yelp-insights) | Partnership access to full review text (overview specifies latest 200), photos/captions, and food/drink insights through APIs or feeds. | Relevant if this becomes a product; commercial access and permitted uses depend on the agreement. |
| [SerpApi](https://serpapi.com/pricing) | Maps search, review, and photo endpoints; published Starter plan $25/month for 1,000 searches. | Viable alternative; request/page billing differs from per-record billing. |
| [Apify Maps scraper](https://apify.com/compass/crawler-google-places/pricing) | Listings plus optional reviews/photos and enrichments. | Another viable provider; price depends on plan and add-on events. |
| [Overture Places](https://docs.overturemaps.org/guides/places/) | Openly licensed place identities, coordinates, categories, and contact fields where present. | Useful for an independent restaurant roster, not a replacement for review/photo evidence. |

A scraper's extraction fee does not itself grant unrestricted publishing or permanent indexing rights. Google's [Maps Platform terms](https://cloud.google.com/maps-platform/terms) restrict scraping, storage, indexing, derived content, and changes to search results; [Yelp's Places FAQ](https://docs.developer.yelp.com/docs/places-faq) restricts caching and analysis. This demo investigation is not a conclusion that production use is cleared. If the project moves beyond a demo, resolve the specific storage, inference, and display permissions before committing to a supplier.

## Additional material already collected

Before the Maps-specific direction was chosen, two useful supplementary datasets were collected:

- `data/scraped-restaurants.json`: nine public SF restaurant websites, nineteen HTML pages, three linked menu PDFs, and 146 candidate image URLs. No customer reviews. `scrape_demo.py` reproduces the bounded crawl; inaccessible resources are recorded rather than bypassed. These are website-level records; do not assume a shared brand menu establishes facts for every branch.
- `data/sf-candidates.json`: 4,718 restaurant/takeout/bakery/bar-with-food permit candidates from [DataSF inspections](https://data.sfgov.org/d/tvy3-wexg), whose metadata lists PDDL. `build_seed.py` reproduces the extraction. The candidates contain 4,574 distinct normalized name/address pairs and need entity matching and current-operation checks. This is not a count of active SF restaurants. The underlying records include nonrestaurant facilities and anomalous dates; permit-type/date/location screening is recorded in `data/seed-summary.json`.

## Next implementation step

Use the [local app](APP.md) to evaluate cuisine, dish, atmosphere, and compound queries, defaulting to the nearby group. The next collection improvement is depth: recent and relevant reviews beyond the three overview excerpts. Image descriptions and OCR still need broader quality evaluation; current processing status distinguishes completed, excluded, and pending images.

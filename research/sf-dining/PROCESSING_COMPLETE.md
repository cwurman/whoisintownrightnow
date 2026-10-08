# Photo processing complete

As of 2026-09-26T03:42:44.286697+00:00.

All **3,373 collected photo references** are accounted for: **1,652 existing source captions** were reused, and **1,721 previously uncaptained photos** were analyzed. Of those analyses, eight came from the original assistant pilot and 1,713 from GPT-5 nano. **Five images were excluded** as unhelpful; **3,368 photo descriptions** are searchable. **99 menu OCR records** add text beyond those descriptions.

There are **zero remaining caption gaps**, including all **1,732 nearby photo references**. The nearby group has 1,727 searchable photo descriptions and five exclusions. Existing source captions were not independently re-analyzed; automated descriptions remain non-human-verified.

Estimated OpenAI image-processing cost: **$0.1931** (about 19 cents), calculated from returned token usage at published standard GPT-5 nano rates. This includes one incomplete response that was subsequently recovered. No unresolved requests remain. Local menu OCR adds no API charge. This is a usage-based estimate, not a billing invoice, and excludes separate TypeSafe calls.

The rebuilt search index contains **5,467 evidence records** across 500 restaurants. All **16 regression checks pass**. Additional validation confirmed every photo is linked to the right restaurant, every photo has a source caption or completed analysis, and generated scene descriptions are not indexed as menu OCR.

Jev reranking is live: tested queries choose compact rows for “Mediterranean food,” dish photos for “kebab,” and space photos for “mint green.” The [Supper app](APP.md) now connects these records to a working localhost interface with independent food, space, menu, and review widgets.

- [Search and image-processing instructions](PHOTO_SEARCH.md)
- [Jev integration](JEV_SEARCH.md)
- [Detailed processing status and usage](data/photo-processing-status.json)
- [Search index counts](data/photo-search-summary.json)

Most photos remain Google-hosted references. Downloaded files are the pilot/QA samples and larger menu images used for local OCR.

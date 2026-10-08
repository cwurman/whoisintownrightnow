# Jev restaurant reranking

`jev_search.py` now calls TypeSafe's live API after local candidate retrieval. It sends the search query, relevant review excerpts, metadata, photo descriptions, and menu OCR as text. It receives restaurant relevance scores and choices of UI widget and matching photo.

TypeSafe authentication was verified with a real API call. Three initial live examples are saved in `data/jev-kebab-example.json`, `data/jev-mediterranean-example.json`, and `data/jev-interior-example.json`:

| Query | Jev's presentation choice | Example behavior |
| --- | --- | --- |
| Mediterranean food | `compact` | Restaurant names and metadata |
| kebab | `dish_photos` | Selects relevant food photos for SF Grill and Delam; a result without a matching photo stays compact |
| mint green | `space_photos` | Selects La Vaca Birria's matching dining-room photo |

These files are snapshots against the evidence available when each command ran. They demonstrate integration, not a comprehensive ranking-quality benchmark. The [local Supper app](APP.md) is now built. Its `web_search.py` adapter uses independent widget decisions, while the CLI documented here retains its original single-presentation contract.

## Run

```sh
python3 research/sf-dining/jev_search.py "mediterranean food"
python3 research/sf-dining/jev_search.py "kebab" --scope nearby --candidates 10
python3 research/sf-dining/jev_search.py "mint green" --scope focus
```

`--dry-run` prints the text payload without a network request. `--output PATH` saves the result. The default model is the tested `jev-1.13.0`; `--model` can explicitly override it.

Credentials are read from `TYPESAFE_API_KEY`, or an owner-only local file at `~/.config/sf-dining/typesafe-api-key`. No credential is written into source files, request caches, or result exports. The key is sent only to the documented `https://api.typesafe.ai/v1/systemone` endpoint; redirects are refused.

## Behavior

The first stage uses the local lexical index to select at most 20 candidates (10 by default). A single Jev call then asks one relevance question per restaurant, one photo-selection question per restaurant with matching photos, and a presentation question for the query. Every candidate-specific question explicitly identifies its candidate in the supplied state.

Scores use an ordered four-level rubric from unsupported to direct evidence, returning values between 0 and 3. They are ranking values, not percentages of factual correctness. The script retains Jev's confidence and raw choices. The demo uses a 0.4 confidence threshold for photo and layout choices, falling back to compact rows below it; that threshold has not been calibrated against user judgments. Ranking uses the relevance score and retains lexical order on ties.

Photos can only be selected from the original candidate's photo IDs. An unknown choice or malformed response is rejected. Identical payloads use a cached validated result. Errors return the local lexical results with `status: lexical_fallback` and a nonzero process exit code. No automatic retry occurs for uncertain failures.

Jev's [state documentation](https://docs.typesafe.ai/concepts/state) explicitly supports text only. It does not inspect the photo pixels. Image descriptions come from OpenAI vision, source captions, or the initial assistant pilot; menu OCR comes from local Apple Vision or the initial pilot. The [TypeSafe API reference](https://docs.typesafe.ai/api) describes the Choice and Score request/answer formats used here.

Candidate recall remains limited by lexical retrieval. Jev cannot rerank a restaurant that the first stage did not retrieve, and it cannot fill gaps in the collected evidence. Dietary suitability, pet policies, noise levels, and current availability must not be inferred from photo appearance alone.

Run the mocked API contract and photo-selection checks with:

```sh
python3 -m unittest discover -s research/sf-dining -p 'test_*.py' -v
```

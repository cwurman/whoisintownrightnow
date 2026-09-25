# Candidate-based drafting beyond places

Exploration, September 25, 2026. These are recommendations, not implemented behavior or new product decisions. The existing implementation is described in [invitation AI research](invitation-ai-research.md).

The reusable pattern is: propose a small set of plausible values, let Jev select the intended meaning or abstain, then validate and copy the selected value into the review form. The candidate source changes by field. Places need external search; dates, quantities, and titles mostly need local parsing. Recipients eventually need an authorized friend roster.

TypeSafe documents this as [pre-parsed value extraction](https://docs.typesafe.ai/cookbooks/pre_parsed_value_extraction_cookbook). Its [API](https://docs.typesafe.ai/api) allows up to 255 options per Choice question; include an abstention option within that limit. A high-confidence answer cannot recover a correct value that was never offered. Candidate coverage and false auto-fills therefore need separate evaluation.

## Field-by-field proposal

| Form field | Candidate source | Jev's role | Deterministic mapping and limits |
| --- | --- | --- | --- |
| Activity / title | Common activity categories plus complete activity phrases from the transcript. | Select the actual plan, excluding rejected alternatives and filler. | For a known activity, compose a title such as “Dinner at Lucia” from the activity and confirmed place. Preserve a spoken phrase for uncommon activities. Category can supply an emoji; it must not restrict what people can plan. |
| When | Parsed temporal phrases, recording instant, locale, and IANA timezone. | Select the intended start expression, or abstain if alternatives remain unresolved. | Resolve calendar arithmetic in code. Keep each date/time combination attached to its source phrase. Preserve date-only or daypart information without turning it into an invented timestamp. |
| Duration | Spoken quantities and units, including number words, fractions, and explicit start/end ranges. | Distinguish total duration from a delay, end time, or unrelated quantity. | Convert units in code; calculate a duration from unambiguous paired endpoints. “In 30 minutes” is a start delay; “for 30 minutes” is duration. Never estimate duration from activity. |
| Group limit | Quantities associated with capacity, open places, or current attendance. | Classify the quantity's role: maximum total, additional openings, current count, or unknown. | “Table for four” can suggest total capacity 4. “Two more people” gives two openings, not a total. Leave total capacity blank unless the necessary count and product rule are known. |
| Invite friends | Matching names from the user's authorized, eligible friend roster. | Resolve identity and explicit invitation intent. | Return IDs from that roster, with reviewable selection chips. Mentioning someone is insufficient. Multiple Alexes require disambiguation. Multiple invitees need per-person decisions, not every possible combination of friends. |
| Exact place / area | Small set: specific meeting spot, general area, unknown; retrieved place geometry where available. | Distinguish “meet at the park entrance” from “walk around the Mission.” | An area needs an approved center and extent. A neighborhood search result's point is not its boundary. The hang's area is separate from the user's location-sharing privacy preference. |
| Radius | Explicit spoken distance and units, if any. | Decide whether that distance describes the hang area rather than travel distance or a route. | Convert units and validate supported values. Don't silently round an unsupported radius or infer one from an activity. |
| Video | The recording the user approved. | None. | Retain the selected artifact; classification does not choose or replace it. |

Activity/category is a proposed internal field, not an existing extra form control. The current emoji implementation uses title keywords. Neither privacy preferences nor notification settings should be inferred from invitation speech.

## Time deserves the first improvement

The current function classifies day, hour, and minute independently. TypeSafe's [date extraction cookbook](https://docs.typesafe.ai/cookbooks/date_extraction_cookbook) supports classifying date components and resolving them in code. For this app's short invitations, complete temporal candidates would better preserve relationships when the speaker proposes or corrects multiple plans.

For “Friday at seven PM or Saturday at eight PM,” propose Friday 19:00 and Saturday 20:00, each with its original span. If the speaker hasn't chosen between them, leave the start unresolved. The candidate representation itself should prevent Friday 20:00 from being assembled out of unrelated components.

For “tonight,” retain a partial draft value such as local date + evening + original wording. Recommend showing “Tonight · choose a time” during review. The current posting rule still requires an exact future start or Now; preserving partial information does not authorize posting a vaguely scheduled hang.

For “in 30 minutes,” calculate from the recording instant, not the later network-response time. Revalidate against the actual time before posting. Keep explicit date/timezone context and existing daylight-saving gap/fold checks. Do not reinterpret an elapsed “today at 8 AM” as tomorrow, or silently decide ambiguous “next Friday” conventions.

[Chrono](https://github.com/wanasit/chrono) is one candidate parser to evaluate, not an adopted dependency. Its parsed components expose `isCertain`, which distinguishes explicit components from parser defaults. Those flags matter: a parser's assumed hour for “tonight” is not spoken evidence. Its timezone behavior needs checking against our IANA/DST requirements rather than replacing the existing validator blindly.

## Concrete example

Spoken: “Let's get dinner at Lucia tonight. We've got a table for four.”

Recommended editable draft, assuming Apple search and Jev confidently resolve Lucia:

- Title: Dinner at Lucia.
- Activity / emoji: dinner / food emoji.
- Place: selected Apple result with address and coordinates.
- When: Tonight, with exact time still to choose.
- Group limit: 4 total, under the current classifier's host-inclusive interpretation.
- Duration: unset.
- Invite friends: none selected.

Dinner does not establish an exact hour, a two-hour duration, or an invitation to every nearby friend. If the venue cannot be resolved, keep that field blank and retain the usable activity phrase.

## Observed gaps in the current code

Read-only diagnostics exercised `buildQuestions`, `titleSpans`, and `mapAnswers` with synthetic transcripts and provider answers. These are structural observations, not live Jev accuracy measurements:

- “Let's chat for twenty minutes” does not offer a 20-minute duration. The digit variant “20 minutes” does. Dynamic quantity extraction currently handles digits only; 20 is absent from the fixed presets.
- “Let's go for a walk at Dolores Park tonight” produces no title candidate. Splitting at “for” leaves “go,” which the minimum-length filter discards.
- Even a confident day choice for “tonight” becomes `startMode: unspecified` with no timestamp or partial date field when hour/minute are missing.
- There is no dedicated relative-start candidate for “in 30 minutes.” Current hour/minute instructions require a spoken clock time.
- Injected high-confidence Friday + 20:00 answers produce a Friday 20:00 timestamp for “Friday at seven PM or Saturday at eight PM.” This demonstrates a missing association check, not an observed response from Jev.
- Date candidates cover only the next 31 local dates. Duration is limited to 1–360 minutes and group size to 0–12, with 0 meaning explicitly unlimited. These are current application restrictions, not Jev cardinality limits. Unsupported values should be shown for correction, never clipped to the nearest valid choice.
- Applying a suggestion always selects pin mode. There is no AI choice for area, radius, activity category, or recipients. The recipient picker still uses `Friend.mock`; contact discovery is not an accepted-friend graph.

## Suggested contract and implementation order

Keep field values nullable, but retain candidate ID, source span, and precision alongside successful suggestions. Distinguish missing information, ambiguity, unsupported values, and retrieval failure internally so review can ask for the right correction. Use plain labels in the form rather than confidence percentages. All AI changes remain editable and require review; existing user edits must survive any later retry.

1. Improve time candidates and preserve partial time information. This fixes the most consequential ambiguity and requires a small review-form/schema extension.
2. Improve activity phrases and template titles from confirmed fields. Keep uncommon activities possible.
3. Parse spoken quantities before classification, including number words and fractions. Classify their role before converting them to duration or capacity.
4. Add exact-place/area suggestions after deciding area geometry and radius behavior.
5. Add recipient suggestions only once real friend relationships, invite eligibility, and server enforcement exist. Notification Off must block direct invites regardless of classifier output.

Batch independent questions into one Jev call as today. Parsing, arithmetic, template composition, and validation do not require additional model calls. Evaluate candidate coverage, wrong auto-fills, abstention, user corrections, and total latency. Include negation, corrections, multiple alternatives, missing values, out-of-range values, speech transcription errors, and locale/timezone changes. Current confidence thresholds are uncalibrated starting points.

## Product choices to settle before implementation

- **Partial time:** recommend retaining “Tonight” during review and asking only for the missing clock time. Whether vaguely timed hangs can eventually be published is a separate decision.
- **Capacity language:** recommend making “people total, including you” explicit if retaining the current classifier interpretation. Decide whether the product also needs an “open spots” concept before converting “two more” into a total. The existing social capacity semantics remain unsettled.
- **Title style:** recommend short activity + place titles, with editable spoken wording for unusual plans.
- **Area defaults:** decide whether a missing radius stays unset or uses a clearly visible manual default. Never treat a default as something the speaker said.

No production code, deployed function, database, or product behavior changed during this exploration.

# Invitation transcription and Jev

Updated September 25, 2026. Live capture/transcription and authenticated Jev drafting are implemented. The Edge Function is deployed, but a real iPhone → final transcript → live Jev result still needs verification. No latency or field-accuracy measurements have been made.

## Shortest wait after recording

Transcription starts while the user records. The implemented pipeline is:

Camera + microphone → local speech transcription → finalized transcript → draft extraction/classification → user review.

Apple's `SpeechAnalyzer` with `SpeechTranscriber` is the first candidate to benchmark. It operates on device and accepts live audio as well as files. This project already targets iOS 26.5. Recording and analysis can overlap, avoiding a video upload on the path to a draft. This is an architectural reason to expect a shorter wait, not proof that Apple beats every service on every device.

Prepare language assets before recording and call `prepareToAnalyze(in:)` to reduce startup delay. Check device and locale support at runtime. Missing model downloads, unsupported hardware/languages, background interruptions, and silence need explicit fallback handling. Preliminary text can change; only a finalized transcript should feed the approved draft. A retake must discard its previous transcript.

The recorder now uses AVFoundation video/audio outputs on one serial capture queue. Accepted movie audio also feeds the on-device analyzer. Camera preparation happens before recording; only audio from the current take reaches transcription. The recorder has a portrait front-camera preview, 15-second cap, live provisional captions, review/retake, interruption handling, and cancellation that releases the capture session. Only finalized speech reaches Jev. Unsupported devices, missing assets, silence, dropped audio, and stalled finalization preserve the video and allow manual details. A missing model can download before recording; an explicit “Record without transcription” action skips it. Imported Photos videos use local audio decoding/transcription after selection.

Sources: [Apple speech walkthrough](https://developer.apple.com/videos/play/wwdc2025/277/), [SpeechTranscriber support](https://developer.apple.com/documentation/speech/speechtranscriber), [analyzer preparation](https://developer.apple.com/documentation/speech/speechanalyzer/preparetoanalyze(in:)), [audio capture buffers](https://developer.apple.com/documentation/avfoundation/avcaptureaudiodataoutput).

## If the video is already recorded

Decode its audio and transcribe locally, independently of video compression/upload. A cloud fallback should receive only audio. Groq's `whisper-large-v3-turbo` is worth comparing: its published 216× real-time factor measures processing speed, not our complete upload-to-transcript latency. Do not turn that number into a promised response time for a 15-second clip.

Deepgram and AssemblyAI also support streaming transcription. Their word/partial-result latency figures are not equivalent to the time to receive a complete, final transcript after stopping. For a streaming fallback, establish the connection before recording and explicitly finish the audio stream when the user stops instead of waiting for an arbitrary silence timeout. Provider secrets belong on the server; a mobile streaming client needs a supported short-lived credential.

Sources: [Groq speech API](https://console.groq.com/docs/speech-to-text), [Deepgram stream finalization](https://developers.deepgram.com/docs/finalize), [AssemblyAI result lifecycle](https://www.assemblyai.com/docs/voice-agents/best-practices).

Benchmark 5–15 second invitations on a real supported iPhone: measure Stop → final transcript, and Save → editable draft, reporting median and p95. Include warm/cold models, first-use downloads separately, Wi-Fi/cellular, silence, noise, accents, venue names, and exact times. Compare accuracy of the actual form fields as well as transcript errors. No latency promise until these measurements exist.

## Jev's role

TypeSafe's Jev 1.13 accepts text, not video or audio. Its documented limits are 64k tokens for a request and 32k for the shared state plus its longest question—ample for short spoken invitations. Pin a model version when evaluating it.

Jev returns choices from supplied candidates, yes/no probabilities (`Noul`), or rubric scores. It does not write an arbitrary title or extract an unrestricted place name into a generative JSON schema. Use Choice for activity and discrete time/group options, including unknown/none. A rubric score is not an exact headcount.

For open fields, either propose candidate spans first and have Jev select them, or use a small extraction model and let Jev check whether the proposed fields are supported by the transcript. TypeSafe documents both patterns. A title can also be templated from approved fields. Resolve calendar math using an explicit reference date/timezone; resolve venues through Maps and user confirmation rather than invented coordinates.

Sources: [Jev model limits](https://docs.typesafe.ai/models), [question and response formats](https://docs.typesafe.ai/api), [candidate extraction](https://docs.typesafe.ai/cookbooks/pre_parsed_value_extraction_cookbook), [date extraction](https://docs.typesafe.ai/cookbooks/date_extraction_cookbook), [extraction with verification](https://docs.typesafe.ai/cookbooks/sde_cascade).

## Form contract

The app owns the final schema, independent of the AI vendor. For example, this illustrative draft could follow “Dinner at Lucia tonight at eight” with a September 25, 2026 reference date in Los Angeles:

```json
{
  "transcript": "Dinner at Lucia tonight at eight",
  "title": "Dinner at Lucia",
  "placeName": "Lucia",
  "startMode": "scheduled",
  "startsAt": "2026-09-25T20:00:00-07:00",
  "durationMinutes": null,
  "groupLimit": null
}
```

This is not a raw Jev response or a measured model result. The backend maps provider output into `HangDraftSuggestion`, validates the schema and bounds, and leaves unsupported fields null. `startMode` is now, scheduled, or unspecified. Keep uncertainty/evidence alongside fields when the provider is connected; calibrate review thresholds on real invitations. Review remains mandatory, and analysis never posts a hang or selects recipients.

## Implemented classifier and boundaries

`draft-hang` pins `jev-1.13.0`. The iPhone sends the finalized text, locale, recording reference time/timezone and verbatim named-entity proposals. No audio or video is uploaded for drafting. There is no generative extraction model in this implementation.

The backend supplies dynamic transcript phrases for title/place and finite choices for start mode, the next 31 local dates, clock hour/minute, duration and total group limit. Every question offers `none`. Fields require confidence ≥ 0.85 and selected-choice probability ≥ 0.90; these are conservative initial thresholds, **not calibrated accuracy guarantees**. Missing, malformed, unsupported or uncertain answers become null. Calendar code rejects past starts and ambiguous/nonexistent daylight-saving times. “Tonight” alone does not invent a clock time. Title/place phrase extraction currently favors English invitations; other language transcripts may require manual entry.

Place text is a proposal, not a resolved venue: a name alone never establishes coordinates. The form still requires user confirmation of a map location. Drafting neither posts the hang nor selects recipients. Duration and group limit remain visibly unset if not supported by the invitation.

The Edge Function validates a live signed-in, non-anonymous account and completed onboarding. The private database counter allows 20 attempts per account per hour, including attempts that later fail at the provider. Atomic row locking enforces the limit under concurrent calls. Only the counter is stored there, not transcripts. `TYPESAFE_API_KEY` stays in Edge Function secrets. Requests and provider responses are size bounded; network calls have deadlines. The app retains manual entry on any failure. This does not change TypeSafe's own data-retention terms.

## Venue retrieval proposal — provider decision pending

For “Let’s get dinner at Lucia tonight,” retrieve candidates with a name search for Lucia biased toward the user’s real current area, then send Jev at most 5–10 choices. Include a stable provider ID, name, address, category and distance. Jev chooses a candidate ID or no match; application code copies its coordinates from the retrieved record. Nearby-only enumeration can miss the intended venue. Do not filter by open-now for a future hang, or treat nearest as proof of identity. Explicitly spoken city/neighborhood should override the default local search context. If equally plausible branches remain, leave the venue unset for the user to choose.

Google Text Search supports a text query and geographic bias, but Google Places results displayed on a map must use a Google map. This app currently uses Apple MapKit. The implementation choice is therefore Apple place search with the same Jev selection pattern, or Google Places together with a map-provider change. That choice is pending; neither provider's venue lookup has been wired into drafting yet. The prototype's sample SF coordinate must never be represented as the user's actual GPS position. Real location permission/freshness or an explicitly chosen search area is needed first.

Sources: [Google Text Search](https://developers.google.com/maps/documentation/places/web-service/text-search), [Google Places policies](https://developers.google.com/maps/documentation/places/web-service/policies).

## Verification

`Tests/hang_draft_test.mts` exercises candidate bounds, confidence abstention, malformed answers, timezone/DST rules, request authentication, budget failures and provider errors using a mocked provider. `Tests/hang_draft_backend_test.py` tests real local Auth/PostgREST and concurrent quota enforcement with disposable accounts. Swift tests check PCM conversion duration, provisional/final passage handling, dropped-buffer rejection, editable form behavior and cancellation races. `scripts/check.sh` runs these alongside the existing account/media tests and Debug/unsigned Release builds. Node 22.6+ with TypeScript stripping is needed for the backend unit tests.

The hosted function rejects unauthenticated calls with HTTP 401. Hosted security advisors report only informational “RLS enabled, no policy” findings on the intentionally inaccessible private tables; no performance findings. Those tables are accessed solely through guarded internal functions. See [the advisor explanation](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy).

Physical-device checks still required: camera/microphone permission denial, warm/cold speech models, correct final words after stopping, silence/noise, multiple retakes, interruption/backgrounding, imported audio, and a signed-in request using the saved Jev secret. Evaluate false-positive fields and end-to-end latency on real invitations before tuning thresholds.

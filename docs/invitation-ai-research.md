# Invitation transcription and Jev

Research date: September 25, 2026. These are architecture recommendations from official documentation, not measurements from this app. No live Jev or transcription API request has been made.

## Shortest wait after recording

Start transcription while the user records. The proposed pipeline is:

Camera + microphone → local speech transcription → finalized transcript → draft extraction/classification → user review.

Apple's `SpeechAnalyzer` with `SpeechTranscriber` is the first candidate to benchmark. It operates on device and accepts live audio as well as files. This project already targets iOS 26.5. Recording and analysis can overlap, avoiding a video upload on the path to a draft. This is an architectural reason to expect a shorter wait, not proof that Apple beats every service on every device.

Prepare language assets before recording and call `prepareToAnalyze(in:)` to reduce startup delay. Check device and locale support at runtime. Missing model downloads, unsupported hardware/languages, background interruptions, and silence need explicit fallback handling. Preliminary text can change; only a finalized transcript should feed the approved draft. A retake must discard its previous transcript.

The current `UIImagePickerController` implementation returns the completed movie, so it can support transcription after saving but does not expose live microphone buffers. Live transcription requires an AVFoundation capture implementation that sends the same audio buffers to the movie writer and analyzer. It must preserve native-feeling capture, interruption handling, orientation, microphone permissions, and the existing 15-second limit.

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

Next integration decision: Apple transcription is compatible with either Jev plus candidate-building code or a small extraction model plus Jev verification. The latter is the more flexible starting point for arbitrary venues and natural titles; evaluate whether Jev improves field accuracy enough to justify its extra call. No cloud provider is wired into the composer yet.

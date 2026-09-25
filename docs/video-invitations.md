# Video invitations

Creating a hang starts with a personal video invitation. The composer opens the AVFoundation recorder on supported devices; after saving a clip, the user reviews the form before posting. A hang with video leads with its poster and play button. The title, place, and time remain readable without playing audio, and Join stays pinned below the detail content. “Write it instead” keeps text-only hangs available.

## Current behavior

- Tapping Let’s hang prompts for camera and microphone access and opens the front camera when available. It never starts recording automatically. Canceling the recorder returns to the video introduction. Devices without a camera offer Photos and manual entry. Choosing from Photos does not require access to the whole library.
- The composer has recording, processing, failure, and review states. The analysis operation is connected to an authenticated Supabase Edge Function that calls Jev with finalized transcript text. Cancellation protects manual edits from late results. Capture feeds Apple on-device speech analysis while recording; a retake starts a fresh transcript. The recorder shows provisional captions and reviews the saved clip before sending text for drafting. No video/audio is uploaded to Jev.
- The typed suggestion contract supports title, place name, start mode, ISO-8601 start time, duration, and group limit. Confident Apple venue matches fill their name/address and retrieved coordinates for user review. Uncertain matches leave the place unset; the user can search Apple Maps or choose a point on the map. Missing or invalid start times remain unset. Post requires a title, location, and valid start choice. Missing or invalid numeric suggestions stay visibly unset, rather than inheriting manual-form defaults.
- Clips are limited to 15 seconds. Longer imports are rejected with a suggestion to trim in Photos; the app does not silently cut off someone's invitation. A quarter-second recording tolerance is trimmed to exactly 15 seconds.
- Selected files are copied before the picker releases its temporary URL, exported to a 720p MP4 with exported asset metadata cleared, and given an orientation-correct poster. Inputs over 250 MB and outputs over 50 MB are rejected.
- Post is disabled during import. Canceling or failing a replacement keeps the previous clip. Canceling the draft releases its media; posting retains it with the hang. The last owner releasing a clip removes its temporary file. On startup, files from terminated sessions older than a day are removed.
- Playback starts only after tapping the poster, uses native controls, and pauses when the player closes or the app becomes inactive.
- The Today list marks video invitations with a small play badge. Opening one expands the detail sheet to make room for the video. Both light and dark appearances and larger text are supported.

## Scope and next decisions

This is a functioning **local preview**, consistent with the existing hang model. Videos are not uploaded, sent to friends, or restored after restarting the app. Existing sample people have no fabricated video attached.

Before cross-user delivery, implement durable hangs and private media storage with authorization tied to the hang's audience. The storage object must have a lifecycle coordinated with posting, canceling, deleting, and expiring a hang. The current join action, recipient choices, and sharing button do not deliver videos.

Product decisions to revisit with real use:

- Is the 15-second limit the right starting point?
- Should a video disappear when the hang ends, or stay in a history?
- Should we offer captions, a poster selector, or in-app trimming?

These decisions do not block trying the current recording/import and playback interface. Real camera capture, permission denial, microphone audio, and capture interruptions still need testing on an iPhone. Sign-in and cross-user delivery remain separate from this Simulator preview.

AI provider research and the recommended transcription approach are in [invitation-ai-research.md](invitation-ai-research.md). The pipeline includes Apple venue search; real-device end-to-end validation remains outstanding.

## Verification

`HangVideoTests` covers playable export and portrait posters, removal of source location metadata, overlong and unreadable files, replacement failures, cancellation races, and file ownership after posting. `ComposerDraftTests` covers required details, place confirmation, date parsing, and suggestion bounds. `HangDraftAssistantTests` covers successful review, failure recovery, and a late analysis result arriving after manual editing begins.

Simulator checks: choose a synthetic six-second clip, preview it, post a titled hang, open its detail, and play the retained clip. The fixture contains no personal footage. Also check no-camera messaging, light/dark appearance, and accessibility text sizes. Debug Simulator and unsigned Release iOS builds pass; the Release build does not validate provisioning or device camera behavior.

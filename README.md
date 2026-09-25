# whoisintownrightnow

Account implementation and local test instructions: [Account setup](docs/account-setup.md). Current account decisions supersede the older granularity and notification text below: Exact/all-friends or half-mile Vicinity; notifications Off, Direct invites only, or All; Apple sign-in first. The map/social features remain a prototype while accounts and settings now use Supabase.

Current product language: **hangs**. The home panel opens to “Today,” with a prominent “Create hang” action. The earlier product draft below uses the former “signal” terminology.

Hangs now support optional video invitations in the local preview: record or choose a short clip, preview it, and play it from the hang detail. See [video invitations](docs/video-invitations.md) for behavior, testing, and remaining delivery work.

Optional contact sync and the People invite list: [contact discovery setup](docs/contact-discovery.md). Verified-phone matching is implemented; SMS-provider configuration and an invite download link are still needed.

A friend map you already know how to use, plus a way to say *I'm doing this thing, come find me*. Find My Friends is the chassis. The bat signal is the engine.

iOS · always-on location · one screen, one object, one button

*Product requirements: draft 02, scoped down.*

## V1, in one sentence

A map of your friends at neighborhood granularity, and a single button that broadcasts one thing: what you're doing, where, and when, pinged to whoever is nearby and free.

## Design principles

1. **Familiar on purpose.** Reads as a friend map on open. No tutorial, no new mental model. The novelty is what you can do from it.
2. **One object, not four.** A signal has a place, a window, and a line of text. Everything else was a variation pretending to be a feature.
3. **Ends in a group text.** We don't build chat. Joining a signal hands off to iMessage. The app's job is to get the thread started.

## Locked decisions

All forks resolved. Designing against this.

| Area | Decision |
| --- | --- |
| **Home = the map** | Full-bleed map, friend avatars, signals as pins. No feed tab. A shallow sheet at the bottom lists what's live, nothing more. |
| **One signal type** | Text + place + time window. Place is either a pin (a venue) or a region (a neighborhood blob, for "somewhere in the Mission"). "Free now" is just a signal with a loose region and a short window. |
| **Granularity** | One global setting, same for everyone, fixed at neighborhood. No per-friend tiers in v1. Location is always on. A single ghost toggle is the only escape hatch. |
| **Audience** | Automatic: friends who are nearby right now get the push. Everyone else can see it on the map. Joining is one tap (no approval) and drops you into an iMessage thread with the host. |
| **Composer** | One button, one mode, one short form. No mode picker to design because there are no modes. |
| **Voice** | Playful, a little chaotic. The map is calm; the copy is not. |

## The signal

The only object in the app. Four fields, two of them optional.

| Field | Required | Notes |
| --- | --- | --- |
| **Text** | Yes | One line. "dinner at Lucia, 2 seats" · "aimless, walking around" |
| **Place** | Yes (pin or region) | A venue pin when you know it, a neighborhood blob when you don't. Defaults to the blob you're standing in. |
| **Window** | Yes | "next 2 hours" or "tonight 8pm" or "Saturday". Expires itself, always. |
| **Seats** | Optional | Cap it if it's a table for four. Blank means come one come all. |

Cut from v1: **Idea** (no-place-yet posts) and **Trip** (city + dates). Both are on the roadmap, neither is in the mock.

## Roadmap, in order

Deliberately deferred, not forgotten. All of these are outside v1. Sequence: browse future plans before adding travel; turn tentative ideas into signals before adding shared hosting.

- **v1.1 Time browsing.** Give the map and its sheet a time dimension: now, tonight, this weekend, or a future date range. Browse signals whose windows overlap that period, including in another city ("what's happening in NYC this weekend?"). This comes before Travel so a future visit has useful plans to explore. Future plans must be distinguishable from friends' live locations; being somewhere now doesn't mean being there this weekend. Zoom-is-time remains a direction to explore; the exact interaction is deferred.
- **v1.2 Travel.** "I'm in NYC Fri–Mon" as a glowing city bubble when you pinch the map out. Build on time browsing to see declared visits alongside signals for the same city and dates, without a new tab.
- **v1.3 Ideas.** Placeless posts ("bike ride this weekend?") that a friend can convert into a real signal by adding a place.
- **v1.4 Co-host invitations.** Tap a friend's avatar or friend card even when they haven't put out a bat signal, and privately propose hosting something together. They can accept or decline; appearing on the map alone doesn't mean they're asking to hang out. Once both agree on the plan, publish a shared signal. This follows Ideas because it extends the tentative-plan-to-signal flow to two hosts. Invitation behavior, shared editing, and who publishes or cancels remain design work for this phase.
- **v2 Circles.** Per-circle granularity and per-signal audience. Asymmetric and opaque when it lands: nobody ever sees their tier.
- **Unsolved.**
  - The flop (nobody answers your signal)
  - Notification policy
  - Cold start with 3 friends
  - Safety: home/work blackouts, ghost mode, coercion

## Screens

Down from eight to five. Interactive, in an iPhone frame.

1. Map home + live sheet
2. Composer
3. Signal detail + join
4. Friend card
5. You / privacy

## Prototype notes

Behaviors specified in the interactive prototype:

- **Composer ("Bat signal").** "What's the move", where, when ("Right now" or pick a time, with a start time and how long the signal stays up, 1 to 6 hrs), cap the group, and who gets pinged.
- **Place picker.** "Exact spot" (a venue) or "A circle" sized from "a block" to "the whole neighborhood", centered on you by default.
- **Who gets pinged.** Nearby friends are selected by default; anyone further out can be added by hand.
- **After sending.** "Bat signal's up" confirmation shows who was pinged, with an option to also text the group.
- **Notifications ("The sky").** Only signals from friends within a mile push to your phone. The rest wait in the in-app list.
- **You / privacy.** Location precision, ghost mode, and your friends list.
- **Add friends.** "The map is boring alone." Share a personal link (e.g. `whoisintown.now/jordan`); friends see you on their map the second they're in.

## Visual directions

Three directions for the map home, all with the same anatomy: full-bleed map, friends as avatars inside neighborhood blobs, live signals as pins, a shallow sheet listing what's happening, and one bat-signal button. Only the temperament changes. Mixing is allowed ("1a's map with 1b's sheet").

| Direction | Look | Sample copy |
| --- | --- | --- |
| **1a Invisible** | Reads like a system app: light map, iOS materials, one blue accent. The signal is the only loud thing on screen. | "6 friends nearby" · "Happening tonight" · "Join" |
| **1b After dark** | Night map, signals as beacons that actually glow. Type is loud, copy is chaotic. Feels like the app is for going out. | "6 out there" · "GOING ON" · "I'M IN" · "BAT SIGNAL" |
| **1c Field guide** | Warm paper map, ink lines, stamped labels. Friend blobs are hand-inked circles. Friendly and low-stakes: less surveillance, more bulletin board. | "6 friends about" · "The bulletin" · "COMING" · "Put out the signal" |

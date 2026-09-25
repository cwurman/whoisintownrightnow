# Product functionality audit

**UX update:** the [native iOS refinement](ux-refinement.md) replaces the custom map/composer surfaces, adds people details, real draft dates, and map pin selection. The historical inventory below retains the initial behavior.

**Current status:** see [next-session notes](next-session.md) for the completed account foundation, save/photo reliability, map list/action fixes, native sharing, validation results, and remaining decisions. The inventory below is the original audit, preserved for traceability; it includes behavior that has since been fixed.

Implementation update, September 25: the account foundation described in [account setup](account-setup.md) now replaces the hardcoded identity/profile entry point. Name, photo, and sharing/notification preferences persist in Supabase; its Apple provider is enabled, while developer provisioning and real Apple authorization remain unverified. The inventory below is the original audit, retained as a record of the remaining social/map work. It is not a statement that the new account code is still mocked.

Decision update: location sharing now has Exact/all-friends and half-mile Vicinity modes; notifications have Off, Direct invites only, and All modes, with Off preventing new direct invites. Apple sign-in will come first, with email later. See [Account, settings, and storage design](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/docs/account-data-design.md) for the confirmed decisions and proposed database model. The audit below records the implementation gaps found before that design work.

Reviewed September 24, 2026, starting from commit `625de0d`. Scope: all five Swift source files, every action and navigation closure, data models, assets, and Xcode configuration. Selected baseline paths were also exercised on the iPhone 17 Pro / iOS 26.5 simulator. This audit only adds this document. Concurrent edits to Models.swift, MapHomeView.swift, and the Composer preview appeared during the review; their host/destination model and new detail/focus paths have been read and incorporated below. Simulator observations refer to the previously built baseline, not those in-progress edits. Source links reflect the working files when reviewed and may move as editing continues.

The app is an interactive prototype. MapKit supplies a real map, and the composer controls update local state. Social behavior uses hardcoded people, places, identity, locations, and signals. There is no account system, persistent store, application backend, location acquisition, notification delivery, or messaging integration in this repository.

**What works today**

The baseline map renders and supports navigation. The concurrent update adds a host-to-destination focus view and basic signal detail panel in source; those new paths have not been runtime-tested in this audit. The home sheet toggles between two and four rows. The composer opens and closes; text, seat and time controls work within the draft. Place search filters the built-in list; place selection, circle preview, recipient toggles, and reset update the draft. Posting inserts a local signal and displays a confirmation. Joining changes the local signal and shows a toast. These interactions do not constitute cross-user delivery or durable storage.

**Complete interaction inventory**

| Entry point | Code path and current behavior | Missing behavior / decision |
| --- | --- | --- |
| App launch | App → ContentView → MapHomeView → `@State signals = Signal.mock`. Sample friends (five originally, six after the concurrent Tara addition), two sample signals, fixed San Francisco map. | No onboarding, signed-in identity, data loading, persistence, or synchronization. Decide whether the next milestone is a demo or a real private beta. |
| Nearby/free pill | Counts `Friend.mock`; tapping calls `toggleSheet()`. Nearby means distance strictly less than 2 miles; free counts all mock friends. | No friend list route, live proximity, presence refresh, or way to mark yourself free. Decide what “free” means and whether the free count is restricted to nearby friends. |
| Friend avatar | `FriendAvatarView` tap → toast “friend's card — next screen.” | No card, profile, current availability, friend actions, or contact action. `Friend.note` is never shown. |
| Signal pin or row | Originally a placeholder toast. Concurrent code now calls `focus(on:)`, fits the camera to host/destination, draws a curved connection, and opens SignalDetailSheet with host, place, time, attendee count, and Join. | Basic detail UI now exists. It still has no named attendee list, host contact, real directions, share, leave, or owner management. Join reaches the same local-only handler. |
| Focus close / map connection | Close button, handle tap/downward drag, and top pill call `clearFocus`, restoring the previous overview camera. Focus drawing is cancelled on selection changes and respects Reduce Motion. | Connection is a decorative curve, not routing. Only one signal per host is shown on the overview map; older signals rely on the already-truncated list. Decide how to access multiple signals from one host. “Around [place] right now” uses a stored anchor without a freshness timestamp. |
| Notifications bell | Toast “The sky — next screen”; unread dot is unconditional. | No activity feed, notification records, unread state, or notification deep links. Decide which events belong in “The sky.” |
| Profile / JD | Toast “You screen — next screen.” | No editable profile, current-user model, availability, sharing preferences, account settings, or friend management. |
| Join | `SignalRowView.onJoin → MapHomeView.join`; marks joined and appends “JD.” Only missing-record, already-joined, and own-signal checks. | No capacity or expiry check, leave/cancel action, host approval, synchronization, or message launch. Decide whether Join is an RSVP, a request, or a conversation. |
| Live / In state | Row join handler returns without doing anything for owned/already-joined signals; the new detail panel disables its join button for these states. | No owner management or leave affordance. Decide owner controls and whether joined users can withdraw. |
| Send out bat signal | Opens a fresh ComposerView with a local ComposerDraft. | No draft persistence or restore. Decide whether closing intentionally discards work. |
| Light it | Nonblank-text guard → `handlePost` → in-memory insert → dismiss → confirmation after 600 ms. | No save or delivery result, validation of date/location/audience, submission failure/retry, or durable result. Some draft values are discarded; see the field table below. |
| Cancel / swipe dismiss | Dismisses the composer. Draft has no persistent owner. | No draft recovery or unsaved-changes behavior. |
| Exact spot / search | Filters three fixed venues plus the “Drop a pin” pseudo-result by name. Selecting a result mutates the draft and returns. | No real venue/address lookup, current-area suggestions, search loading/error/no-results state, or stable place identifier. “Use” remains available with the previous place even for a search with no matches. |
| Drop a pin | Sets name to “Dropped pin” and immediately returns. | No interactive placement. Mini-map shows the fixed user coordinate; posted coordinate uses a hardcoded offset from it, so preview and result disagree. |
| A circle | Changes draft mode; radius slider changes the preview circle. | The published Signal lacks location mode and radius, so the home map stores a host anchor and displays a destination point on focus, not the chosen circle. Decide the shared center and whether it is fixed or follows the host. |
| Place Back / Use | Both return; changes already mutated the bound draft. | Back is not cancel. Confirm whether picker changes apply immediately or only on Use. |
| Right now / Pick a time | Switches draft UI and formats labels; Today/Tomorrow/Sat/Sun are static labels. Start time is 6:00am–11:30pm in 30-minute steps; duration is 1–6 hours. | No calendar date, start/end timestamp, time zone, past-time validation, clock-based update, or expiration. Decide scheduling and lifetime rules. |
| Cap the group | Stepper sets 0–12; zero displays infinity. Value is shown on the row. | Cap is never enforced or decremented. Decide whether it counts guests, total attendees, or remaining places; whether approval or a waitlist exists. |
| Who gets pinged | Toggles sample IDs, grouped using fixed distances; Reset restores literal IDs mk/rs. | Selection affects the confirmation only. No recipients are persisted with the signal and no notifications are sent. Clarify visibility versus notification audience and the nearby rule. |
| Recipients Back / Signal these N | Both return; selection was already applied to the draft. | “Signal these N” does not send anything at this point. Clarify apply/cancel semantics and button copy. |
| Confirmation | “Bat signal's up” and “PINGED JUST NOW” are displayed from local data. | No delivery acknowledgement. Even zero recipients retains the “PINGED JUST NOW” heading. |
| Also text the group | Calls exactly the same `onClose` callback as Back to the map. | No share sheet, Messages composer, recipient phone numbers, or shareable signal URL. Decide whether “group” means selected recipients, attendees, or a user-chosen conversation. |
| Happening handle / more | Both call the same boolean toggle. Collapsed: first two; expanded: first four. | With five or more signals, “+N more” collapses the list instead of revealing the rest. No scrolling, full-list destination, actual drag handling, ranking, date filtering, or empty state. |
| Relaunch | Reconstructs all local state from fixtures. | Posts and joins disappear; nothing reaches another user. |

Sources: [app entry](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/whoisintownrightnow/whoisintownrightnowApp.swift:10), [root view](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/whoisintownrightnow/ContentView.swift:10), [home state and routing](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/MapHomeView.swift:13), [home actions](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/MapHomeView.swift:296), [Happening sheet](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/MapHomeView.swift:675), [row actions](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/MapHomeView.swift:746), [draft and composer](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/ComposerView.swift:30), [place picker](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/ComposerView.swift:373), [recipients](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/ComposerView.swift:603), [confirmation](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/ComposerView.swift:723).

**Where the post loses information**

The write path is `ComposerDraft → handlePost → Signal → signals.insert`. The resulting model cannot implement several promises made by the composer.

| Draft choice / context | What survives posting | What is missing |
| --- | --- | --- |
| Text | Trimmed title | Only spaces are trimmed, not newlines; no length limit or broader validation. The blank-post button has a guard but is not actually disabled for accessibility. |
| Selected venue | A display string and destination coordinate | Stable venue identity/address metadata for lookup, sharing, or navigation. |
| Exact spot versus circle | Place display text, a fixed host anchor, and destination coordinate | Place mode and radius; the destination is a point in the focus view. |
| Dropped pin | “Dropped pin” and synthetic coordinate offset | User-selected coordinate. Preview and posted point differ. |
| Right now + duration | “next N hrs” string | Creation time, absolute expiration, and a countdown. The text does not change with elapsed time. |
| Later + day/start/duration | A string such as “tomorrow, 8:00pm” | Actual date/time and duration/end time. The chosen duration is completely absent from the posted value for later signals. |
| Selected recipients | Used only in PostedConfirmation | Durable recipient IDs, notification jobs/results, and any visibility authorization. |
| Host | “You”, “JD”, fixed color, `isMine = true`, and now literal `hostID = "you"` | Authenticated account identity and ownership enforcement. Host IDs were added by the concurrent update, but still refer to fixtures. |
| Attendance | Initials in `going`, plus local `isJoined` | User IDs, membership records, joining/leaving timestamps, and reliable capacity accounting. Initials cannot uniquely identify people. |
| Distance | “you” for new posts; literals for fixtures | Distance derived from current position and selected place. |

Sources: [Signal fields](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/Models.swift:95), [draft fields and formatting](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/ComposerView.swift:32), [draft-to-signal conversion](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/MapHomeView.swift:349).

**Location and visibility need a product rule before real users**

Friend circles are always 850 meters and are drawn around the same coordinates used by the avatar annotations. The data is currently synthetic; there is no live-location leak to users today. However, drawing a translucent circle around an exact coordinate is not an implementation of the copy's neighborhood-only sharing promise. There is no approximate-location representation, location freshness, opt-in, pause, or location-permission fallback.

The circle picker promises that friends see an area. Its destination is instead a point at a fixed offset, with no radius stored. The concurrent update separates host anchor from destination and shows the latter on focus; this is a presentation distinction, not a visibility/authorization rule. A complete implementation must define what coordinate may leave the device and who may receive it, then preserve that representation in the model, storage, and map rendering.

The recipients screen says other people can still see the signal even when they are not pinged. That implies two concepts—viewers and notification recipients—but neither is implemented. It is unclear whether “everyone else” means all friends or all users. The nearby default is two hardcoded IDs; it is not recomputed from location. The concurrent update adds Tara at 0.9 miles but does not add her to that default, so the default already misses one nearby friend in the new fixtures. Users can deselect those IDs despite the “automatically” wording.

Sources: [friend fixtures](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/Models.swift:36), [friend map circles](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/MapHomeView.swift:126), [synthetic posted coordinate](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/ComposerView.swift:109), [circle preview and privacy copy](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/ComposerView.swift:401), [notification-audience copy](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/ComposerView.swift:631).

**Time, availability, and capacity inconsistencies**

Tomorrow's signal immediately appears under “tonight.” Expanding the same sheet changes its subtitle to “expiring within 4 hrs,” but neither caption filters the data. The composer permits durations up to six hours. There is no expiration timestamp or timer, so a signal stays present until the app's state resets.

Static Today/Tomorrow/Sat/Sun choices can overlap or become misleading as the real calendar changes. The formatter wraps end times through midnight without identifying the next day. “Today” can select a time in the past. There is no locale or time-zone model.

Friend availability is an immutable fixture boolean, independent of active signals or the current user's behavior. Posting or joining does not update the nearby/free counts.

Joining ignores the cap entirely. The sample dinner has `seats = 2` and `going = ["TW", "MK"]`, demonstrating why the meaning of seats must be specified before treating a particular count as full. Regardless of that decision, the join function never compares either value.

Sources: [home counts and list selection](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/MapHomeView.swift:34), [join mutation](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/MapHomeView.swift:377), [sheet captions](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/MapHomeView.swift:699), [time controls](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/ComposerView.swift:294), [sample attendance](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/Models.swift:124).

**Foundation and quality work**

These are absent or incomplete in the inspected repository; they are not claims about services that might exist elsewhere.

- Accounts and relationships: authentication, stable current-user identity, onboarding, friend discovery/invitations/acceptance/removal, blocking, and account lifecycle. No contact identifiers exist for messaging.
- Shared application data: durable local storage, backend/API, synchronization, access rules, stable user relations, and loading/offline/error/retry states. MapKit's map loading is separate from an application data service.
- Lifecycle: edit, end, delete/cancel, leave, expired/full states, and owner versus guest permissions. The UI currently allows multiple local signals; whether that is intended is a product decision.
- Notifications and sharing: permission and token registration, delivery service, event records, read state, notification routing, native message/share UI, and deep links. No push entitlement or location usage description is configured.
- Presentation reliability: confirmation presentation relies on an untracked 600 ms sleep rather than sheet-dismissal completion. This is a code-level race risk, not a reproduced failure in the checked flow.
- Accessibility and layouts: the home handle has no meaningful accessibility label; custom +/- controls lack contextual labels; most fonts and some sheet heights are fixed; the confirmation is fixed at 440 points. The new focus transition respects Reduce Motion, but the original pulsing user dot still animates continuously. Dynamic Type, VoiceOver, full Reduce Motion behavior, dark mode, iPad, and landscape need targeted verification. The nested row/Join buttons also deserve interaction coverage; do not assume a bug solely from nesting.
- Release readiness: there are no automated test targets or CI files in this checkout; the app icon catalog has slots but no images. The minimum deployment target is iOS 26.5, with iPhone/iPad and landscape enabled. The original development team and bundle ID remain configured. Physical-device signing and distribution were not verified in the earlier build check.

Sources: [project target/settings](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/whoisintownrightnow.xcodeproj/project.pbxproj:62), [deployment target](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/whoisintownrightnow.xcodeproj/project.pbxproj:196), [signing and orientations](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/whoisintownrightnow.xcodeproj/project.pbxproj:271), [empty icon catalog](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/whoisintownrightnow/Assets.xcassets/AppIcon.appiconset/Contents.json:1), [confirmation timing](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/MapHomeView.swift:370), [custom stepper](/Users/douglasqian/Documents/ChatGPT/whosintownrightnow/ComposerView.swift:825).

**Decisions I need from you**

These are product choices; implementation details can be worked out after the intended behavior is settled. The candidate directions below are suggestions for discussion, not decisions already made.

| Decision | What needs your input | Candidate direction |
| --- | --- | --- |
| 1. Next milestone | Complete local demo, or real private beta? Who should be able to use it? Is there an existing backend/design spec outside this repo? | A narrow private beta of the map → post → view → join loop; keep missing secondary features out of its completion criteria only if you explicitly choose that scope. |
| 2. Identity and friendships | How do people sign in, find one another, and become friends? Can non-friends see anything? | Invite-based, mutually accepted friendships; choose login method after audience and messaging needs are known. |
| 3. Location and availability | Automatic location or manual neighborhood? Updates only while using the app or in background? What does “free” mean, and how long does it last? | Explicit, time-limited availability; approximate sharing by default; exact venue sharing only when deliberately selected. |
| 4. Visibility and notification recipients | Who can see a signal? Do selected recipients only control push? Are nearby friends selected by default but removable? Does “nearby” measure from the host or event? | Separate visibility from notification selection. Use the existing two-mile concept as a configurable rule once its reference point is chosen. |
| 5. Join and capacity | Immediate RSVP, host approval, or just opening a conversation? Does the cap include the host? Can people leave? What happens when full? | Immediate RSVP and leave; explicit guest cap excluding host; no waitlist for the first version unless required. |
| 6. Time and lifecycle | Are scheduled signals visible immediately? Expiration measured from posting or start time? How far ahead may someone schedule? Can hosts edit/end and have multiple active signals? | Preserve the current copy's immediate visibility, use real start/end dates, and expire at end time; allow hosts to end early. |
| 7. Missing screens | What must be on friend cards, “The sky,” and “You,” and what remains to add to the new basic signal details? Are there approved designs? | Small sheets using the existing visual style. Signal detail: host, time/place, attendance, join/leave, and host controls. Profile: identity, availability, and sharing settings. |
| 8. Messaging and sharing | Native Messages, general share sheet, or in-app chat? Does “text the group” address pinged friends or attendees? Should Join also open messaging? | Keep RSVP separate from communication; use a user-controlled sharing flow with a signal link. Native group-text behavior requires an explicit recipient rule. |
| 9. App reach and distribution | iPhone only or iPad too? Which iOS versions? Which Apple developer team owns the app and beta? Is the current name/icon final? | Confirm target devices before promising layout or OS support; do not change account or signing ownership without the owner details. |
| 10. Draft behavior | Should Cancel/swipe discard, prompt, or save? Should Back undo picker edits? | Consistent immediate-apply pickers; preserve an unfinished draft only if that is desired. |

I do not need product input to identify or repair the four-row “more” bug, preserve chosen location/time values, avoid false delivery claims, derive dates from a calendar, replace the delayed sheet handoff, add accurate disabled states, or implement accessible labels. Rules for audience, privacy, joining, and lifecycle determine the correct behavior around those repairs.

**Verification performed**

- Previous turn: Debug simulator and unsigned Release device builds succeeded in Xcode 26.5; simulator app launched successfully.
- This audit: read all application source and callbacks; searched the entire source set for persistence, networking, location, notification, messaging, navigation, and lifecycle integration points. Re-read concurrent map/model changes and traced focus, clearFocus, drawConnection, destination rendering, detail Join, and host deduplication. Those new source paths have not been rebuilt or exercised in this audit.
- Simulator: invoked Join and observed the “Opening Messages with Tara…” toast with no Messages flow.
- Simulator: selected Drop a pin and returned immediately with “Dropped pin,” without selecting a point.
- Simulator: composed “Audit: circle tomorrow,” selected tomorrow, circle mode, and zero notification recipients; posted successfully to local state.
- Simulator: confirmation displayed “PINGED JUST NOW” alongside “nobody — map only.”
- Simulator: Also text the group dismissed confirmation; the new tomorrow signal appeared in the “tonight” list and as a point annotation.
- Simulator: terminated and relaunched the app; the audit signal disappeared and the original sample list returned.
- The overflow, capacity, expiry, and model-field findings follow directly from the inspected code. Multi-device, real notification delivery, real messaging, accessibility/layout matrices, and production authorization cannot be validated against integrations that are not present.

**Suggested implementation order after decisions**

1. Agree on identity, relationship, location, audience, join, and lifetime rules; encode stable IDs, structured location, real timestamps, and attendance in the domain models.
2. Make one durable end-to-end loop: load map → create signal → another authorized user sees it → join/leave → host sees the update → signal ends.
3. Complete friend/profile/activity destinations, the remaining signal-detail actions, and owner controls, real place search/drop-pin, notification delivery, and sharing.
4. Verify failures, permissions, reconnect/relaunch, capacity races, time boundaries, accessibility, and chosen device layouts before beta distribution.

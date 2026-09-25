# Next session

Updated September 25, 2026. Work is on `codex/account-foundation`; commits are local and have not been pushed.

## Latest capture and AI work

Live camera/audio capture now streams audio into Apple on-device speech transcription. Saving a clip sends its final transcript to the deployed `draft-hang` Edge Function and Jev; uncertain fields stay blank, and place names require map confirmation. The private request-budget migration is deployed. Videos remain local. See [the implementation and device-test checklist](invitation-ai-research.md).

Apple place search is now implemented: spoken venue queries use a fresh foreground location fix and return at most eight candidates for Jev. The selected ID resolves to Apple's coordinates on device; uncertain matches stay blank. The location picker uses real Apple search, optional GPS, and a map fallback. It no longer treats sample places as confirmed venues. Hosted `draft-hang` is version 2, with the existing authentication/quota checks. No new database migration or API key is needed.

Earlier capture verification: `build/check.YIFhyE` passed local account/contact/quota API tests, 12 backend unit tests, 24 Swift tests, unsigned Release iPhone build and map geometry checks. These tests use a mocked Jev response; a signed-in physical iPhone → live transcription → live Jev test remains outstanding.

New commits: `c329338` (capture/transcription), `6d3c173` (Jev backend/quota), `2153b13` (editable draft integration). Hosted `draft-hang` version 2 requires JWT verification; migration `20260925195503_hang_draft_limits.sql` matches local and hosted history.

Apple-search commits: `b88bb96` (bounded venue classification), `dae2b0d` (client lookup and review).

Latest Apple-search verification: `build/apple-places/` has 15 passing backend tests, 15 passing focused Swift tests, and successful Debug/unsigned Release builds. Live Apple search and allowed/denied location paths were checked in Simulator. Real iPhone capture → Jev classification remains unverified.

## Ready to review

- Optional contact sync follows profile setup. People shows matched, verified/discoverable contacts first and other contacts below with Invite actions. Full/limited access, skipping, later opt-in, search, stop sync, and native invitation composers are implemented. The private phone-matching backend is deployed; **SMS-provider setup and a real invite download URL are still needed**. See [contacts setup and limits](contact-discovery.md).
- The Cocoa & Orchid palette uses orchid actions/highlights and warm cocoa/ivory surfaces. **The map panel must keep native Liquid Glass in light mode and a dark translucent surface in dark mode; no opaque black/cocoa light-mode panel.** See [palette details](ux-refinement.md#cocoa--orchid-palette).
- Product wording is now **hangs** throughout the app: tabs, composer, details, friend notes, notification descriptions, and accessibility labels. The default heading is **Today**, with a full-width orchid **Let’s hang** button pinned below both overview tabs. The small toolbar plus and redundant count row are removed. Today anticipates future time browsing; it does not add date filtering or schedule persistence. Internal Swift model names and stable automation identifiers retain `Signal`/`signal`.
- Hang markers use activity emoji badges instead of the green broadcast symbol. A title emoji takes priority; otherwise local keyword matching chooses an activity emoji, with 👋 for an unspecified hang. This applies to sample and newly posted hangs, the focused marker, and hang links on friend profiles. Debug build passed (`build/ux/hang-emoji-build.log`); the simulator showed 🍝 for dinner, 🚶 for walking, and ☕️ on a newly posted coffee hang.
- Hang details sit directly on the main sheet: no redundant “Hang” navigation title or nested shaded card. Attendance and group limit share a compact row, stacking at accessibility text sizes, and Join remains pinned below the scrollable content. Debug build passed (`build/ux/flat-hang-details-build.log`); simulator checks covered the half-height layout, joining, and expanded dark appearance with accessibility-large text.
- The repository opens and builds in Xcode with the existing Apple team `36P3GQ337U` and bundle ID `wurms.whoisintownrightnow`.
- Supabase has private profiles, account settings, and avatars. Native Apple sign-in, resumable onboarding, editable name/photo, and Settings are implemented in Swift. Real Apple authorization still needs the configuration below.
- Settings preserve Exact/Vicinity and Off/Direct invites only/All. Saves are atomic and reject stale versions, including simultaneous saves from two devices.
- Sessions restore through Keychain. Network failures preserve the session and show retry. Photo failures have their own retry, and image processing downsizes, normalizes orientation, and strips location metadata.
- The [native iOS refinement](ux-refinement.md) adds a Find My-inspired map, Liquid Glass controls, real system sheet detents, People/Signals lists, profile cards, and native composer/settings forms. Larger accessibility text uses expanded sheets and stacked rows.
- Map appearance, recenter, and profile/settings form a compact glass group at the top right. The profile editor is also usable in Debug map preview with clearly labeled, temporary name/photo/preferences; authenticated saves still use Supabase.
- Map focus follows a signal from its host to its destination. The expanded list scrolls through every signal. Row and Join actions are separate, and joined/owned signals cannot be joined again.
- Posting waits for actual composer dismissal before presenting confirmation. Preview copy identifies sample data and does not claim invites or texts were sent. “Share this plan” opens the native share sheet with plan text.

Run `./scripts/check.sh` for local database/API tests, simulator XCTest, an unsigned Release iPhone build, and signal geometry checks. It uses disposable local accounts and does not test against the hosted project. See [account setup](account-setup.md) for prerequisites and detailed coverage.

Final verification passed: all local API checks, five XCTest cases with zero failures/skips (three account integration cases and two composer draft cases), Debug simulator and unsigned Release device builds, and geometry checks. Simulator interaction checks covered separate Join/row actions, three consecutive posts, reaching/opening the fifth list item, and the native share sheet. Hosted security/performance advisors reported no findings after the second migration. The local test stack is stopped with its volumes retained; disposable test accounts were removed. The only build warning was Xcode skipping App Intents extraction because the app has no App Intents dependency.

The September 25 profile/toolbar pass repeated the full check successfully in `build/check.gBVeBl`. Manual checks covered saving/reopening profile preferences and a sample photo, canceling edits, opening the editor from the compact toolbar, dark appearance, and accessibility-large text. See [UX verification](ux-refinement.md#verification).

## Configuration needed to test real Apple sign-in

1. Add an Apple Developer account belonging to team `36P3GQ337U` in Xcode Settings → Accounts. The signed-device build currently reports that this team has no account/profile available on this Mac.
2. Confirm Sign in with Apple is enabled for `wurms.whoisintownrightnow` in Apple Developer under the intended publishing team. **Supabase provider enablement is complete:** the live settings endpoint returned `external.apple: true` on September 25, and the user's screenshot shows the matching Client ID. Keep nonce checks enabled.
3. Complete first authorization and a returning sign-in on a provisioned build. Confirm the name/photo and settings restore after relaunch and sign-out/sign-in.

The September 25 native simulator attempt reached Apple's “Sign in to your Apple Account” prompt, which requires signing in through the simulator's Settings. No real Apple token exchange or hosted onboarding has been completed. A fresh device build with automatic provisioning updates still reports no account for the configured team and no development profile. See [verification details](account-setup.md#apple-sign-in-verification--september-25).

## Decisions for our next discussion

These are proposals for discussion, not decisions made overnight.

| Topic | Decision needed | Starting point to discuss |
| --- | --- | --- |
| Location | Update frequency, stale-location timeout, background sharing, and whether an exact event venue is allowed while the person shares Vicinity. | Start with foreground updates; hide stale locations; treat deliberate event destinations separately from the person's live location. |
| Friends and identity | How account matches become friends; whether accepting is required; unique handles versus names. | Contact discovery is implemented using optional verified phone numbers. Mutual acceptance before sharing location remains a proposal. |
| Signal audience | Who can see a signal versus who receives a direct invitation; whether nearby friends are selected automatically. | Make visibility and invitation selection explicit. All three notification modes and Off blocking new direct invites are already confirmed. |
| Join and capacity | Whether Join is an RSVP, host approval, or opening a conversation; whether the cap counts guests or the total group; leaving/cancellation. | Choose one membership model before implementing transactional capacity or message handoff. |
| Time and availability | Schedule persistence, when a signal becomes visible, when it expires, and what “free” means. | Store real start/end timestamps; settle visibility and expiration rules before implementing a live feed. |
| Messages and existing invites | Whether sharing targets invitees, attendees, or a chosen conversation; whether pending invites remain actionable after switching Off. | Keep the user-chosen share sheet now. New direct invites must be blocked when Off; treatment of existing invites remains open. |

## Still unfinished

The map/social side remains a prototype: sample friends and coordinates; venue search limited to fixtures; scheduled dates formatted into display-only signal labels; draft schedule/radius/recipient fields lost on posting; posts and joins held only in memory. There are no live friend relationships, durable signals, location publication, invitation backend, APNs delivery, attendance synchronization, or automatic Messages handoff.

The composer now has a movable-map pin picker, consistent selected coordinates, a native calendar/time picker, and past-date validation. Those improvements do not persist a schedule, enforce a radius, or deliver invitations.

The account foundation does **not** implement those social features. In particular, saving Off is not yet end-to-end invite enforcement because there is no invite-creation API. Saving Vicinity does not publish an obfuscated location because nothing publishes live locations yet. Existing profiles and avatars are owner-only until accepted-friend/block authorization exists.

Account deletion, Apple revocation, and a server cleanup process for orphaned avatar uploads are required before release. Offline photo cleanup remains best effort.

The [original product audit](product-audit.md) inventories every code path and records the initial gaps. Its historical rows should be read alongside the fixes above. The [data design](account-data-design.md) separates deployed account tables from proposed social tables.

## Commit boundaries

| Commit | Scope |
| --- | --- |
| `44322f0` | Existing map focus/connection work and geometry checks. |
| `09454c0` | Account database, private Storage policies, and local API integration tests. |
| `fcdc7d5` | Native Apple client, onboarding/settings, SDK dependency, and session integration tests. |
| `1b523af` | Initial product audit, data design, setup notes, and existing README work. |
| `36f3cd7` | Account save conflict detection and race tests. |
| `75268b9` | Photo failure recovery, bounded decoding, metadata/orientation checks, and scrollable welcome. |
| `bd05a0b` | Map list/actions, reliable confirmation, truthful preview copy, native sharing, and accessibility controls. |
| `da12203` | One-command local database, simulator, Release build, and geometry verification. |
| `b1b1777` | Native map sheets, People/Signals navigation, glass controls, and semantic colors. |
| `b763aec` | Native composer and pickers, actual draft dates and pin coordinates, and draft tests. |
| `be05189` | Native welcome/onboarding/settings presentation. |
| `8c46ba2` | Larger-text row layouts, appearance refresh, profile avatar, and selection contrast. |
| `8508676` | Restore Happening now and signals as the default panel. |
| `1bcf741` | Move profile/settings beside the top-right map controls. |
| `ed9e421` | Complete the shared profile editor, isolated Debug preview editing, and compact glass control group. |

Documentation updates are separate from implementation. No social backend or unresolved product rule was added in this UX pass.

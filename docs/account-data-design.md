# Account, settings, and storage design

Updated September 24, 2026. This records the product decisions and broader backend design. The first account slice is now implemented: Supabase project `pqliwxrxmeycdjptqpks`, profile/settings tables, private avatars, native Apple sign-in client, session restoration, onboarding, and Settings. The Apple provider still needs dashboard/Apple Developer configuration before a real Apple login can be verified. See [implementation and setup](account-setup.md).

Only `profiles`, `user_settings`, account RPCs, and the private `avatars` bucket are deployed so far. Friendships, shared locations, invitations, notifications, deletion, and the lifecycle rules described below remain future implementation work. Profile and avatar reads are currently owner-only. Defaults are Vicinity and Off; photo is optional in this first slice.

**Confirmed product decisions**

- Every user has a settings page.
- Location sharing has two choices: Exact location, shared with all friends; and Vicinity, a rough area with a half-mile radius.
- Notification modes are Off, Direct invites only, and All notifications (including nearby signals).
- Off prevents friends from creating new direct invites. It does not mean silently collecting new invites.
- The first sign-in method is native Sign in with Apple. Email sign-in comes later.
- Name and profile photo must be stored with the user's account and restored on later sessions.

The defaults, update cadence, friend-discovery flow, photo requirement, and treatment of already-existing invites below are proposals, not additional confirmed decisions.

**Recommended stack**

Use hosted Supabase with PostgreSQL, the PostGIS extension, Supabase Auth, and Supabase Storage. Keep SQL migrations and authorization tests in the repository when implementation starts.

| Option | Relevant strengths and tradeoffs | Assessment for this app |
| --- | --- | --- |
| Supabase / PostgreSQL | Relational data and database authorization; PostGIS provides spatial types and indexed geographic queries; Swift support covers auth, data, and file uploads. | Recommended. Friend relationships, invitation eligibility, attendance, and settings are naturally related records. |
| Firebase / Firestore | Apple-platform offline persistence is built in. Its documented geographic-query approach uses geohashes, multiple query ranges, and filtering of false positives. | Viable, especially if automatic offline synchronization becomes the priority. I prefer the relational model here. |

These are design judgments based on this app's requirements. Supporting platform documentation: [Supabase Swift user-management guide](https://supabase.com/docs/guides/getting-started/tutorials/with-swift), [PostGIS](https://supabase.com/docs/guides/database/extensions/postgis), [database authorization](https://supabase.com/docs/guides/database/postgres/row-level-security), [Firestore offline behavior](https://firebase.google.com/docs/firestore/manage-data/enable-offline), and [Firestore geographic queries](https://firebase.google.com/docs/firestore/solutions/geoqueries).

Supabase would be the shared source of truth. The phone can cache its own profile/settings for display, but friendship access, invite eligibility, and authoritative writes are checked online. Live friend locations should use a short-lived memory cache rather than a durable offline location history. Push delivery still needs a server worker and Apple Push Notification service (APNs); choosing Supabase does not implement push delivery automatically.

**Where information lives**

| Store | Data | Access |
| --- | --- | --- |
| Supabase Auth | Stable account UUID, linked Apple identity, authentication email/relay address, sessions. | Managed authentication service. Email is private and is not the public profile identifier. |
| PostgreSQL `profiles` | `id UUID PK/FK → auth.users.id`, `display_name`, optional `avatar_path`, `onboarding_completed_at`, `created_at`, `updated_at`. | Owner edits; accepted friends see approved profile fields. Any pending-friend-request identity preview needs its own narrow access path. |
| PostgreSQL `user_settings` | `user_id UUID PK/FK`, `location_mode: exact / vicinity`, `notification_mode: off / direct_only / all`, `location_sharing_confirmed_at`, `privacy_revision`, `updated_at`. | Owner reads/changes. Sensitive changes go through authenticated server operations. Friends may receive limited derived capabilities, such as whether inviting is allowed, rather than the whole settings row. |
| Private Storage bucket `avatars` | Image bytes at a versioned object key such as `{user_id}/{image_id}.jpg`. | Owner uploads/replaces; owner and eligible friends can fetch through authenticated access. Store the object key in the profile, not a permanently public URL or image bytes in PostgreSQL. |
| PostgreSQL `shared_locations` | One current row per user: `shared_point geography(Point,4326)`, `effective_mode`, `radius_m`, `observed_at`, `expires_at`, `privacy_revision`. | Owner and currently accepted, unblocked friends read a fresh authorized location. Only the trusted publication operation writes it. |
| PostgreSQL `friendships` | Canonical pair of account UUIDs, requester UUID, `pending / accepted`, creation/acceptance timestamps; unique pair and no self-relationships. | Participants only; only the recipient can accept a request. Location access requires accepted status. |
| PostgreSQL `blocks` | `blocker_id`, `blocked_id`, timestamp; unique directed pair. | Owner manages; either-direction block denies sharing and invitations. Friend-removal/blocking UI is a later slice, but access checks need this rule. |
| Server-private `push_devices` | Installation ID, owner UUID, APNs token, environment, observed permission status, last-seen time, disabled-at time. | Owner can register/unregister through a restricted endpoint; tokens are available only to delivery code. Account setting applies across devices; OS permission is per device. |
| iOS Keychain | Authentication session credentials through the SDK's secure storage integration. | Device-local. Never store sessions in public profile fields or normal preferences. |
| Phone-local display cache | Own profile/settings, non-authoritative UI state. | Cleared or separated on account change. Failed writes must not be presented as successful cross-device updates. |

Use the Auth UUID as the common identity throughout the app. Names, initials, emails, and phone numbers are not foreign keys. A user can rename themselves or later add another sign-in method without changing friendships or posted signals. Initials, display colors, distance labels, `isMine`, and `isJoined` should be derived for the UI.

Keep application profile fields in the profile table rather than treating provider metadata as the editable profile database. Supabase documents the pattern of application profile rows referencing `auth.users`. [User-management data model](https://supabase.com/docs/guides/auth/managing-user-data)

Private Storage supports authorized downloads; public buckets allow anyone with the URL to fetch the file. Use private access for this friends-based app. Re-encode/crop uploads and strip location metadata before storing an avatar. Upload to a new object key, save the confirmed key to the profile, then clean up the old object. An upload and database update are separate operations, so failed uploads/profile saves need retry and orphan cleanup. [Storage access models](https://supabase.com/docs/guides/storage/buckets/fundamentals)

**Notification settings and invite enforcement**

Use one account-level enum, avoiding contradictory combinations of separate “enabled” and “allow invites” switches.

| Mode | New direct invites | Direct-invite alerts | Nearby-signal/general social alerts |
| --- | --- | --- | --- |
| Off | Rejected by the server | No | No |
| Direct invites only | Allowed from accepted, unblocked friends | Yes, when the device permits alerts | No |
| All notifications | Allowed from accepted, unblocked friends | Yes, when the device permits alerts | Yes, when the device permits alerts |

These settings do not change which ordinary friend signals the user can view on the map. Sign-in messages and account operations are separate from social notifications.

The sender UI can hide/disable invite actions, but `create_direct_invite` must check the authenticated sender, friendship, blocks, signal eligibility, and the recipient's current mode. Use a transaction and serialize against settings changes so a simultaneous opt-out cannot be ignored. Friends cannot directly insert arbitrary invitation rows. Re-check eligibility before a queued push is sent; switching Off cancels unsent social delivery work. Already delivered notifications cannot be withdrawn from another device by changing a database preference.

Proposed treatment of history: keep invites received before opting out visible as existing history, subject to normal expiration, while preventing new ones. Whether already-pending invites should remain actionable is still a product choice.

If iOS notification permission is denied, the app may still accept invites in Direct-only/All mode and show them in-app. Explain the device restriction in Settings. Do not silently rewrite the user's account-level preference to Off. APNs tokens must be updated and detached from an account on logout/account switching.

**Exact versus half-mile vicinity**

Half a mile is 804.672 meters. This is a product sharing radius, not a guarantee about GPS measurement accuracy.

Proposed publication contract:

1. The device obtains a location sample only after the user has chosen a sharing mode and permitted location use.
2. An authenticated publication endpoint reads the current account mode and privacy revision. It computes and stores the friend-visible representation before exposing it to friends.
3. Exact mode stores the current measured point with its timestamp and effective accuracy. Vicinity mode stores only a coarse area center and approximately 805-meter display radius, not the original exact point.
4. Use stable, predefined coarse regions with a reviewed size/coverage rule. Do not repeatedly add random jitter: repeated samples can be averaged, and arbitrary degree-rounding changes size by latitude.
5. Raw input needed to produce a vicinity area is transient: do not retain it in database history, payload logs, notification payloads, or telemetry. The backend still briefly receives it in this proposed design; it is not a claim that exact location never leaves the phone.
6. In vicinity mode, distances and nearby matching use the shared coarse representation, not a hidden exact-distance result. Label distance estimates accordingly.
7. Maintain a timestamp and expiration on the current row. A stale location must disappear or be explicitly labeled stale, not silently presented as “right now.”

A circle centered exactly on the real point still reveals the real point. Returning the exact point in an API and drawing a fuzzy circle in SwiftUI does not implement vicinity sharing. The same rule applies to the host-to-destination connection now being added to the map.

Changing Exact → Vicinity must atomically downgrade or remove the previous shared point and advance `privacy_revision`. Reads reject mismatched/stale revisions; in-flight publications re-check current settings. First-party clients invalidate cached locations after a change, but previously seen exact locations cannot be made unknown again.

Do not copy exact host coordinates into every signal permanently. Prefer deriving the displayed host anchor from the currently permitted location. If a posting-time anchor is required, store only a privacy-approved representation and include it in precision-downgrade handling. The current `Signal.anchorCoordinate` snapshot needs to change when the real model is introduced.

A deliberately selected event venue/destination is a separate data item. Whether selecting an exact destination is allowed while the profile uses Vicinity needs explicit product copy/confirmation: an event venue may disclose where someone intends to be even when their live location is coarse.

Proposed first version: location updates while the app is in use, with a freshness timeout and “last updated” label. Background updates and the timeout duration are not yet decided. Do not automatically add an Off location setting beyond the two requested choices; absent consent/permission or a stale sample is an operational “no shared location” state.

iOS's reduced-accuracy permission can supply a broader region than our half-mile target. If a sample is too imprecise, do not claim it is exact or invent an 805-meter certainty; show location unavailable/limited or ask for the necessary precision at the point of use. [Apple location authorization](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services), [accuracy authorization](https://developer.apple.com/documentation/corelocation/cllocationmanager/accuracyauthorization)

**Sign-in and onboarding: Apple first**

Proposed flow:

`Restore session → Welcome / Continue with Apple → Confirm display name + optional photo → Choose location sharing → Choose notifications → Map`

Returning users skip completed onboarding. Signed-in users with an unfinished profile resume it. An unavailable network is an error/retry state, not evidence that an account does not exist.

- Use native Apple Authentication Services and exchange the identity token with Supabase Auth, with nonce validation. Apple identity maps to a stable Supabase account UUID.
- Capture Apple's provided name on the first authorization and persist it promptly. Subsequent authorizations may not supply the name; never overwrite a saved name with an absent provider value.
- Let users confirm/edit their display name. Offer an image picker for their avatar with initials as the proposed fallback; do not design around automatically receiving an Apple profile picture.
- Bootstrap profile/settings rows idempotently. Persist updates before setting `onboarding_completed_at`; repeated sign-in or a retry must not reset user choices.
- Proposed initial rows: Vicinity and Off, with no location published until sharing is explicitly confirmed. The user can select Direct-only/All during onboarding. These are recommended defaults, not additional decisions already made.
- Ask for location permission when enabling sharing, and notification permission after the user opts into alerts. Permission denial should not prevent profile creation or settings access.
- Settings remains accessible from the profile and includes editable name/photo, both sharing choices, the three notification modes, device-permission status, sign out, and an account-deletion path.
- Use provider/account IDs for identity. Apple relay email is not a reliable way to match friends or automatically merge a later email account.

Supabase supports native Apple authentication; Apple's name must be captured on first sign-in. [Native Apple sign-in](https://supabase.com/docs/guides/auth/social-login/auth-apple)

Email is deferred. When added, email verification codes are supported, but a real delivery provider must be configured for beta/production email. Account linking needs an explicit authenticated flow; a new email login must not silently create a second profile for an existing Apple user. [Email codes](https://supabase.com/docs/guides/auth/auth-email-passwordless), [email delivery setup](https://supabase.com/docs/guides/auth/auth-smtp)

**How signals connect later**

These are planned records, not extra work required before the first sign-in screen:

| Record | Core fields / relation |
| --- | --- |
| `signals` | UUID, host UUID, title, structured destination (point or area, label, radius), starts_at, ends_at, status, capacity once its meaning is decided. Display strings are derived. Host live/shared location is obtained through the authorized location model. |
| `signal_participants` | Unique signal/user pair, membership status and timestamps. Joining/leaving and capacity changes happen transactionally. |
| `signal_invites` | Signal, sender, recipient UUIDs, status/timestamps; unique invitation policy and idempotency key. Recipient opt-out is enforced at creation. |
| `notifications` | Recipient UUID, event kind, related record ID, read_at. No precise coordinates or credentials in payloads. |
| Server-private `notification_jobs` | Event/recipient/device reference, dedupe key, attempts and delivery state; preference checked before sending. |

The exact feed visibility, join/capacity semantics, and expiration rules from the audit remain open. Location sharing with all friends does not automatically settle visibility for every signal. None of these tables should trust client-supplied ownership flags or attendee initials.

**Access and lifecycle implementation rules**

Enable row-level security and explicit grants on exposed tables, with policies for each operation. Account settings are owner-only. Friend location/profile access requires the current accepted relationship and absence of blocks. A location query must exclude everyone else before returning coordinates; hiding markers in the app is insufficient.

Use server operations for settings/precision changes, location publication, friendship transitions, inviting, and joining where multiple records must stay consistent. Keep admin credentials and APNs signing material on the server. The iOS app uses a publishable project key plus the user's session. All custom functions need narrow grants and caller checks. [Supabase authorization](https://supabase.com/docs/guides/database/postgres/row-level-security)

Account deletion must remove app records, avatar objects, push registrations, and the auth identity; deleting a profile alone is not account deletion. Sign out clears account-specific caches and unregisters that installation. A later implementation must handle authentication revocation and active sessions as part of this flow.

**Next implementation slice**

1. Confirm the Supabase project owner/environment and Apple Developer team/bundle ID; configure native Apple sign-in.
2. Add version-controlled profile/settings migrations, idempotent bootstrap, private avatar storage, and authorization policies.
3. Add an app-level session store and auth gate, replacing the hardcoded “You”/“JD” identity with the signed-in profile.
4. Build Apple sign-in, resumable name/photo setup, and the Settings page. Persist settings account-wide even before live location/push features are connected.
5. Validate account/session restore, avatar persistence, interrupted onboarding, returning Apple login without a name, account switching, and cross-user access restrictions.
6. Add real location publishing and invitation/push enforcement as separate slices using the already-persisted settings. Do not claim sharing or notifications are active until those integrations exist.

Before the backend goes live, test that non-friends cannot fetch profiles/locations/photos; Off rejects even handcrafted invite requests; queued notifications respect opt-out; exact-to-vicinity changes do not expose stale precise fields; and multiple logins/devices preserve settings.

Still to settle before the affected feature ships: backend project ownership; whether photos are optional; name versus a unique public handle; location freshness/background cadence; how exact event destinations interact with Vicinity; and treatment of pre-existing pending invites.

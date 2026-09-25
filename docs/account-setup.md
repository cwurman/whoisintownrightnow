# Account implementation and setup

Implemented September 24, 2026 against Supabase project `pqliwxrxmeycdjptqpks`.

## Implemented

- Native Apple sign-in with a cryptographically random nonce; Apple’s one-time name is copied into account metadata before profile setup.
- Supabase Swift 2.55.2, pinned in Xcode with `Package.resolved`. Sessions use the SDK’s iOS Keychain storage. Relaunch restores the session and loads the saved account; network errors show Retry instead of pretending a new account is needed.
- Resumable onboarding and Settings: display name, optional photo, Exact/Vicinity, Off/Direct invites only/All, save failure handling, and sign out of this device.
- Private avatar uploads with bounded image dimensions, newly encoded JPEG bytes, unique versioned paths, and cleanup of the previous image after a successful save. Profile stores a path rather than a public URL.
- Atomic `save_account` RPC and idempotent `bootstrap_account`. Database constraints, grants, and RLS isolate each user’s profile/settings; Storage policies isolate avatar reads/writes.
- The map’s profile button opens Settings and uses the signed-in user’s photo/initials. Local prototype posts and joins use that identity.

The hosted migration version is `20260925052021_account_foundation.sql`, matching the repository and local migration history. Security and performance advisors returned no findings after deployment. No real user accounts were created by tests.

Verified: Debug simulator build and launch, unsigned Release iPhone build, both simulator XCTest cases (0 failures), the local Auth/REST/Storage integration suite, and the existing signal-geometry tests. The simulator suite also verifies that an offline load preserves the session and presents a retry state. The local Supabase stack was stopped after testing, retaining its volumes.

Signed-device verification is blocked by Xcode configuration: even with `-allowProvisioningUpdates`, Xcode reports **No Account for Team "36P3GQ337U"** and no development profile for `wurms.whoisintownrightnow`. Add an Apple Developer account belonging to that team in Xcode Settings → Accounts before provisioning a device build.

## Apple configuration still needed

User confirmed existing team `36P3GQ337U` and bundle ID `wurms.whoisintownrightnow`.

1. In [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/list/bundleId), select this App ID under this team and enable **Sign in with Apple**. A team member with the appropriate permissions must do this if it is not already enabled.
2. In [Supabase → Authentication → Sign In / Providers](https://supabase.com/dashboard/project/pqliwxrxmeycdjptqpks/auth/providers), enable **Apple**, adding `wurms.whoisintownrightnow` under **Client IDs**. Keep nonce checks enabled.
3. Open the Xcode project, select the confirmed team, and allow Xcode to obtain a provisioning profile containing the new capability. The entitlement is already in source control.
4. On a signed build and a device/simulator with an Apple account, exercise first authorization, cancellation, returning sign-in without a name, app restart, name/photo edits, settings changes, and sign out.

This uses native identity-token exchange. A web Services ID, `.p8` key, and rotating OAuth client secret are not needed for the native-only flow. [Supabase native Apple configuration](https://supabase.com/docs/guides/auth/social-login/auth-apple#configuration-swift-native)

## Local checks

Local Supabase ports are 55421 (API) and 55422 (database), keeping them separate from the default stack. Docker must be running.

```sh
supabase start -x realtime,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor
python3 Tests/account_backend_test.py
supabase status -o json > whoisintownrightnowTests/LocalSupabase.json
xcodebuild -project whoisintownrightnow.xcodeproj -scheme whoisintownrightnow \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData test
```

`LocalSupabase.json` is ignored and included only in the test bundle, never the app. Tests refuse hosted URLs. The API tests create disposable local accounts and clean them up; they cover idempotency, settings validation/rollback, session refresh, cross-user and anonymous denial, private avatars, and cascading profile cleanup. The simulator integration test exercises the actual Swift store, JPEG processing, save, Keychain-backed restoration, photo download/removal, and logout. Native Apple authorization itself cannot be substituted by these tests.

Run `supabase stop` from this repository to stop its local stack while retaining local data. For map-only design review, add `--preview-map` to the Xcode scheme’s launch arguments in Debug; this bypass is absent in Release.

## Remaining scope and decisions

- The map, friends, event posting/joining, and message handoff still use local fixtures. A real account does not make these social features live.
- Settings persist now; live location publication, coarse-region calculation, friend access, direct-invite rejection, nearby alerts, and APNs delivery are subsequent slices. No location/push permission prompt is shown before those features exist. Off is stored for the future invite API; there is no invite-creation backend yet.
- Photos/profiles are owner-only until accepted-friend and block policies exist. This avoids exposing them to every signed-in user while friend relationships are unfinished.
- Account deletion (including session invalidation, Apple token revocation, avatars, and Auth identity) must be implemented before release. Sign out is not deletion.
- Upload and profile-save are separate services: an interrupted/failed save can leave an unreferenced private image. Old-image cleanup is best effort; a server cleanup job for unreferenced images is still needed.
- Defaults and optional-photo behavior are implementation assumptions: Vicinity, Off, optional image, editable non-unique display name. Public handles, pending-invite behavior after opting out, location update cadence/freshness, and exact event destinations in Vicinity mode remain product decisions in the design/audit documents.

When location/invitation tables are introduced, tighten settings writes to server operations that also invalidate stale exact coordinates and cancel queued delivery. The current owner-only settings API intentionally handles preferences only; it must not be treated as complete privacy enforcement for future location tables.

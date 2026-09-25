# Native iOS refinement

September 24, 2026. This pass takes visual cues from Find My and uses the iOS 26 system components supplied by the installed iOS 26.5 SDK.

## Map and people

- A full-screen MapKit map with quieter circular people markers, names, and activity emoji badges. The original yellow/black cards and bat-shaped floating button are replaced with native controls and the Cocoa & Orchid palette described below.
- Native sheet detents (compact, medium, expanded), system corner treatment and material, scrollable People/Signals lists, and background map interaction. System sheets own their presentation rather than imitating a sheet with a fixed overlay.
- September 25 correction: the bottom panel opens to signals under “Happening now.” People remains a secondary tab; Find My informs the styling, while plans remain the default focus.
- Liquid Glass map appearance/recenter controls and native glass toolbar actions. Glass is concentrated in controls and navigation; lists and forms use standard system surfaces.
- September 25 profile pass: map appearance, recenter, and profile/settings now share a compact glass capsule at the top right. Each control retains a 44-point tap target. The profile action no longer occupies the bottom panel toolbar; “Happening now” remains the default heading.
- At accessibility text sizes the sheet opens expanded; people metadata and signal actions stack vertically. Marker labels remain bounded while the full names are available in accessible controls and the list.
- People open a detail card with the existing profile/location fixture and links to their signals. Selecting a signal retains the animated host-to-destination connection.
- Map fitting waits for the sheet size to settle. The Join action stays visible above the bottom edge while the details scroll.

## Composer and account

- Native navigation stacks, grouped forms, text input, segmented controls, date/time selection, duration picker, capacity stepper, searchable recipient/place lists, and toolbar confirmation actions.
- Scheduled plans now use a real date in the draft and reject past dates. Signal persistence and expiration remain future backend work.
- A working movable-map pin picker replaces the fabricated coordinate. Venue suggestions remain explicitly labeled sample places. The chosen point is used consistently by the preview and posted local signal; area previews are centered on the sample user coordinate.
- System sharing from a native confirmation sheet. No claim that invitations or notifications were sent.
- A simpler welcome screen with semantic surfaces and an Apple button that adapts to light/dark appearance. Sign-in stays reachable below the scrollable introduction.
- Settings use native navigation pickers, a toolbar Save action, and standard grouped sections. Onboarding keeps location/notification choices visible and has a pinned Continue action.
- Profile & settings includes a centered avatar, independent Add/Change/Remove photo actions, editable name with live initials, Exact/Vicinity, and Off/Direct invites only/All. Save applies the draft; Cancel leaves saved values unchanged. Signed-in users retain private Supabase persistence and sign out.
- Debug map preview opens that same editor with an explicitly labeled, temporary profile. It supports trying the page before Apple account setup is complete; it makes no Auth/Storage requests and is compiled out of Release.

## Scope

This is a presentation and interaction pass. Auth, account persistence, privacy choices, and the deployed schema are unchanged. Apple developer provisioning and a real authorization test are still required; the Supabase Apple provider was enabled and checked on September 25. Friends, coordinates, signals, and joins remain local preview data. No invitation delivery, social audience rule, background location behavior, or capacity policy was added.

## Cocoa & Orchid palette

- Based on the user's September 25 reference: pastel orchid (`#E6B5F4`) for filled actions, avatar rings, and map highlights; cocoa (`#332521`) for text on orchid. Avatar fills stay within cocoa, clay, and muted purple tones.
- **Keep the map panel's native Liquid Glass appearance:** translucent light material in light mode, dark translucent material in dark mode. Do not force dark appearance or an opaque cocoa/black panel in light mode. This is an explicit user correction.
- Profile/settings, the composer, and selection lists use warm ivory surfaces in light mode and dark cocoa surfaces in dark mode. Native controls, system Apple sign-in colors, and semantic destructive/error colors are retained.
- Adaptive colors live in the asset catalog: AccentColor, AppBackground, AppSurface, AppLabel, and AppSecondaryLabel. Plain text actions use a deeper orchid in light mode for legibility; filled orchid actions use cocoa text. The base solid-color contrast is 8.60:1 for cocoa on orchid and 5.47:1 for the light-mode accent on ivory.
- Verification: Debug simulator and unsigned Release iPhone builds passed (`build/ux/cocoa-orchid-debug.log`, `cocoa-orchid-release.log`), along with the standalone geometry checks. Visual checks covered the native light/dark glass map panel, hang details, composer, and profile/settings surfaces. The corrected panel screenshots are `build/ux/cocoa-orchid-map-light.jpg` and `cocoa-orchid-map-dark.jpg`.

## Verification

- September 25 profile pass: `scripts/check.sh` passed again with all local API checks, five XCTest cases (zero failures/skips), Debug simulator tests, unsigned Release build, and geometry checks. Results are in ignored `build/check.gBVeBl`; the run summary is `build/ux/profile-settings-check.log`.
- The shared profile editor was exercised through Debug preview: saved name, Exact location, Direct invites only, reopened saved values, canceled a subsequent name edit, and selected/saved/reopened a simulator sample photo. The final compact toolbar opens it correctly. Dark appearance and accessibility-large text preserve readable settings and notification choices. Screenshots are in `build/ux/map-profile-controls.jpg`, `profile-settings.jpg`, and `profile-settings-large-dark.jpg`.
- `scripts/check.sh` passed: the local Auth/REST/Storage isolation and conflict suite, five XCTest cases with no failures/skips, unsigned Release iPhone build, and signal geometry checks. Results are in ignored `build/check.nrjyni`.
- After the final appearance/accessibility adjustments, both Debug simulator and unsigned Release iPhone builds passed again (`build/ux/final-debug.log` and `final-release.log`). The only warning is skipped App Intents metadata extraction because the app has no App Intents dependency.
- iPhone 17 Pro / iOS 26.5 visual checks covered light/dark maps and welcome, live appearance switching, larger accessibility text, People/Signals navigation, focused map endpoints, the pinned Join action, composer navigation, opening/accepting a dropped pin, repeated local posts, confirmation, and the native share sheet. No share recipient was selected.
- Screenshots are in ignored `build/ux/map-light.jpg`, `map-dark.jpg`, `signal-dark.jpg`, and `composer-dark.jpg`.
- Automated map-drag gestures did not move the simulator viewport, so physical drag placement still needs a hands-on check. Draft tests verify that supplied pin coordinates survive selection and match the posted point; opening/accepting the current point was checked in the UI.
- Real Apple authorization and a signed device build remain dependent on the setup in [account setup](account-setup.md). The same Settings form was visually checked using isolated Debug preview data; hosted authentication was not bypassed and no live account was created. iPad and physical-device visual review remain to be done.

## References

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)

The implementation uses native materials rather than raster artwork or a simulated glass shader. System controls inherit the platform’s appearance, motion, contrast, and accessibility behavior.

# Native iOS refinement

September 24, 2026. This pass takes visual cues from Find My and uses the iOS 26 system components supplied by the installed iOS 26.5 SDK.

## Map and people

- A full-screen MapKit map with quieter circular people markers, names, and small signal badges. The original yellow/black cards and bat-shaped floating button are replaced with system green, SF Symbols, and semantic colors.
- Native sheet detents (compact, medium, expanded), system corner treatment and material, scrollable People/Signals lists, and background map interaction. System sheets own their presentation rather than imitating a sheet with a fixed overlay.
- Liquid Glass map appearance/recenter controls and native glass toolbar actions. Glass is concentrated in controls and navigation; lists and forms use standard system surfaces.
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

## Scope

This is a presentation and interaction pass. Auth, account persistence, privacy choices, and the deployed schema are unchanged. Apple provider/provisioning setup is still required. Friends, coordinates, signals, and joins remain local preview data. No invitation delivery, social audience rule, background location behavior, or capacity policy was added.

## Verification

- `scripts/check.sh` passed: the local Auth/REST/Storage isolation and conflict suite, five XCTest cases with no failures/skips, unsigned Release iPhone build, and signal geometry checks. Results are in ignored `build/check.nrjyni`.
- After the final appearance/accessibility adjustments, both Debug simulator and unsigned Release iPhone builds passed again (`build/ux/final-debug.log` and `final-release.log`). The only warning is skipped App Intents metadata extraction because the app has no App Intents dependency.
- iPhone 17 Pro / iOS 26.5 visual checks covered light/dark maps and welcome, live appearance switching, larger accessibility text, People/Signals navigation, focused map endpoints, the pinned Join action, composer navigation, opening/accepting a dropped pin, repeated local posts, confirmation, and the native share sheet. No share recipient was selected.
- Screenshots are in ignored `build/ux/map-light.jpg`, `map-dark.jpg`, `signal-dark.jpg`, and `composer-dark.jpg`.
- Automated map-drag gestures did not move the simulator viewport, so physical drag placement still needs a hands-on check. Draft tests verify that supplied pin coordinates survive selection and match the posted point; opening/accepting the current point was checked in the UI.
- Real Apple authorization and a signed device build remain dependent on the setup in [account setup](account-setup.md). The authenticated Settings form was compiled; this visual pass did not bypass Apple authentication to create a live account. iPad and physical-device visual review remain to be done.

## References

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)

The implementation uses native materials rather than raster artwork or a simulated glass shader. System controls inherit the platform’s appearance, motion, contrast, and accessibility behavior.

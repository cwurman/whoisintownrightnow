# Contacts and People

Implemented September 25, 2026. People lists the contacts shared with the app: matching accounts first, alphabetically, then other contacts with a prominent Invite button. The existing map still uses sample friends and hang data; finding a contact does not create a friendship or publish a location.

## Onboarding and access

After profile setup, users can Sync contacts or choose Not now. This choice is scoped to the signed-in account on this device. Contacts are optional, and syncing can be enabled later from People → Manage contacts or Profile & settings → Contacts.

The system Contacts permission supports full, limited, denied, and restricted access. Limited access shows only the selected contacts, with the native contact access picker available to change the selection. Returning to the foreground rechecks permission. Contact-store notifications refresh the snapshot; revocation and Stop syncing clear the list and invalidate outstanding work. Sign-out clears in-memory data. Names, photos, and the address book are not persisted on our server.

Contact enumeration and international phone parsing run off the main actor. PhoneNumberKit is pinned to 5.0.11. Contact names, photos, original invitation addresses, and normalized numbers remain in memory. Contacts without usable phone numbers are still listed and can be invited through email or the share sheet.

## Matching and discoverability

The initial implementation uses optional **verified phone numbers**, the recommended default while the matching-method question is pending. Apple sign-in does not supply a phone number; Apple relay email addresses cannot reliably be matched to an address book. Email matching is not implemented.

Users can add a phone number during the contact onboarding step or from Contacts settings. The app updates the existing Apple-authenticated Supabase user, then verifies the OTP with `phone_change`; it does not create a second account. Users explicitly enable **Let contacts find me** after verification. Discovery is off by default.

The lookup accepts batches of at most 500 international numbers and a maximum of 10,000 submitted numbers per signed-in account per hour. It returns only the submitted numbers that match completed, verified, discoverable accounts. It excludes the caller, anonymous users, banned/deleted users, incomplete profiles, and unverified numbers. It does not return another user's profile, avatar, account ID, or location. Names/photos in People come from the local address book.

Only per-account discovery preferences and numeric lookup counters are stored in two RLS-enabled tables in the unexposed `private` schema. Authenticated clients cannot read either table. Public RPC wrappers use invoker rights; the private definer functions check the caller, inputs, verification and lookup budget before reading Auth. Profile/avatar RLS remains owner-only. The contact address book is not stored. Raw numbers are sent over HTTPS for matching; this is not a claim of anonymous or cryptographic private contact discovery.

Migration `20260925183200_contact_discovery.sql` is applied locally and to the hosted project. Security advisors report only the two expected informational “RLS enabled, no policy” notices on the deliberately inaccessible private tables; there are no warning/error findings, and performance advisors are clear. See [Supabase's explanation of this informational notice](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy).

A contact who has not verified a number or enabled discovery can appear in the Invite section despite already having an account. The list explains this limitation. Lookup failures are shown explicitly, with Retry, rather than asserting that all contacts are non-users. This is discovery only; friend requests, blocks, cross-account profile access and in-app invitations remain separate work.

## Invitations

Invite opens a recipient/channel choice and then the native Messages or Mail composer when available; Share invite is the fallback. The user reviews and sends the message. Nothing is sent automatically, and canceled/failed composers never mark the person as joined or invited. Debug sample contacts cannot send invitations.

The download URL is currently unset. Once there is a real TestFlight/App Store URL, add an HTTPS **AppInviteURL** string to the app's generated Info.plist (Xcode build setting `INFOPLIST_KEY_AppInviteURL`). `ContactInvitation.swift` appends it to the message. Until then the invite remains editable and prompts the sender to add a TestFlight link. No fabricated download URL is used.

## Required external setup

- **SMS:** hosted `/auth/v1/settings` currently reports phone authentication disabled. Configure a supported SMS provider, enable phone authentication with phone confirmation required, and test `update user phone` → `verifyOTP(type: phone_change)` on an Apple-authenticated account. Provider credentials and real SMS delivery are not configured or tested. Keep Apple as the visible login method. See [Supabase phone verification](https://supabase.com/docs/guides/auth/phone-login#updating-a-phone-number).
- **Invites:** supply a working TestFlight or App Store URL.
- **Device QA:** real Apple authorization/provisioning remains pending as documented in account-setup.md. Exercise a device address book, limited-access edits/revocation, phone OTP expiry/resend, and actual invitation delivery before calling this release-ready. No real contacts were uploaded and no messages were sent during development.

## Verification

- Full local `scripts/check.sh` passed: account API isolation/conflicts, the new contact API suite, eight Swift tests, unsigned Release build, and map geometry (`build/check.BFqhJO`).
- The added Swift SDK integration case also passed, covering unverified-number rejection, verified discoverability, response decoding, matching, and opt-out (`build/ux/contacts-sdk-test.log`).
- The migration was replayed in a rollback-only local transaction; authenticated RPC access and anonymous/directory-read denial were verified. Hosted grants were also checked after deployment.
- Debug previews use synthetic contacts only. Launch with `--preview-map` for the grouped People list or `--preview-contacts-onboarding` for the optional onboarding step. They do not read the device address book, contact Supabase, or send invitations.
- Final simulator review covered skipping onboarding, enabling sync later, matched-first ordering, Invite opening for the correct contact, the expanded list, and dark mode with accessibility-large text. Screenshots: `build/ux/contacts-onboarding.jpg`, `contacts-people-light.jpg`, and `contacts-people-accessibility-dark.jpg`. The three contact unit tests passed again after the final navigation changes (`build/ux/contacts-final-tests.log`); the final unsigned Release build also passed (`build/ux/contacts-final-release.log`).

References: [Apple's limited Contacts access](https://developer.apple.com/videos/play/wwdc2024/10121/), [PhoneNumberKit](https://github.com/PhoneNumberKit/PhoneNumberKit).

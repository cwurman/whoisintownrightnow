import PhoneNumberKit
import XCTest
@testable import whoisintownrightnow

@MainActor
final class ContactsTests: XCTestCase {
    func testInternationalNumbersMatchWithoutGuessingFromSuffixes() {
        let parser = PhoneNumberUtility()
        XCTAssertEqual(ContactPhone.normalize("(415) 555-0101", region: "US", using: parser), "+14155550101")
        XCTAssertEqual(ContactPhone.normalize("020 7946 0018", region: "GB", using: parser), "+442079460018")
        XCTAssertEqual(ContactPhone.normalize("+44 20 7946 0018", region: "US", using: parser), "+442079460018")
        XCTAssertNil(ContactPhone.normalize("123", region: "US", using: parser))
    }

    func testMembersComeFirstAndEveryOtherContactRemainsInvitable() {
        let contacts = [
            DeviceContact(id: "z", name: "Zoe", phones: ["+14155550101", "+14155550102"], emails: []),
            DeviceContact(id: "a", name: "Alex", phones: [], emails: ["alex@example.test"]),
            DeviceContact(id: "b", name: "Bea", phones: [], emails: []),
            DeviceContact(id: "m", name: "Maya", phones: ["+14155550103"], emails: []),
        ]
        let groups = ContactGroups(contacts: contacts, matchedPhones: ["+14155550102", "+14155550103"])
        XCTAssertEqual(groups.members.map(\.name), ["Maya", "Zoe"])
        XCTAssertEqual(groups.others.map(\.name), ["Alex", "Bea"])
        XCTAssertEqual(ContactGroups(contacts: contacts, matchedPhones: [], search: " zo ").others.map(\.name), ["Zoe"])
        XCTAssertEqual(ContactGroups(contacts: contacts, matchedPhones: []).others.count, contacts.count)
    }

    func testContactChoiceIsScopedToEachAccountAndDoesNotGrantPermission() {
        let suite = "contact-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let first = ContactsStore(accountID: id, defaults: defaults)
        first.skip()
        XCTAssertTrue(ContactsStore(accountID: id, defaults: defaults).didChoose)
        XCTAssertFalse(first.isEnabled)
        XCTAssertFalse(ContactsStore(accountID: UUID(), defaults: defaults).didChoose)
        XCTAssertTrue(first.contacts.isEmpty)
    }
}

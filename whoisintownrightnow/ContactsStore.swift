import Contacts
import Foundation
import Observation
import PhoneNumberKit

nonisolated struct DeviceContact: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let phones: [String]
    let emails: [String]
    var invitationPhones: [String] = []
    var photo: Data? = nil
    var messageNumbers: [String] { invitationPhones.isEmpty ? phones : invitationPhones }
    var initials: String {
        name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

nonisolated struct ContactGroups: Sendable {
    let members: [DeviceContact]
    let others: [DeviceContact]

    init(contacts: [DeviceContact], matchedPhones: Set<String>, search: String = "") {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let ordered = contacts.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.phones.contains(where: { $0.contains(query) })
        }.sorted { lhs, rhs in
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
        members = ordered.filter { !matchedPhones.isDisjoint(with: $0.phones) }
        others = ordered.filter { matchedPhones.isDisjoint(with: $0.phones) }
    }
}

nonisolated enum ContactPhone {
    static func normalize(_ value: String, region: String, using parser: PhoneNumberUtility) -> String? {
        guard let number = try? parser.parse(value, withRegion: region) else { return nil }
        return parser.format(number, toType: .e164)
    }
}

/// CNContact objects and the phone parser never cross the worker's isolation boundary.
actor ContactReader {
    func read(region: String) throws -> [DeviceContact] {
        let parser = PhoneNumberUtility()
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
        ])
        request.unifyResults = true
        var contacts: [DeviceContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let phones = Array(Set(contact.phoneNumbers.compactMap {
                ContactPhone.normalize($0.value.stringValue, region: region, using: parser)
            })).sorted()
            let emails = Array(Set(contact.emailAddresses.map { String($0.value) })).sorted()
            let name = CNContactFormatter.string(from: contact, style: .fullName)?.trimmingCharacters(in: .whitespacesAndNewlines)
            contacts.append(DeviceContact(id: contact.identifier,
                name: name.flatMap { $0.isEmpty ? nil : $0 } ?? phones.first ?? emails.first ?? "Unnamed contact",
                phones: phones, emails: emails,
                invitationPhones: Array(Set(contact.phoneNumbers.map { $0.value.stringValue })).sorted(),
                photo: contact.thumbnailImageData))
        }
        return contacts
    }
}

@MainActor @Observable
final class ContactsStore {
    private(set) var contacts: [DeviceContact] = []
    private(set) var matchedPhones = Set<String>()
    private(set) var authorization = CNContactStore.authorizationStatus(for: .contacts)
    private(set) var isLoading = false
    private(set) var hasMatched = false
    private(set) var errorMessage: String?
    private(set) var isEnabled: Bool
    private(set) var didChoose: Bool
    private let defaults: UserDefaults
    private let key: String
    private let reader = ContactReader()
    private var generation = UUID()
    private var lastRefresh: Date?
    private let isPreview: Bool
    var region: String { Locale.current.region?.identifier ?? "US" }
    var hasAccess: Bool { authorization == .authorized || authorization == .limited }

    init(accountID: UUID?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "contacts.\(accountID?.uuidString ?? "preview")"
        isPreview = accountID == nil
        // Debug map previews never read the device's real contacts or call the backend.
        isEnabled = accountID != nil && defaults.bool(forKey: key + ".enabled")
        didChoose = accountID != nil && defaults.bool(forKey: key + ".chosen")
    }

    func skip() {
        didChoose = true
        if !isPreview { defaults.set(true, forKey: key + ".chosen") }
    }

    func disconnect() {
        isEnabled = false
        clearSession()
        if !isPreview { defaults.set(false, forKey: key + ".enabled") }
    }

    func clearSession() {
        generation = UUID()
        isLoading = false
        contacts = []
        matchedPhones = []
        hasMatched = false
        lastRefresh = nil
        errorMessage = nil
    }

    func connect(account: AccountStore?) async {
        if isPreview {
            #if DEBUG
            contacts = Self.samples
            matchedPhones = ["+14155550101", "+14155550102"]
            authorization = .authorized
            isEnabled = true
            hasMatched = true
            skip()
            #endif
            return
        }
        errorMessage = nil
        if authorization == .notDetermined {
            do { _ = try await CNContactStore().requestAccess(for: .contacts) }
            catch { errorMessage = "Couldn’t open Contacts. You can try again or continue without syncing." }
        }
        authorization = CNContactStore.authorizationStatus(for: .contacts)
        guard hasAccess else { return }
        isEnabled = true
        defaults.set(true, forKey: key + ".enabled")
        skip()
        await refresh(account: account, force: true)
    }

    func refresh(account: AccountStore?, force: Bool = false) async {
        guard !isPreview else { return }
        authorization = CNContactStore.authorizationStatus(for: .contacts)
        guard isEnabled, hasAccess else {
            generation = UUID()
            contacts = []; matchedPhones = []; hasMatched = false; lastRefresh = nil
            isLoading = false
            return
        }
        guard !isLoading || force, force || lastRefresh.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
        let requestID = UUID()
        generation = requestID
        isLoading = true
        errorMessage = nil
        // Do not keep membership results across a failed/revoked/changed contact snapshot.
        contacts = []
        matchedPhones = []
        hasMatched = false
        defer { if generation == requestID { isLoading = false } }
        do {
            let values = try await reader.read(region: region)
            guard generation == requestID, !Task.isCancelled else { return }
            contacts = values
            guard let account else { throw AccountError.message("Sign in to find contacts with accounts.") }
            let phones = Array(Set(values.flatMap(\.phones))).sorted()
            var matches = Set<String>()
            for start in stride(from: 0, to: phones.count, by: 500) {
                try Task.checkCancellation()
                guard generation == requestID else { return }
                matches.formUnion(try await account.matchContacts(Array(phones[start..<min(start + 500, phones.count)])))
            }
            guard generation == requestID, !Task.isCancelled,
                  CNContactStore.authorizationStatus(for: .contacts) == authorization else { return }
            matchedPhones = matches
            hasMatched = true
            lastRefresh = Date()
        } catch is CancellationError { }
        catch {
            guard generation == requestID else { return }
            errorMessage = "Couldn’t check which contacts have accounts. Try again when you’re connected."
        }
    }

    #if DEBUG
    private static let samples = [
        DeviceContact(id: "preview-tara", name: "Tara Weiss", phones: ["+14155550101"], emails: []),
        DeviceContact(id: "preview-rae", name: "Rae Solis", phones: ["+14155550102"], emails: []),
        DeviceContact(id: "preview-alex", name: "Alex Lund", phones: ["+14155550103"], emails: []),
        DeviceContact(id: "preview-jonas", name: "Jonas Pike", phones: [], emails: ["jonas@example.test"]),
        DeviceContact(id: "preview-maya", name: "Maya Kwan", phones: ["+14155550104"], emails: []),
    ]
    #endif
}

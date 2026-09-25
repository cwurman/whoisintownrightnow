import Foundation

enum LocationSharingMode: String, Codable, CaseIterable, Identifiable {
    case exact, vicinity
    var id: String { rawValue }
    var title: String { self == .exact ? "Exact location" : "Vicinity" }
    var detail: String {
        self == .exact ? "Share your exact location with all friends." : "Share a rough area with a half-mile radius."
    }
}

enum NotificationMode: String, Codable, CaseIterable, Identifiable {
    case off, directOnly = "direct_only", all
    var id: String { rawValue }
    var title: String {
        switch self { case .off: "Off"; case .directOnly: "Direct invites only"; case .all: "All notifications" }
    }
    var detail: String {
        switch self {
        case .off: "Friends won’t be able to send you direct invites."
        case .directOnly: "Allow direct invites from friends and alerts for those invites."
        case .all: "Allow direct invites and alerts about nearby signals."
        }
    }
}

struct AccountProfile: Codable, Identifiable {
    let id: UUID
    var displayName: String
    var avatarPath: String?
    var onboardingCompletedAt: String?

    var initials: String {
        let words = displayName.split(whereSeparator: \.isWhitespace)
        let result = words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return result.isEmpty ? "You" : result
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName = "display_name", avatarPath = "avatar_path", onboardingCompletedAt = "onboarding_completed_at"
    }
}

struct AccountSettings: Codable {
    var locationMode: LocationSharingMode
    var notificationMode: NotificationMode
    var locationSharingConfirmedAt: String?
    enum CodingKeys: String, CodingKey {
        case locationMode = "location_mode", notificationMode = "notification_mode", locationSharingConfirmedAt = "location_sharing_confirmed_at"
    }
}

struct AccountSnapshot: Codable {
    var profile: AccountProfile
    var settings: AccountSettings
    var needsSetup: Bool { profile.onboardingCompletedAt == nil || settings.locationSharingConfirmedAt == nil }
}

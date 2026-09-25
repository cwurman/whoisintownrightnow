import Foundation

enum ContactInvitation {
    /// Set AppInviteURL in the app's Info.plist when a TestFlight/App Store URL exists.
    static var downloadURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AppInviteURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    static var message: String {
        let text = "Join me on Who’s in town so we can make plans and hang out!"
        return downloadURL.map { text + "\n" + $0.absoluteString } ?? text
    }
}

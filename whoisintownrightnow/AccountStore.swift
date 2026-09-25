import AuthenticationServices
import CryptoKit
import Foundation
import ImageIO
import Observation
import Security
import Supabase
import UIKit

@MainActor @Observable
final class AccountStore {
    enum Phase { case loading, signedOut, setup, ready, failed }
    private(set) var phase: Phase = .loading
    private(set) var account: AccountSnapshot?
    private(set) var avatarData: Data?
    private(set) var isWorking = false
    private(set) var needsReload = false
    private(set) var avatarErrorMessage: String?
    var errorMessage: String?
    private let client: SupabaseClient
    private var nonce: String?
    private var appleName: String?
    private var loadedUserID: UUID?

    init(client: SupabaseClient? = nil) { self.client = client ?? SupabaseConfiguration.makeClient() }

    // The SDK stores and refreshes sessions in Keychain on iOS.
    func observeSession() async {
        for await (event, session) in client.auth.authStateChanges {
            if Task.isCancelled { return }
            if event == .signedOut || (event == .initialSession && session == nil) {
                clearAccount()
            } else if let session, !isWorking, loadedUserID != session.user.id {
                await loadAccount()
            }
        }
    }

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        errorMessage = nil
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            nonce = nil
            errorMessage = "Couldn’t securely start sign-in. Please try again."
            return
        }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        nonce = value
        request.requestedScopes = [.fullName, .email]
        request.nonce = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false; nonce = nil }
        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8), let nonce else {
                throw AccountError.message("Apple didn’t return a valid sign-in. Please try again.")
            }
            let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) } ?? ""
            appleName = name.isEmpty ? nil : name
            _ = try await client.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: token, nonce: nonce))
            // Apple supplies the name only once. Persist before the editable profile step.
            if let appleName {
                _ = try await client.auth.update(user: UserAttributes(data: ["full_name": .string(appleName)]))
            }
            try await fetchAccount()
        } catch {
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = error.localizedDescription
            phase = client.auth.currentSession == nil ? .signedOut : .failed
        }
    }

    func loadAccount() async {
        guard !isWorking else { return }
        isWorking = true
        phase = .loading
        errorMessage = nil
        defer { isWorking = false }
        do { try await fetchAccount() }
        catch {
            // A network failure must never be mistaken for a missing profile or logged-out user.
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    private func fetchAccount() async throws {
        let session = try await client.auth.session
        let name = appleName ?? session.user.userMetadata["full_name"]?.stringValue ?? ""
        struct Parameters: Encodable { let p_initial_name: String }
        let snapshot: AccountSnapshot = try await client.rpc("bootstrap_account", params: Parameters(p_initial_name: name)).execute().value
        guard client.auth.currentUser?.id == session.user.id else { return }
        account = snapshot
        needsReload = false
        loadedUserID = snapshot.profile.id
        phase = snapshot.needsSetup ? .setup : .ready
        appleName = nil
        await loadAvatar(path: snapshot.profile.avatarPath, userID: session.user.id)
    }

    func save(name: String, location: LocationSharingMode, notifications: NotificationMode, photoData: Data?, removePhoto: Bool) async -> Bool {
        guard let current = account, !isWorking, !needsReload else { return false }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        var uploadedPath: String?
        do {
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty, cleanName.unicodeScalars.count <= 80 else { throw AccountError.message("Enter a name of 1–80 characters.") }
            var path = removePhoto ? nil : current.profile.avatarPath
            if let photoData {
                let newPath = "\(current.profile.id.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
                try await client.storage.from("avatars").upload(newPath, data: photoData, options: FileOptions(contentType: "image/jpeg", upsert: false))
                path = newPath
                uploadedPath = newPath
            }
            struct Parameters: Encodable {
                let p_display_name: String
                let p_avatar_path: String?
                let p_location_mode: String
                let p_notification_mode: String
                let p_profile_revision: Int64
                let p_settings_revision: Int64
                // RPC needs explicit null to remove an avatar (synthesized optional encoding omits it).
                func encode(to encoder: Encoder) throws {
                    var values = encoder.container(keyedBy: CodingKeys.self)
                    try values.encode(p_display_name, forKey: .p_display_name)
                    try values.encode(p_avatar_path, forKey: .p_avatar_path)
                    try values.encode(p_location_mode, forKey: .p_location_mode)
                    try values.encode(p_notification_mode, forKey: .p_notification_mode)
                    try values.encode(p_profile_revision, forKey: .p_profile_revision)
                    try values.encode(p_settings_revision, forKey: .p_settings_revision)
                }
                enum CodingKeys: String, CodingKey { case p_display_name, p_avatar_path, p_location_mode, p_notification_mode, p_profile_revision, p_settings_revision }
            }
            let snapshot: AccountSnapshot = try await client.rpc("save_account", params: Parameters(p_display_name: cleanName, p_avatar_path: path, p_location_mode: location.rawValue, p_notification_mode: notifications.rawValue, p_profile_revision: current.profile.revision, p_settings_revision: current.settings.revision)).execute().value
            guard client.auth.currentUser?.id == current.profile.id else { return false }
            account = snapshot
            phase = .ready
            avatarData = photoData ?? (removePhoto ? nil : avatarData)
            if photoData != nil || removePhoto { avatarErrorMessage = nil }
            if let oldPath = current.profile.avatarPath, oldPath != path {
                // A failed cleanup doesn't invalidate a successfully saved profile. RLS protects the active photo.
                _ = try? await client.storage.from("avatars").remove(paths: [oldPath])
            }
            return true
        } catch {
            // If a response was lost after commit, RLS prevents deletion of the active photo.
            if let uploadedPath { _ = try? await client.storage.from("avatars").remove(paths: [uploadedPath]) }
            needsReload = (error as? PostgrestError)?.code == "PT409"
            errorMessage = needsReload ? "Your account changed on another device. Reload the saved settings before making more changes." : error.localizedDescription
            return false
        }
    }

    /// Refresh without replacing the root view and dismissing the settings form.
    func reloadSavedAccount() async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do { try await fetchAccount(); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }

    func signOut() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.auth.signOut(scope: .local)
            clearAccount()
        } catch { errorMessage = error.localizedDescription }
    }

    func matchContacts(_ phones: [String]) async throws -> [String] {
        guard let id = account?.profile.id, client.auth.currentUser?.id == id else {
            throw AccountError.message("Sign in to find your contacts.")
        }
        struct Parameters: Encodable { let p_phones: [String] }
        let matches: [String] = try await client.rpc("match_contacts", params: Parameters(p_phones: phones)).execute().value
        guard client.auth.currentUser?.id == id else { throw CancellationError() }
        return matches
    }

    func contactDiscoveryStatus(enabled: Bool? = nil) async throws -> ContactDiscoveryStatus {
        struct Parameters: Encodable { let p_enabled: Bool? }
        return try await client.rpc("contact_discovery_settings", params: Parameters(p_enabled: enabled)).execute().value
    }

    func requestContactPhone(_ phone: String) async throws {
        guard let id = account?.profile.id, client.auth.currentUser?.id == id else { throw CancellationError() }
        _ = try await client.auth.update(user: UserAttributes(phone: phone))
    }

    func verifyContactPhone(_ phone: String, code: String) async throws {
        guard let id = account?.profile.id, client.auth.currentUser?.id == id else { throw CancellationError() }
        _ = try await client.auth.verifyOTP(phone: phone, token: code, type: .phoneChange)
        guard client.auth.currentUser?.id == id else { throw CancellationError() }
    }

    private func loadAvatar(path: String?, userID: UUID) async {
        avatarData = nil
        avatarErrorMessage = nil
        guard let path else { return }
        do {
            let data = try await client.storage.from("avatars").download(path: path)
            guard client.auth.currentUser?.id == userID, account?.profile.avatarPath == path else { return }
            guard UIImage(data: data) != nil else { throw AccountError.message("The saved photo couldn’t be read.") }
            avatarData = data
        } catch {
            guard client.auth.currentUser?.id == userID, account?.profile.avatarPath == path else { return }
            avatarErrorMessage = "Your saved photo couldn’t load. Check your connection and try again."
        }
    }

    func retryAvatar() async {
        guard let account, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await loadAvatar(path: account.profile.avatarPath, userID: account.profile.id)
    }

    private func clearAccount() {
        account = nil
        avatarData = nil
        avatarErrorMessage = nil
        loadedUserID = nil
        needsReload = false
        appleName = nil
        nonce = nil
        errorMessage = nil
        phase = .signedOut
    }
}

enum AccountError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}

enum AvatarImage {
    /// Draw into a new image to normalize orientation, bound memory/storage, and omit source EXIF/GPS.
    static func jpeg(from data: Data) throws -> Data {
        // Decode a thumbnail directly; decoding the full original first can exhaust memory.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else {
            throw AccountError.message("Choose a supported photo.")
        }
        let image = UIImage(cgImage: thumbnail)
        let size = CGSize(width: thumbnail.width, height: thumbnail.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let output = resized.jpegData(compressionQuality: 0.85) else { throw AccountError.message("Couldn’t prepare this photo.") }
        return output
    }
}

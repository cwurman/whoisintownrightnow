import AuthenticationServices
import ImageIO
import Supabase
import UIKit
import XCTest
@testable import whoisintownrightnow

@MainActor
final class AccountIntegrationTests: XCTestCase {
    func testProfileSettingsPhotoAndSessionRestore() async throws {
        let config = try localConfig()
        let storage = KeychainLocalStorage(service: "account-tests-\(UUID().uuidString)")
        func makeClient() -> SupabaseClient {
            SupabaseClient(supabaseURL: config.url, supabaseKey: config.key,
                options: .init(auth: .init(storage: storage, autoRefreshToken: false, emitLocalSessionAsInitialSession: true)))
        }
        let client = makeClient()
        let email = "swift-test-\(UUID().uuidString)@example.test"
        let password = UUID().uuidString + "Aa1!"
        let userData = try await adminRequest(config: config, path: "users", method: "POST", body: ["email": email, "password": password, "email_confirm": true])
        let userID = try XCTUnwrap((try JSONSerialization.jsonObject(with: userData) as? [String: Any])?["id"] as? String)
        addTeardownBlock {
            _ = try await self.adminRequest(config: config, path: "users/\(userID)", method: "DELETE")
        }
        _ = try await client.auth.signIn(email: email, password: password)
        let store = AccountStore(client: client)
        await store.loadAccount()
        XCTAssertEqual(store.phase, .setup)
        XCTAssertEqual(store.account?.settings.locationMode, .vicinity)
        XCTAssertEqual(store.account?.settings.notificationMode, .off)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        }
        let photo = try AvatarImage.jpeg(from: XCTUnwrap(image.pngData()))
        XCTAssertEqual(try XCTUnwrap(UIImage(data: photo)).size.width, 512)
        let saved = await store.save(name: "  Test Person  ", location: .exact, notifications: .directOnly, photoData: photo, removePhoto: false)
        XCTAssertTrue(saved, store.errorMessage ?? "Save failed")
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.account?.profile.displayName, "Test Person")
        XCTAssertEqual(store.account?.profile.initials, "TP")

        // New SDK/store instances must read the Keychain session and persistent profile/photo.
        let restored = AccountStore(client: makeClient())
        await restored.loadAccount()
        XCTAssertEqual(restored.phase, .ready)
        XCTAssertEqual(restored.account?.profile.id, store.account?.profile.id)
        XCTAssertEqual(restored.account?.settings.locationMode, .exact)
        XCTAssertEqual(restored.account?.settings.notificationMode, .directOnly)
        XCTAssertEqual(restored.avatarData, photo)

        let photoOfflineConfiguration = URLSessionConfiguration.ephemeral
        photoOfflineConfiguration.protocolClasses = [PhotoOfflineURLProtocol.self]
        let photoOfflineClient = SupabaseClient(supabaseURL: config.url, supabaseKey: config.key,
            options: .init(auth: .init(storage: storage, autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                           global: .init(session: URLSession(configuration: photoOfflineConfiguration))))
        let photoOffline = AccountStore(client: photoOfflineClient)
        await photoOffline.loadAccount()
        XCTAssertEqual(photoOffline.phase, .ready, "An avatar failure must not block the whole account")
        XCTAssertNil(photoOffline.avatarData)
        XCTAssertNotNil(photoOffline.avatarErrorMessage, "A failed photo download needs a visible retry path")

        let offlineConfiguration = URLSessionConfiguration.ephemeral
        offlineConfiguration.protocolClasses = [OfflineURLProtocol.self]
        let offlineClient = SupabaseClient(supabaseURL: config.url, supabaseKey: config.key,
            options: .init(auth: .init(storage: storage, autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                           global: .init(session: URLSession(configuration: offlineConfiguration))))
        let offline = AccountStore(client: offlineClient)
        await offline.loadAccount()
        XCTAssertEqual(offline.phase, .failed, "Offline is a retry state, not a new account")
        XCTAssertNotNil(offlineClient.auth.currentSession, "Network failure must preserve the stored session")

        // Explicit JSON null must remove a photo, and Off must survive another reload.
        let removed = await restored.save(name: "Renamed Person", location: .vicinity, notifications: .off, photoData: nil, removePhoto: true)
        XCTAssertTrue(removed, restored.errorMessage ?? "Remove failed")
        XCTAssertNil(restored.account?.profile.avatarPath)
        XCTAssertNil(restored.avatarData)
        let staleSave = await store.save(name: "Stale Name", location: .exact, notifications: .all, photoData: photo, removePhoto: false)
        XCTAssertFalse(staleSave, "An older device must not overwrite newer privacy choices")
        XCTAssertTrue(store.needsReload)
        let reloaded = await store.reloadSavedAccount()
        XCTAssertTrue(reloaded)
        XCTAssertFalse(store.needsReload)
        XCTAssertEqual(store.account?.profile.displayName, "Renamed Person")
        XCTAssertEqual(store.account?.settings.notificationMode, .off)

        let invalid = await store.save(name: "  ", location: .exact, notifications: .all, photoData: nil, removePhoto: false)
        XCTAssertFalse(invalid)
        XCTAssertEqual(store.account?.settings.notificationMode, .off)
        await store.signOut()
        XCTAssertEqual(store.phase, .signedOut)
        XCTAssertNil(store.account)
        XCTAssertNil(store.avatarData)
        XCTAssertNil(makeClient().auth.currentSession)
    }

    func testNativeAppleCancellationDoesNotShowError() async throws {
        let store = AccountStore()
        await store.completeAppleSignIn(.failure(ASAuthorizationError(.canceled)))
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isWorking)
    }

    func testAvatarNormalizesOrientationAndStripsLocationMetadata() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
        }
        let original = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(original, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.0, kCGImagePropertyGPSLatitudeRef: "N",
                                          kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let output = try AvatarImage.jpeg(from: original as Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let decoded = try XCTUnwrap(UIImage(data: output))
        XCTAssertEqual(decoded.size.height, 512, "Orientation must be baked into the image pixels")
        XCTAssertLessThan(decoded.size.width, decoded.size.height)
        XCTAssertThrowsError(try AvatarImage.jpeg(from: Data("not an image".utf8)))
    }

    struct LocalConfig: Sendable {
        let url: URL
        let key: String
        let admin: String
    }

    private func localConfig() throws -> LocalConfig {
        guard let path = Bundle(for: Self.self).url(forResource: "LocalSupabase", withExtension: "json") else {
            throw XCTSkip("Run supabase start and copy supabase status -o json to whoisintownrightnowTests/LocalSupabase.json")
        }
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: String]
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(data["API_URL"])))
        guard ["127.0.0.1", "localhost"].contains(url.host) else { throw AccountError.message("Tests require a local Supabase stack.") }
        return LocalConfig(url: url, key: try XCTUnwrap(data["ANON_KEY"]), admin: try XCTUnwrap(data["SERVICE_ROLE_KEY"]))
    }

    private func adminRequest(config: LocalConfig, path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: config.url.appendingPathComponent("auth/v1/admin/" + path))
        request.httpMethod = method
        request.setValue(config.key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + config.admin, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains((response as! HTTPURLResponse).statusCode))
        return data
    }
}

private class OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private final class PhotoOfflineURLProtocol: OfflineURLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.path.hasPrefix("/storage/v1/") == true }
}

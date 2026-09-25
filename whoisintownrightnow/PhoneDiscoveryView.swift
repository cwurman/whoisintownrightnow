import PhoneNumberKit
import SwiftUI

struct ContactDiscoveryStatus: Decodable {
    let enabled: Bool
    let verifiedPhone: String?
    enum CodingKeys: String, CodingKey { case enabled, verifiedPhone = "verified_phone" }
}

struct PhoneDiscoveryView: View {
    let account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var status: ContactDiscoveryStatus?
    @State private var phone = ""
    @State private var sentTo: String?
    @State private var code = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var canResendAt = Date.distantPast

    var body: some View {
        NavigationStack {
            ThemedForm {
                Section {
                    Text("Let your people find you").font(.title2.bold())
                    Text("Verify your number so contacts can recognize your account, even if you use Hide My Email with Apple.")
                        .foregroundStyle(Theme.secondaryLabel)
                } footer: { Text("Your number isn’t added to a public profile. Finding your account doesn’t give anyone access to your location.") }

                if let status {
                    if let verified = status.verifiedPhone {
                        Section {
                            LabeledContent("Verified number", value: verified)
                            Toggle("Let contacts find me", isOn: Binding(get: { self.status?.enabled ?? false }, set: { enabled in
                                Task { await updateDiscovery(enabled) }
                            }))
                        }
                    }
                    Section {
                        TextField("+1 415 555 0123", text: $phone)
                            .keyboardType(.phonePad).textContentType(.telephoneNumber)
                            .accessibilityLabel("Phone number including country code")
                            .onChange(of: phone) { sentTo = nil; code = "" }
                        Button("Send verification code") { Task { await sendCode() } }
                            .disabled(phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: { Text(status.verifiedPhone == nil ? "Your number" : "Change number") }
                    footer: { Text("Include your country code. We’ll send one text to verify this number. Carrier charges may apply.") }
                    if let sentTo {
                        Section {
                            TextField("Verification code", text: $code)
                                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                            Button("Verify number") { Task { await verifyCode() } }.disabled(code.count < 6)
                        } header: { Text("Code sent to \(sentTo)") }
                        footer: { Text("After verification, turn on “Let contacts find me” above to appear in their list.") }
                    }
                } else if !isWorking {
                    Section { Button("Retry") { Task { await loadStatus() } } }
                }
                if isWorking { Section { ProgressView("Please wait…") } }
                if let error { Section { Text(error).font(.callout).foregroundStyle(.red) } }
            }
            .disabled(isWorking)
            .navigationTitle("Your phone number").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(isWorking) } }
            .interactiveDismissDisabled(isWorking)
        }
        .tint(Theme.accent).presentationBackground(Theme.background)
        .task { await loadStatus() }
    }

    private func loadStatus() async {
        isWorking = true; error = nil
        defer { isWorking = false }
        do { status = try await account.contactDiscoveryStatus() }
        catch { self.error = "Couldn’t load phone settings. Check your connection and try again." }
    }

    private func sendCode() async {
        guard Date() >= canResendAt else { error = "Please wait a minute before requesting another code."; return }
        let clean = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("+"), let normalized = ContactPhone.normalize(clean, region: "US", using: PhoneNumberUtility()) else {
            error = "Enter a valid phone number with its country code, starting with +."; return
        }
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            try await account.requestContactPhone(normalized)
            sentTo = normalized
            canResendAt = Date().addingTimeInterval(60)
        } catch { self.error = "Couldn’t send a code. Phone verification may not be configured yet, or you may need to wait before trying again." }
    }

    private func verifyCode() async {
        guard let sentTo else { return }
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            try await account.verifyContactPhone(sentTo, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            status = try await account.contactDiscoveryStatus()
            self.sentTo = nil; code = ""; phone = ""
        } catch { self.error = "That code couldn’t be verified. Check it or request a new one." }
    }

    private func updateDiscovery(_ enabled: Bool) async {
        isWorking = true; error = nil
        defer { isWorking = false }
        do { status = try await account.contactDiscoveryStatus(enabled: enabled) }
        catch { self.error = "Couldn’t save discoverability. Your previous setting is still shown." }
    }
}

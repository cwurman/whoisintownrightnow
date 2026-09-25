import AuthenticationServices
import PhotosUI
import SwiftUI

struct AccountRootView: View {
    @State private var store = AccountStore()

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                ProgressView("Getting your account…").frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.background)
            case .signedOut:
                WelcomeView(store: store)
            case .failed:
                ContentUnavailableView {
                    Label("Couldn’t load your account", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(store.errorMessage ?? "Please check your connection and try again.")
                } actions: {
                    Button("Try again") { Task { await store.loadAccount() } }.buttonStyle(.borderedProminent)
                    Button("Sign out") { Task { await store.signOut() } }
                }
            case .setup:
                AccountSettingsView(store: store, isOnboarding: true)
            case .ready:
                MapHomeView(profile: store.account?.profile, avatarData: store.avatarData, accountStore: store)
                    .id(store.account?.profile.id)
            }
        }
        .tint(Theme.accent)
        .task { await store.observeSession() }
    }
}

private struct WelcomeView: View {
    @Bindable var store: AccountStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 88))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.accent)
                    .accessibilityHidden(true)
                    .padding(.top, 56)
                Text("Who’s in town?")
                    .font(.largeTitle.bold())
                Text("See who’s nearby and turn a free moment into a plan.")
                    .font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 16) {
                    Label("Share your location on your terms", systemImage: "location")
                    Label("Choose which invites reach you", systemImage: "bell.badge")
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.top, 16)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 16) {
                if let error = store.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("accountError")
                }
                SignInWithAppleButton(.continue) { store.prepareAppleRequest($0) } onCompletion: { result in
                    Task { await store.completeAppleSignIn(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .id(colorScheme)
                .frame(height: 54).clipShape(Capsule())
                .disabled(store.isWorking)
                if store.isWorking { ProgressView("Signing in…") }
                Text("Your people. Your plans. Your choice.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 20)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
        }
        .background(Theme.background)
    }
}

struct AccountSettingsView: View {
    @Bindable var store: AccountStore
    let isOnboarding: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var location: LocationSharingMode = .vicinity
    @State private var notifications: NotificationMode = .off
    @State private var photoItem: PhotosPickerItem?
    @State private var pendingPhoto: Data?
    @State private var removePhoto = false
    @State private var loadingPhoto = false
    @State private var didLoad = false
    @State private var photoError: String?
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 18) {
                        AccountAvatar(data: pendingPhoto ?? (removePhoto ? nil : store.avatarData), initials: store.account?.profile.initials ?? "You", size: 64)
                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Text(loadingPhoto ? "Preparing photo…" : "Choose photo")
                            }
                            .disabled(loadingPhoto)
                            if pendingPhoto != nil || (!removePhoto && store.account?.profile.avatarPath != nil) {
                                Button("Remove photo", role: .destructive) {
                                    pendingPhoto = nil; photoItem = nil; removePhoto = true
                                }.font(.footnote)
                            }
                        }
                    }
                    TextField("Your name", text: $name)
                        .textContentType(.name).textInputAutocapitalization(.words)
                        .accessibilityIdentifier("displayName")
                    if let error = store.avatarErrorMessage, pendingPhoto == nil, !removePhoto {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("Retry photo download") { Task { await store.retryAvatar() } }
                    }
                } header: { Text("You") } footer: {
                    Text("Use the name your friends know. A photo is optional.")
                }

                Section {
                    if isOnboarding { locationPicker.pickerStyle(.inline) }
                    else { locationPicker.pickerStyle(.navigationLink) }
                } header: { Text("Location sharing") } footer: { Text(location.detail) }

                Section {
                    if isOnboarding { notificationPicker.pickerStyle(.inline) }
                    else { notificationPicker.pickerStyle(.navigationLink) }
                } header: { Text("Notifications & invites") } footer: { Text(notifications.detail) }

                Section {
                    Text("Your preferences are saved to your account. Live location sharing and notification delivery aren’t available yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if let error = photoError ?? store.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }

                if store.needsReload {
                    Section {
                        Button("Discard edits and reload saved settings") {
                            Task {
                                if await store.reloadSavedAccount() { copySavedAccount() }
                            }
                        }
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .disabled(store.isWorking)
                }
            }
            .disabled(store.isWorking)
            .navigationTitle(isOnboarding ? "Your profile" : "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isOnboarding {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.isWorking) }
                    ToolbarItem(placement: .confirmationAction) { saveButton }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isOnboarding {
                    saveButton.buttonStyle(.glassProminent).controlSize(.large)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .frame(maxWidth: .infinity).background(.regularMaterial)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled(store.isWorking)
            .confirmationDialog("Sign out of this account? Unsaved changes will be discarded.", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await store.signOut() } }
            }
        }
        .tint(Theme.accent)
        .onAppear {
            guard !didLoad else { return }
            copySavedAccount()
            store.errorMessage = nil
            didLoad = true
        }
        .task(id: photoItem) {
            guard let selectedPhoto = photoItem else { loadingPhoto = false; return }
            loadingPhoto = true
            photoError = nil
            defer { if photoItem == selectedPhoto { loadingPhoto = false } }
            do {
                guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else {
                    throw AccountError.message("Couldn’t read this photo. Try another one.")
                }
                try Task.checkCancellation()
                guard photoItem == selectedPhoto else { return }
                pendingPhoto = try AvatarImage.jpeg(from: data)
                removePhoto = false
            } catch is CancellationError { }
            catch { if photoItem == selectedPhoto { photoError = error.localizedDescription } }
        }
    }

    private var locationPicker: some View {
        Picker("Location", selection: $location) {
            ForEach(LocationSharingMode.allCases) { Text($0.title).tag($0) }
        }
    }

    private var notificationPicker: some View {
        Picker("Notifications", selection: $notifications) {
            ForEach(NotificationMode.allCases) { Text($0.title).tag($0) }
        }
    }

    private var saveButton: some View {
        Button {
            Task {
                let saved = await store.save(name: name, location: location, notifications: notifications, photoData: pendingPhoto, removePhoto: removePhoto)
                if saved && !isOnboarding { dismiss() }
            }
        } label: {
            HStack {
                if store.isWorking { ProgressView() }
                Text(isOnboarding ? "Continue" : "Save").fontWeight(.semibold)
            }.frame(maxWidth: isOnboarding ? .infinity : nil)
        }
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > 80 || store.isWorking || loadingPhoto || store.needsReload)
        .accessibilityIdentifier("saveAccount")
    }

    private func copySavedAccount() {
        guard let account = store.account else { return }
        name = account.profile.displayName
        location = account.settings.locationMode
        notifications = account.settings.notificationMode
        photoItem = nil
        pendingPhoto = nil
        removePhoto = false
        photoError = nil
    }
}

struct AccountAvatar: View {
    let data: Data?
    let initials: String
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(initials).font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.accent.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

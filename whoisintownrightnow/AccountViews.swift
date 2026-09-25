import AuthenticationServices
import PhotosUI
import SwiftUI

struct AccountRootView: View {
    @State private var store = AccountStore()
    @State private var showSettings = false

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                ProgressView("Getting your account…").frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.cream)
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
                MapHomeView(profile: store.account?.profile, avatarData: store.avatarData) { showSettings = true }
                    .id(store.account?.profile.id)
                    .sheet(isPresented: $showSettings) {
                        AccountSettingsView(store: store, isOnboarding: false)
                    }
            }
        }
        .tint(Theme.ink)
        .task { await store.observeSession() }
        .onChange(of: store.phase) { _, phase in
            if phase == .signedOut { showSettings = false }
        }
    }
}

private struct WelcomeView: View {
    @Bindable var store: AccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Image(systemName: "location.circle.fill")
                .font(.system(size: 72)).foregroundStyle(Theme.signalYellow, Theme.ink)
            Text("Who’s in town\nright now?")
                .font(.system(size: 46, weight: .bold, design: .rounded)).minimumScaleFactor(0.7)
            Text("Your people. Your plans.\nSee who’s around and make something happen.")
                .font(.title3).foregroundStyle(.secondary)
            Spacer()
            if let error = store.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("accountError")
            }
            SignInWithAppleButton(.continue) { request in
                store.prepareAppleRequest(request)
            } onCompletion: { result in
                Task { await store.completeAppleSignIn(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .disabled(store.isWorking)
            if store.isWorking { ProgressView("Signing in…").frame(maxWidth: .infinity) }
            Text("You choose how much location detail to share and which invitations reach you.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Theme.cream)
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
                } header: { Text("You") } footer: {
                    Text("Use the name your friends know. A photo is optional.")
                }

                Section {
                    Picker("Share", selection: $location) {
                        ForEach(LocationSharingMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } header: { Text("Location sharing") } footer: { Text(location.detail) }

                Section {
                    Picker("Receive", selection: $notifications) {
                        ForEach(NotificationMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } header: { Text("Notifications & invites") } footer: { Text(notifications.detail) }

                Section {
                    Text("Your preferences are saved to your account. Live location sharing and notification delivery aren’t available yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if let error = photoError ?? store.errorMessage {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }

                Section {
                    Button {
                        Task {
                            let saved = await store.save(name: name, location: location, notifications: notifications, photoData: pendingPhoto, removePhoto: removePhoto)
                            if saved && !isOnboarding { dismiss() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if store.isWorking { ProgressView() }
                            Text(isOnboarding ? "Let’s go" : "Save changes").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80 || store.isWorking || loadingPhoto)
                    .accessibilityIdentifier("saveAccount")
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .disabled(store.isWorking)
                }
            }
            .disabled(store.isWorking)
            .scrollContentBackground(.hidden)
            .background(Theme.cream)
            .navigationTitle(isOnboarding ? "Make yourself known" : "Your settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isOnboarding {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.isWorking) }
                }
            }
            .interactiveDismissDisabled(store.isWorking)
            .confirmationDialog("Sign out of this account? Unsaved changes will be discarded.", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await store.signOut() } }
            }
        }
        .onAppear {
            guard !didLoad, let account = store.account else { return }
            name = account.profile.displayName
            location = account.settings.locationMode
            notifications = account.settings.notificationMode
            store.errorMessage = nil
            didLoad = true
        }
        .task(id: photoItem) {
            guard let photoItem else { return }
            loadingPhoto = true
            photoError = nil
            defer { loadingPhoto = false }
            do {
                guard let data = try await photoItem.loadTransferable(type: Data.self) else {
                    throw AccountError.message("Couldn’t read this photo. Try another one.")
                }
                try Task.checkCancellation()
                pendingPhoto = try AvatarImage.jpeg(from: data)
                removePhoto = false
            } catch is CancellationError { }
            catch { photoError = error.localizedDescription }
        }
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.signalYellow)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

import Contacts
import ContactsUI
import MessageUI
import SwiftUI

struct ContactAccountView: View {
    let account: AccountStore
    @State private var contacts: ContactsStore
    @Environment(\.scenePhase) private var scenePhase

    init(account: AccountStore) {
        self.account = account
        _contacts = State(initialValue: ContactsStore(accountID: account.account?.profile.id))
    }

    var body: some View {
        ZStack {
            if contacts.didChoose {
                MapHomeView(profile: account.account?.profile, accountStore: account, contactsStore: contacts)
            } else {
                ContactsOnboardingView(contacts: contacts, account: account)
            }
        }
        .task { await contacts.refresh(account: account) }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await contacts.refresh(account: account) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CNContactStoreDidChange)) { _ in
            Task { await contacts.refresh(account: account, force: true) }
        }
        .onDisappear { contacts.clearSession() }
    }
}

struct ContactsOnboardingView: View {
    let contacts: ContactsStore
    let account: AccountStore?
    @State private var showPhone = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "person.2.crop.square.stack.fill")
                        .font(.system(size: 72)).foregroundStyle(Theme.accent)
                        .accessibilityHidden(true).padding(.top, 36)
                    Text("Find your people").font(.largeTitle.bold())
                    Text("See who’s already here, and invite everyone else to hang.")
                        .font(.title3).foregroundStyle(Theme.secondaryLabel)
                    VStack(alignment: .leading, spacing: 18) {
                        Label("Choose all contacts or just a few", systemImage: "person.crop.circle.badge.checkmark")
                        Label("Names and photos stay on your phone", systemImage: "iphone")
                        Label("You choose when to send an invite", systemImage: "paperplane")
                    }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    Text("We send contact phone numbers securely to check for accounts, without saving your address book on our servers. Syncing doesn’t share your location.")
                        .font(.footnote).foregroundStyle(Theme.secondaryLabel)
                    if let account {
                        Button("Add your number so contacts can find you") { showPhone = true }
                            .sheet(isPresented: $showPhone) { PhoneDiscoveryView(account: account) }
                    }
                    if let error = contacts.errorMessage {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                    if contacts.authorization == .denied || contacts.authorization == .restricted {
                        Text("Contacts access is off. You can continue and change this later in Settings.")
                            .font(.callout).foregroundStyle(Theme.secondaryLabel)
                    }
                }
                .multilineTextAlignment(.center).padding(28).frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 16) {
                    Button {
                        if contacts.authorization == .denied {
                            openURL(URL(string: UIApplication.openSettingsURLString)!)
                        } else { Task { await contacts.connect(account: account) } }
                    } label: {
                        Label(contacts.authorization == .denied ? "Open Settings" : "Sync contacts", systemImage: "person.2")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glassProminent).tint(Theme.orchid).foregroundStyle(Theme.ink)
                    .disabled(contacts.isLoading || contacts.authorization == .restricted)
                    .accessibilityIdentifier("sync-contacts")
                    Button("Not now") { contacts.skip() }.accessibilityIdentifier("skip-contacts")
                }.padding(24).background(Theme.background)
            }
            .background(Theme.background)
        }.tint(Theme.accent)
    }
}

struct FriendsView: View {
    let contacts: ContactsStore
    let account: AccountStore?
    @Environment(\.dismiss) private var dismiss
    @State private var showContactsSettings = false
    @State private var invitedContact: DeviceContact?

    var body: some View {
        NavigationStack {
            List {
                ContactsPeopleSections(contacts: contacts, account: account,
                    onManage: { showContactsSettings = true }, onInvite: { invitedContact = $0 })
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Manage contacts", systemImage: "person.crop.rectangle") { showContactsSettings = true }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await contacts.refresh(account: account, force: true) }
            .task {
                if account == nil && !contacts.didChoose { await contacts.connect(account: nil) }
                else { await contacts.refresh(account: account) }
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showContactsSettings) {
            NavigationStack {
                ContactsSettingsView(contacts: contacts, account: account)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showContactsSettings = false }
                        }
                    }
            }
            .presentationBackground(Theme.background)
        }
        .sheet(item: $invitedContact) { contact in
            InviteContactView(contact: contact, isPreview: account == nil)
        }
    }
}

struct ContactsPeopleSections: View {
    let contacts: ContactsStore
    let account: AccountStore?
    let onManage: () -> Void
    let onInvite: (DeviceContact) -> Void
    @State private var search = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var groups: ContactGroups {
        ContactGroups(contacts: contacts.contacts, matchedPhones: contacts.matchedPhones, search: search)
    }

    var body: some View {
        Group {
            if !contacts.isEnabled || !contacts.hasAccess {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your people, all here").font(.headline)
                        Text("Sync contacts to find people on the app and invite the rest.")
                            .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                        Button("Sync contacts", systemImage: "person.2", action: onManage)
                            .buttonStyle(.borderedProminent).tint(Theme.orchid).foregroundStyle(Theme.ink)
                    }.padding(.vertical, 6)
                }
            } else {
                Section {
                    TextField("Search contacts", text: $search).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityLabel("Search contacts")
                    if contacts.isLoading { ProgressView("Finding your people…") }
                    if let error = contacts.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(Theme.secondaryLabel)
                        Button("Retry account matching") { Task { await contacts.refresh(account: account, force: true) } }
                    }
                }
                if !groups.members.isEmpty {
                    Section("On Who’s in town") {
                        ForEach(groups.members) { contact in contactRow(contact, isMember: true) }
                    }
                }
                if !groups.others.isEmpty {
                    Section {
                        ForEach(groups.others) { contact in contactRow(contact, isMember: false) }
                    } header: { Text(contacts.hasMatched ? "Invite to Who’s in town" : "Your contacts") }
                    footer: {
                        Text("Matching uses verified phone numbers. Someone who hasn’t added theirs may still appear here.")
                    }
                }
                if groups.members.isEmpty && groups.others.isEmpty && !contacts.isLoading {
                    Section {
                        ContentUnavailableView(search.isEmpty ? "No contacts shared yet" : "No matches",
                            systemImage: "person.crop.circle.badge.questionmark",
                            description: Text(search.isEmpty ? "Add contacts in Manage contacts, or choose more to share." : "Try another name or number."))
                    }
                }
            }
            if account == nil {
                Section { Text("Preview · sample contacts").font(.footnote).foregroundStyle(Theme.secondaryLabel) }
            }
        }
        .listRowBackground(Theme.panelRow)
    }

    private func contactRow(_ contact: DeviceContact, isMember: Bool) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                AccountAvatar(data: contact.photo, initials: contact.initials)
                VStack(alignment: .leading, spacing: 4) {
                    Text(contact.name).font(.headline).foregroundStyle(Theme.label)
                    Text(isMember ? "On Who’s in town" : contact.messageNumbers.first ?? contact.emails.first ?? "Contact")
                        .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if isMember {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).accessibilityHidden(true)
            } else {
                Button("Invite") { onInvite(contact) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .tint(Theme.orchid).foregroundStyle(Theme.ink)
                    .accessibilityLabel("Invite \(contact.name)")
            }
        }.padding(.vertical, 4)
    }
}

struct ContactsSettingsView: View {
    let contacts: ContactsStore
    let account: AccountStore?
    @Environment(\.openURL) private var openURL
    @State private var showPicker = false
    @State private var showPhone = false

    var body: some View {
        ThemedForm {
            Section {
                Text("Find contacts who have accounts, then invite the rest. Only contacts you allow are shown.")
                if contacts.isEnabled && contacts.hasAccess {
                    LabeledContent("Access", value: contacts.authorization == .limited ? "Selected contacts" : "All contacts")
                    if contacts.authorization == .limited {
                        Button("Choose contacts") { showPicker = true }
                    }
                    Button("Refresh contacts") { Task { await contacts.refresh(account: account, force: true) } }
                    Button("Stop syncing", role: .destructive) { contacts.disconnect() }
                } else if contacts.authorization == .denied || contacts.authorization == .restricted {
                    Text("Contacts access is off in iOS Settings.").foregroundStyle(Theme.secondaryLabel)
                    Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                } else {
                    Button("Sync contacts") { Task { await contacts.connect(account: account) } }
                }
                if contacts.isLoading { ProgressView("Syncing…") }
                if let error = contacts.errorMessage { Text(error).foregroundStyle(.red) }
            } header: { Text("Contacts on this iPhone") } footer: {
                Text("Phone numbers are sent securely to check for accounts. Names and photos stay on your phone; we don’t save your address book on our servers. Stopping sync clears this list. You can revoke permission in iOS Settings.")
            }
            if let account {
                Section {
                    Button("Your number & discoverability") { showPhone = true }
                } footer: { Text("Add a verified phone number so people who have it can find your account. This doesn’t share your location.") }
                .sheet(isPresented: $showPhone) { PhoneDiscoveryView(account: account) }
            }
        }
        .navigationTitle("Contacts").navigationBarTitleDisplayMode(.inline)
        .contactAccessPicker(isPresented: $showPicker) { _ in
            Task { await contacts.refresh(account: account, force: true) }
        }
        .tint(Theme.accent)
    }
}

struct InviteContactView: View {
    let contact: DeviceContact
    let isPreview: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var destination: InviteDestination?
    private var invitation: String { ContactInvitation.message }

    var body: some View {
        NavigationStack {
            ThemedList {
                Section {
                    Text(invitation)
                } header: { Text("Invite \(contact.name)") } footer: {
                    Text(isPreview ? "Sample contact. Invitations aren’t sent in preview." : ContactInvitation.downloadURL == nil
                         ? "You can edit the message and add a TestFlight link before sending."
                         : "You can edit the message before sending.")
                }
                if !isPreview {
                    if MFMessageComposeViewController.canSendText() {
                        Section("Message") {
                            ForEach(contact.messageNumbers, id: \.self) { phone in
                                Button(phone) { destination = InviteDestination(address: phone, isEmail: false) }
                            }
                        }
                    }
                    if MFMailComposeViewController.canSendMail() {
                        Section("Email") {
                            ForEach(contact.emails, id: \.self) { email in
                                Button(email) { destination = InviteDestination(address: email, isEmail: true) }
                            }
                        }
                    }
                    Section { ShareLink(item: invitation) { Label("Share invite", systemImage: "square.and.arrow.up") } }
                }
            }
            .navigationTitle("Invite").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $destination) { destination in
                InviteMessageComposer(destination: destination, text: invitation) { self.destination = nil }
            }
        }.tint(Theme.accent).presentationDetents([.medium, .large]).presentationBackground(Theme.background)
    }
}

private struct InviteDestination: Identifiable {
    var id: String { "\(isEmail)-\(address)" }
    let address: String
    let isEmail: Bool
}

private struct InviteMessageComposer: UIViewControllerRepresentable {
    let destination: InviteDestination
    let text: String
    let onDismiss: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }
    func makeUIViewController(context: Context) -> UIViewController {
        if destination.isEmail {
            let controller = MFMailComposeViewController()
            controller.setToRecipients([destination.address])
            controller.setSubject("Let’s hang out")
            controller.setMessageBody(text, isHTML: false)
            controller.mailComposeDelegate = context.coordinator
            return controller
        }
        let controller = MFMessageComposeViewController()
        controller.recipients = [destination.address]
        controller.body = text
        controller.messageComposeDelegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate, MFMailComposeViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) { onDismiss() }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) { onDismiss() }
    }
}

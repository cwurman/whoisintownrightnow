import SwiftUI
import MapKit

struct MapHomeView: View {
    var profile: AccountProfile? = nil
    var accountStore: AccountStore? = nil
    var contactsStore: ContactsStore? = nil
    @State private var previewContacts = ContactsStore(accountID: nil)
    private var activeContacts: ContactsStore { contactsStore ?? previewContacts }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var signals = Signal.mock
    @State private var selectedSignalID: Signal.ID?
    @State private var selectedFriend: Friend?
    @State private var showPanel = false
    @State private var panelDetent: PresentationDetent = .height(300)
    @State private var panelHeight: CGFloat = 334
    @State private var isChangingPanelDetents = false
    @State private var showComposer = false
    @State private var showSettings = false
    @State private var showFriends = false
    @State private var confirmation: PostedConfirmation?
    @State private var pendingConfirmation: PostedConfirmation?
    @State private var mapCamera = HangMapCameraController()
    @State private var overviewPanelDetent: PresentationDetent?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    #if DEBUG
    @State private var previewSettings = PreviewAccountSettings()
    #endif

    private var activeProfile: AccountProfile? {
        #if DEBUG
        profile ?? previewSettings.profile
        #else
        profile
        #endif
    }

    private static var overviewRect: MKMapRect {
        let points = (Friend.mock.map(\.coordinate) + [Friend.youCoordinate]).map(MKMapPoint.init)
        let bounds = points.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1))) }
        return bounds.insetBy(dx: -bounds.width * 0.12, dy: -bounds.height * 0.12)
    }
    private struct CollapsedHangDetent: CustomPresentationDetent {
        static func height(in context: Context) -> CGFloat? {
            context.dynamicTypeSize.isAccessibilitySize ? 140 : 90
        }
    }
    private static let collapsedDetent = PresentationDetent.custom(CollapsedHangDetent.self)
    private var selectedSignal: Signal? { signals.first { $0.id == selectedSignalID } }
    private var hasSelection: Bool { selectedSignal != nil || selectedFriend != nil }
    private var isPanelCollapsed: Bool { !hasSelection && panelDetent == Self.collapsedDetent }
    private var panelDetents: Set<PresentationDetent> {
        // Keep the departing stop valid until the native transition finishes.
        // Removing a selected detent first makes UIKit snap to its smallest stop.
        if isChangingPanelDetents { return [Self.collapsedDetent, .height(300), .medium, .large] }
        return hasSelection ? [.medium, .large] : [Self.collapsedDetent, .height(300), .large]
    }
    private var panelTitle: String {
        selectedSignal != nil ? "" : selectedFriend?.firstName ?? "Today"
    }
    private var mapSignals: [Signal] {
        var seen = Set<String>()
        return signals.filter { seen.insert($0.hostID).inserted }.map { signal in
            selectedSignal?.hostID == signal.hostID ? selectedSignal! : signal
        }
    }

    var body: some View {
        map
            .overlay(alignment: .topTrailing) { mapControls.padding(16) }
            .task {
                if dynamicTypeSize.isAccessibilitySize { panelDetent = .large }
                showPanel = true
            }
            .onChange(of: dynamicTypeSize) {
                if dynamicTypeSize.isAccessibilitySize { panelDetent = .large }
            }
            .sheet(isPresented: $showPanel) {
                panel
                    .presentationDetents(panelDetents, selection: $panelDetent)
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: hasSelection || isChangingPanelDetents ? .medium : .height(300)))
                    .interactiveDismissDisabled()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
            }
            .tint(Theme.accent)
            .onDisappear { toastTask?.cancel() }
    }

    private var map: some View {
        HangMapView(camera: mapCamera, overviewRect: Self.overviewRect,
                    signals: mapSignals, selectedSignal: selectedSignal, selectedFriend: selectedFriend,
                    ownHostID: activeProfile?.id.uuidString.lowercased() ?? "you",
                    panelHeight: panelHeight, reduceMotion: reduceMotion,
                    onSelectSignal: { focus(on: $0) }, onSelectFriend: { focus(on: $0) },
                    onCameraSettled: { isChangingPanelDetents = false })
            .ignoresSafeArea()
            .transaction { $0.animation = nil }
    }

    private var mapControls: some View {
        HStack(spacing: 2) {
            Button {
                clearFocus()
            } label: {
                Image(systemName: "location.fill").font(.system(size: 20))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Show everyone on the map")
            Button { showFriends = true } label: {
                Image(systemName: "person.2.fill").font(.system(size: 20))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Friends")
            .accessibilityIdentifier("show-friends")
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 20))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("profile-settings")
        }
        .buttonStyle(.plain)
        .tint(Theme.label)
        .padding(4)
        .glassEffect(.regular.tint(Theme.cocoa.opacity(0.18)), in: .capsule)
    }

    private var panel: some View {
        NavigationStack {
            Group {
                if isPanelCollapsed {
                    createHangButton
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Center within the glass, including the sheet's bottom safe area.
                        .ignoresSafeArea(.container, edges: .bottom)
                } else if let selectedSignal {
                    SignalDetailSheet(signal: selectedSignal, onJoin: { join(selectedSignal) })
                } else if let selectedFriend {
                    friendDetails(selectedFriend)
                } else {
                    overviewList
                }
            }
            .navigationTitle(hasSelection ? panelTitle : "")
            .toolbarTitleDisplayMode(.inline)
            .toolbarVisibility(hasSelection ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if hasSelection {
                        Button("Back", systemImage: "chevron.left", action: clearFocus)
                            .accessibilityIdentifier("close-signal-detail")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let toast, !isPanelCollapsed {
                    Text(toast).font(.footnote).foregroundStyle(Theme.secondaryLabel)
                        .padding().frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                        .accessibilityIdentifier("preview-status")
                }
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $showComposer, onDismiss: {
            confirmation = pendingConfirmation
            pendingConfirmation = nil
        }) {
            ComposerView(analyzeInvitation: { video in
                guard let accountStore else { throw HangAnalysisError.signInRequired }
                return try await accountStore.draftHang(from: video)
            }, onPost: handlePost)
                .presentationBackground(Theme.background)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $confirmation) { posted in
            ConfirmationView(confirmation: posted) { confirmation = nil }
                .presentationBackground(Theme.background)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            if let accountStore {
                AccountSettingsView(store: accountStore, isOnboarding: false, contacts: activeContacts)
            } else {
                #if DEBUG
                AccountSettingsView(preview: previewSettings, contacts: activeContacts)
                #else
                NavigationStack {
                    ContentUnavailableView("Your account", systemImage: "person.crop.circle", description: Text("Sign in to personalize your profile and sharing preferences. You’re viewing the map preview."))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                }
                #endif
            }
        }
        .sheet(isPresented: $showFriends) {
            FriendsView(contacts: activeContacts, account: accountStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var overviewList: some View {
        List {
            Section {
                ForEach(signals) { signal in
                    SignalRowView(signal: signal, onJoin: { join(signal) }, onTap: { focus(on: signal) })
                }
            } footer: {
                Label("Preview · sample people and plans", systemImage: "info.circle")
                    .font(.footnote).padding(.top, 8)
            }
            .listRowBackground(Theme.panelRow)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text(panelTitle)
                .font(.largeTitle.bold())
                .foregroundStyle(Theme.label)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            createHangButton.background(.regularMaterial)
        }
    }

    private var createHangButton: some View {
        Button { showComposer = true } label: {
            Label("Let’s hang", systemImage: "plus")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(Theme.orchid)
        .foregroundStyle(Theme.ink)
        .accessibilityIdentifier("new-signal")
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func friendDetails(_ friend: Friend) -> some View {
        List {
            Section {
                HStack(spacing: 16) {
                    PersonAvatar(initials: friend.initials, color: friend.color, size: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(friend.name).font(.title2.bold())
                        Label(friend.isFree ? "Free to hang out" : "Not available", systemImage: friend.isFree ? "circle.fill" : "moon.fill")
                            .font(.subheadline).foregroundStyle(friend.isFree ? Theme.accent : Theme.secondaryLabel)
                    }
                }.padding(.vertical, 8)
                Label(friend.hood, systemImage: "location")
                LabeledContent("Distance", value: friend.distanceLabel)
                Text(friend.note).foregroundStyle(Theme.secondaryLabel)
            }
            .listRowBackground(Theme.panelRow)
            let hosted = signals.filter { $0.hostID == friend.id }
            if !hosted.isEmpty {
                Section("Hangs") {
                    ForEach(hosted) { signal in
                        Button { focus(on: signal) } label: {
                            Label { Text(signal.title) } icon: {
                                Text(signal.activityEmoji).accessibilityHidden(true)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.panelRow)
            }
            Section { Text("This is a sample profile and location.").font(.footnote).foregroundStyle(Theme.secondaryLabel) }
                .listRowBackground(Theme.panelRow)
        }
        .scrollContentBackground(.hidden)
    }

    private func panelExtent(for detent: PresentationDetent) -> MapPanelExtent {
        if detent == Self.collapsedDetent { return .collapsed }
        if detent == .height(300) { return .overview }
        if detent == .large { return .expanded }
        return .details
    }

    private func rememberOverview() {
        if !hasSelection { overviewPanelDetent = panelDetent }
    }

    private func focus(on signal: Signal) {
        rememberOverview()
        let detent: PresentationDetent = dynamicTypeSize.isAccessibilitySize || signal.video != nil ? .large : .medium
        let moved = mapCamera.focus(on: SignalConnection(signal: signal).mapRect,
                        panel: panelExtent(for: detent), animated: !reduceMotion)
        isChangingPanelDetents = moved && !reduceMotion
        selectedFriend = nil
        selectedSignalID = signal.id
        panelDetent = detent
    }

    private func focus(on friend: Friend) {
        rememberOverview()
        let detent: PresentationDetent = dynamicTypeSize.isAccessibilitySize ? .large : .medium
        let center = MKMapPoint(friend.coordinate)
        let size = MKMapPointsPerMeterAtLatitude(friend.coordinate.latitude) * 2000
        let rect = MKMapRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let moved = mapCamera.focus(on: rect, panel: panelExtent(for: detent), animated: !reduceMotion)
        isChangingPanelDetents = moved && !reduceMotion
        selectedSignalID = nil
        selectedFriend = friend
        panelDetent = detent
    }

    private func clearFocus() {
        let detent = dynamicTypeSize.isAccessibilitySize ? .large : overviewPanelDetent ?? panelDetent
        let moved = mapCamera.showOverview(panel: panelExtent(for: detent), animated: !reduceMotion)
        isChangingPanelDetents = moved && !reduceMotion
        selectedSignalID = nil
        selectedFriend = nil
        panelDetent = detent
        overviewPanelDetent = nil
    }

    private func handlePost(_ draft: ComposerDraft) {
        guard showComposer, draft.canPost else { return }
        let signal = Signal(id: "me-\(UUID().uuidString)",
            hostID: activeProfile?.id.uuidString.lowercased() ?? "you", hostName: activeProfile?.displayName ?? "You",
            hostInitials: activeProfile?.initials ?? "You", hostColor: Theme.cocoa,
            title: draft.text.trimmingCharacters(in: .whitespacesAndNewlines), place: draft.placeText,
            window: draft.whenText, distance: "you", seats: draft.seats ?? 0,
            going: [activeProfile?.initials ?? "You"], isJoined: true, isMine: true,
            anchorCoordinate: Friend.youCoordinate, anchorPlace: "Mission", destinationCoordinate: draft.placeCoordinate,
            video: draft.videoAttachment.video)
        signals.insert(signal, at: 0)
        clearFocus()
        pendingConfirmation = PostedConfirmation(signal: signal, pinged: draft.selectedFriends,
            note: draft.selectedFriends.isEmpty ? "No friends selected" : "\(draft.selectedFriends.count) friends selected")
        showComposer = false
    }

    private func join(_ signal: Signal) {
        guard let index = signals.firstIndex(where: { $0.id == signal.id }), !signals[index].isJoined, !signals[index].isMine else { return }
        signals[index].isJoined = true
        signals[index].going.append(activeProfile?.initials ?? "You")
        toastTask?.cancel()
        toast = "Joined in this preview. \(signal.hostFirstName) hasn’t been notified."
        toastTask = Task {
            do { try await Task.sleep(for: .seconds(4)); toast = nil } catch { }
        }
    }
}

struct PersonAvatar: View {
    let initials: String
    let color: Color
    var size: CGFloat = 44
    var body: some View {
        Text(initials).font(.system(size: size * 0.32, weight: .semibold, design: .rounded))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

struct PersonMapMarker: View {
    let initials: String
    let name: String
    let color: Color
    var activityEmoji: String? = nil
    var animatesHalo = true
    var body: some View {
        VStack(spacing: 4) {
            PersonAvatar(initials: initials, color: color, size: 42)
                .padding(3).background(Theme.orchid, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                .background {
                    if activityEmoji != nil { ActiveHangHalo(animates: animatesHalo) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let activityEmoji {
                        Text(activityEmoji)
                            .font(.system(size: 18))
                            .frame(width: 26, height: 26).background(Theme.surface, in: Circle())
                            .overlay(Circle().stroke(Theme.orchid, lineWidth: 1.5))
                            .accessibilityHidden(true)
                    }
                }
            Text(name).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
        }
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// Decorative waves stay behind the avatar without changing its layout or tap target.
private struct ActiveHangHalo: View {
    var animates = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.orchid.opacity(0.5), Theme.orchid.opacity(0)],
                                     center: .center, startRadius: 22, endRadius: 43))
                .frame(width: 86, height: 86)
            if animates && !reduceMotion && scenePhase == .active {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let cycle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                    ZStack {
                        ForEach(0..<2) { index in
                            let progress = (cycle + Double(index) / 2).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(Theme.accent.opacity(0.5 * pow(1 - progress, 1.5)), lineWidth: 1.5)
                                .frame(width: 48 + 36 * progress, height: 48 + 36 * progress)
                        }
                    }
                    .frame(width: 86, height: 86)
                }
            } else {
                Circle().stroke(Theme.orchid.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 58, height: 58)
            }
        }
        .frame(width: 48, height: 48)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct FriendAvatarView: View {
    let friend: Friend
    var body: some View { PersonAvatar(initials: friend.initials, color: friend.color) }
}

struct SignalPinView: View {
    let signal: Signal
    var animatesHalo = true
    var body: some View {
        PersonMapMarker(initials: signal.hostInitials, name: signal.hostFirstName, color: signal.hostColor,
                        activityEmoji: signal.activityEmoji, animatesHalo: animatesHalo)
    }
}

struct SignalDestinationView: View {
    let signal: Signal
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "mappin.circle.fill").font(.system(size: 38))
                .symbolRenderingMode(.palette).foregroundStyle(Theme.ink, Theme.orchid)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            Text(signal.place).font(.caption.weight(.semibold)).padding(8)
                .background(.regularMaterial, in: Capsule())
        }.fixedSize()
    }
}

struct PersonRow: View {
    let friend: Friend
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 14) {
            PersonAvatar(initials: friend.initials, color: friend.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(friend.name).font(.headline)
                Text(friend.hood).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                if dynamicTypeSize.isAccessibilitySize { status }
            }
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize { status }
        }.padding(.vertical, 5).foregroundStyle(Theme.label).contentShape(Rectangle())
    }

    private var status: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 5) {
            Text(friend.distanceLabel).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
            if friend.isFree { Text("Free now").font(.caption).foregroundStyle(Theme.accent) }
        }
    }
}

struct SignalRowView: View {
    let signal: Signal
    let onJoin: () -> Void
    let onTap: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    PersonAvatar(initials: signal.hostInitials, color: signal.hostColor)
                        .overlay(alignment: .bottomTrailing) {
                            if signal.video != nil {
                                Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.ink).padding(5)
                                    .background(Theme.orchid, in: Circle()).accessibilityHidden(true)
                            }
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(signal.title).font(.headline).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        Text("\(signal.hostFirstName) · \(signal.window)").font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle()).foregroundStyle(Theme.label)
            }.buttonStyle(.plain).accessibilityHint(signal.video == nil ? "Show hang details" : "Show hang details and video invitation")
            Button(action: onJoin) {
                if signal.isJoined || signal.isMine { Image(systemName: "checkmark") }
                else { Text("Join").fontWeight(.semibold) }
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
            .disabled(signal.isJoined || signal.isMine)
            .accessibilityLabel(signal.isMine ? "Your hang" : signal.isJoined ? "Already joined" : "Join \(signal.hostFirstName)’s hang")
        }.padding(.vertical, 5)
    }
}

struct SignalDetailSheet: View {
    let signal: Signal
    let onJoin: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    PersonAvatar(initials: signal.hostInitials, color: signal.hostColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(signal.isMine ? "Your invitation" : "\(signal.hostFirstName) wants to hang").font(.headline)
                        Text(signal.anchorPlace).font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                    }
                }
                if let video = signal.video {
                    HangVideoPoster(video: video, title: signal.isMine ? "your invitation" : "\(signal.hostFirstName)’s invitation")
                }
                Text(signal.title).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 10) {
                    Label(signal.place, systemImage: "mappin.and.ellipse")
                    Label(signal.window, systemImage: "clock")
                        .foregroundStyle(Theme.secondaryLabel)
                }
                attendance
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .accessibilityIdentifier("signal-detail")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button(action: onJoin) {
                    Label(signal.isMine ? "Your hang" : signal.isJoined ? "You’re in" : "Join \(signal.hostFirstName)",
                          systemImage: signal.isJoined ? "checkmark.circle.fill" : "person.badge.plus")
                        .frame(maxWidth: .infinity).font(.headline).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                .tint(Theme.orchid).foregroundStyle(Theme.ink)
                .disabled(signal.isMine || signal.isJoined).accessibilityIdentifier("join-signal")
                Text("Preview only · No notifications sent").font(.caption).foregroundStyle(Theme.secondaryLabel)
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.regularMaterial)
        }
    }

    private var attendance: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 20))
        return layout {
            Label("\(signal.going.count) going", systemImage: "person.2")
            if signal.seats > 0 { Text("Group limit: \(signal.seats)") }
        }
        .font(.subheadline)
        .foregroundStyle(Theme.secondaryLabel)
    }
}

struct YouDotView: View {
    var body: some View {
        Circle().fill(.blue).frame(width: 16, height: 16)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .padding(12).background(Color.blue.opacity(0.20), in: Circle())
            .accessibilityLabel("Your sample location")
    }
}

struct BatSignalShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 100
        let sy = rect.height / 46
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
        }

        var path = Path()
        // Left wing tip, sweeping up and over to the shoulder
        path.move(to: p(0, 15))
        path.addQuadCurve(to: p(35, 7), control: p(13, -1))
        path.addLine(to: p(43, 7))
        // Left ear
        path.addLine(to: p(44.5, 0))
        path.addLine(to: p(47.2, 6))
        // Rounded head between the ears
        path.addQuadCurve(to: p(52.8, 6), control: p(50, 4.5))
        // Right ear
        path.addLine(to: p(55.5, 0))
        path.addLine(to: p(57, 7))
        path.addLine(to: p(65, 7))
        // Right wing top out to the tip
        path.addQuadCurve(to: p(100, 15), control: p(87, -1))
        // Right wing membrane: two scallops in to the tail
        path.addQuadCurve(to: p(77, 26), control: p(87, 17))
        path.addQuadCurve(to: p(61, 31), control: p(68, 25))
        // Tail point
        path.addQuadCurve(to: p(50, 46), control: p(55, 32))
        // Left wing membrane, mirrored
        path.addQuadCurve(to: p(39, 31), control: p(45, 32))
        path.addQuadCurve(to: p(23, 26), control: p(32, 25))
        path.addQuadCurve(to: p(0, 15), control: p(13, 17))
        path.closeSubpath()
        return path
    }
}


#Preview { MapHomeView() }

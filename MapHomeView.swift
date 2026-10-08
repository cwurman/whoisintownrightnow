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
    @State private var viewportHeight: CGFloat = 800
    @State private var showComposer = false
    @State private var showSettings = false
    @State private var showFriends = false
    @State private var confirmation: PostedConfirmation?
    @State private var pendingConfirmation: PostedConfirmation?
    @State private var cameraPosition: MapCameraPosition = .rect(overviewRect)
    @State private var lastCamera: MapCamera?
    @State private var overviewViewport: OverviewViewport?
    @State private var returnCamera: MapCameraPosition?
    @State private var cameraRequestID = UUID()
    @State private var focusProjection: SignalMapProjection?
    @State private var connectionProgress = 0.0
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
        hasSelection ? [.medium, .large] : [Self.collapsedDetent, .height(300), .large]
    }
    private var panelTitle: String {
        selectedSignal != nil ? "" : selectedFriend?.firstName ?? "Today"
    }
    private var focusAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.4) }
    private var returnAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.55) }
    private struct OverviewViewport {
        let camera: MapCameraPosition
        let panelDetent: PresentationDetent
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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .task {
                if dynamicTypeSize.isAccessibilitySize { panelDetent = .large }
                showPanel = true
            }
            .onChange(of: dynamicTypeSize) {
                if dynamicTypeSize.isAccessibilitySize { panelDetent = .large }
            }
            .onChange(of: panelDetent) {
                // Sheet resizing should reveal more of the map without refitting the
                // initial overview bounds (which can zoom far out at the largest detent).
                if !hasSelection, returnCamera == nil, let lastCamera {
                    cameraPosition = .camera(lastCamera)
                }
            }
            .task(id: "\(cameraRequestID)-\(Int(panelHeight))") {
                guard hasSelection || returnCamera != nil else { return }
                // In both directions, let the sheet and map insets settle before moving
                // the camera. Changing the layout during the return can interrupt its animation.
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 200)) } catch { return }
                if let selectedSignal {
                    withAnimation(focusAnimation) { cameraPosition = .rect(SignalConnection(signal: selectedSignal).mapRect) }
                    await drawConnection()
                } else if let selectedFriend {
                    withAnimation(focusAnimation) {
                        cameraPosition = .region(MKCoordinateRegion(center: selectedFriend.coordinate,
                            latitudinalMeters: 2000, longitudinalMeters: 2000))
                    }
                } else if let returnCamera {
                    withAnimation(returnAnimation) { cameraPosition = returnCamera }
                    // Keep the original overview through the animation so a quick refocus
                    // doesn't replace it with a camera sampled halfway through the return.
                    do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 550)) } catch { return }
                    self.returnCamera = nil
                    overviewViewport = nil
                }
            }
            .sheet(isPresented: $showPanel) {
                panel
                    .presentationDetents(panelDetents, selection: $panelDetent)
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: hasSelection ? .medium : .height(300)))
                    .interactiveDismissDisabled()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
            }
            .tint(Theme.accent)
            .onDisappear { toastTask?.cancel() }
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                ForEach(Friend.mock) { friend in
                    if selectedFriend?.id == friend.id {
                        MapCircle(center: friend.coordinate, radius: 805)
                            .foregroundStyle(Theme.orchid.opacity(0.15))
                            .stroke(Theme.orchid.opacity(0.65), lineWidth: 1)
                    }
                    if !mapSignals.contains(where: { $0.hostID == friend.id }) {
                        Annotation(friend.name, coordinate: friend.coordinate) {
                            Button { focus(on: friend) } label: {
                                PersonMapMarker(initials: friend.initials, name: friend.firstName, color: friend.color)
                            }
                            .buttonStyle(.plain)
                            .opacity(selectedSignalID == nil ? 1 : 0.35)
                            .accessibilityLabel("\(friend.name), \(friend.hood)")
                        }.annotationTitles(.hidden)
                    }
                }
                ForEach(mapSignals) { signal in
                    Annotation(signal.hostName, coordinate: signal.anchorCoordinate) {
                        Button { focus(on: signal) } label: {
                            SignalPinView(signal: signal, animatesHalo: selectedSignalID == nil)
                        }
                            .buttonStyle(.plain)
                            .opacity(selectedSignalID == signal.id ? 0 : selectedSignalID == nil ? 1 : 0.35)
                            .accessibilityLabel("\(signal.hostName)’s hang: \(signal.title)")
                            .accessibilityIdentifier("signal-pin-\(signal.id)")
                    }.annotationTitles(.hidden)
                }
                if !mapSignals.contains(where: { $0.hostID == (activeProfile?.id.uuidString.lowercased() ?? "you") }) {
                    Annotation("You", coordinate: Friend.youCoordinate) { YouDotView() }
                        .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapScaleView() }
            .safeAreaPadding(.top, 115)
            .safeAreaPadding(.bottom, min(panelHeight + 70, viewportHeight * 0.78))
            .safeAreaPadding(.horizontal, hasSelection ? 55 : 20)
            .onMapCameraChange(frequency: .continuous) { context in
                lastCamera = context.camera
                focusProjection = selectedSignal.flatMap { SignalMapProjection(signal: $0, proxy: proxy) }
            }
            .onChange(of: selectedSignalID) {
                focusProjection = selectedSignal.flatMap { SignalMapProjection(signal: $0, proxy: proxy) }
            }
            .overlay {
                GeometryReader { geometry in
                    if let selectedSignal, let focusProjection, focusProjection.signalID == selectedSignal.id {
                        SignalFocusOverlay(signal: selectedSignal, projection: focusProjection,
                                           progress: connectionProgress, reduceMotion: reduceMotion)
                            .offset(x: -geometry.frame(in: .global).minX, y: -geometry.frame(in: .global).minY)
                            .transaction { $0.animation = nil }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .ignoresSafeArea()
        }
    }

    private var mapControls: some View {
        HStack(spacing: 2) {
            Button { showFriends = true } label: {
                Image(systemName: "person.2.fill").font(.system(size: 20))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Friends")
            .accessibilityIdentifier("show-friends")
            Button {
                clearFocus()
                returnCamera = .rect(Self.overviewRect)
                cameraRequestID = UUID()
            } label: {
                Image(systemName: "location.fill").font(.system(size: 20))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Show everyone on the map")
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

    private func rememberOverview() {
        if !hasSelection, overviewViewport == nil {
            overviewViewport = OverviewViewport(camera: lastCamera.map { .camera($0) } ?? cameraPosition,
                                                panelDetent: panelDetent)
        }
        returnCamera = nil
        cameraRequestID = UUID()
    }

    private func focus(on signal: Signal) {
        rememberOverview()
        selectedFriend = nil
        selectedSignalID = signal.id
        panelDetent = dynamicTypeSize.isAccessibilitySize || signal.video != nil ? .large : .medium
    }

    private func focus(on friend: Friend) {
        rememberOverview()
        selectedSignalID = nil
        selectedFriend = friend
        panelDetent = dynamicTypeSize.isAccessibilitySize ? .large : .medium
    }

    private func clearFocus() {
        returnCamera = overviewViewport?.camera
        cameraRequestID = UUID()
        withAnimation(returnAnimation) {
            selectedSignalID = nil
            selectedFriend = nil
            connectionProgress = 0
            if let overviewViewport {
                panelDetent = dynamicTypeSize.isAccessibilitySize ? .large : overviewViewport.panelDetent
            }
        }
    }

    @MainActor private func drawConnection() async {
        guard let selectedSignal, !selectedSignal.destinationIsAtAnchor else { return }
        connectionProgress = 0
        if reduceMotion { connectionProgress = 1; return }
        do {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            connectionProgress = 1
        } catch { }
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

private struct PersonMapMarker: View {
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

private struct SignalMapProjection {
    let signalID: Signal.ID
    let origin: CGPoint
    let destination: CGPoint
    let connection: [CGPoint]

    init?(signal: Signal, proxy: MapProxy) {
        guard let origin = proxy.convert(signal.anchorCoordinate, to: .global),
              let destination = proxy.convert(signal.destinationCoordinate, to: .global) else { return nil }
        self.signalID = signal.id
        self.origin = origin
        self.destination = destination
        self.connection = SignalConnection(signal: signal).coordinates(through: 1).compactMap {
            proxy.convert($0, to: .global)
        }
    }
}

private struct SignalFocusOverlay: View {
    let signal: Signal
    let projection: SignalMapProjection
    let progress: Double
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if !signal.destinationIsAtAnchor {
                ZStack {
                    connectionPath
                        .trim(from: 0, to: progress)
                        .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                    connectionPath
                        .trim(from: 0, to: progress)
                        .stroke(Theme.orchid, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.9), value: progress)

                SignalDestinationView(signal: signal)
                    .position(projection.destination)
            }

            SignalPinView(signal: signal)
                .position(projection.origin)
        }
    }

    private var connectionPath: Path {
        Path { path in
            path.addLines(projection.connection)
        }
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

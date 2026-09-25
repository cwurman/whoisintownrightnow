import SwiftUI
import MapKit

struct MapHomeView: View {
    var profile: AccountProfile? = nil
    var avatarData: Data? = nil
    var accountStore: AccountStore? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var signals = Signal.mock
    @State private var section: MapSection = .people
    @State private var selectedSignalID: Signal.ID?
    @State private var selectedFriend: Friend?
    @State private var showPanel = false
    @State private var panelDetent: PresentationDetent = .height(300)
    @State private var panelHeight: CGFloat = 334
    @State private var viewportHeight: CGFloat = 800
    @State private var showComposer = false
    @State private var showSettings = false
    @State private var confirmation: PostedConfirmation?
    @State private var pendingConfirmation: PostedConfirmation?
    @State private var satellite = false
    @State private var cameraPosition: MapCameraPosition = .rect(overviewRect)
    @State private var lastCamera: MapCamera?
    @State private var overviewCamera: MapCameraPosition?
    @State private var focusProjection: SignalMapProjection?
    @State private var connectionProgress = 0.0
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?

    private static var overviewRect: MKMapRect {
        let points = (Friend.mock.map(\.coordinate) + [Friend.youCoordinate]).map(MKMapPoint.init)
        let bounds = points.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1))) }
        return bounds.insetBy(dx: -bounds.width * 0.12, dy: -bounds.height * 0.12)
    }
    private enum MapSection: String, CaseIterable { case people = "People", signals = "Signals" }
    private var selectedSignal: Signal? { signals.first { $0.id == selectedSignalID } }
    private var hasSelection: Bool { selectedSignal != nil || selectedFriend != nil }
    private var panelTitle: String { selectedSignal != nil ? "Signal" : selectedFriend?.firstName ?? section.rawValue }
    private var focusAnimation: Animation? { reduceMotion ? nil : .smooth(duration: 0.4) }
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
            .task { showPanel = true }
            .task(id: "\(selectedSignalID ?? selectedFriend?.id ?? "")-\(Int(panelHeight))") {
                guard hasSelection else { return }
                // Fit after the native sheet settles, using its actual occupied map area.
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 200)) } catch { return }
                if let selectedSignal {
                    withAnimation(focusAnimation) { cameraPosition = .rect(SignalConnection(signal: selectedSignal).mapRect) }
                    await drawConnection()
                } else if let selectedFriend {
                    withAnimation(focusAnimation) {
                        cameraPosition = .region(MKCoordinateRegion(center: selectedFriend.coordinate,
                            latitudinalMeters: 2000, longitudinalMeters: 2000))
                    }
                }
            }
            .sheet(isPresented: $showPanel) {
                panel
                    .presentationDetents([.height(300), .medium, .large], selection: $panelDetent)
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
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
                            .foregroundStyle(Theme.accent.opacity(0.10))
                            .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
                    }
                    if !mapSignals.contains(where: { $0.hostID == friend.id }) {
                        Annotation(friend.name, coordinate: friend.coordinate) {
                            Button { focus(on: friend) } label: {
                                PersonMapMarker(initials: friend.initials, name: friend.firstName, color: friend.color, hasSignal: false)
                            }
                            .buttonStyle(.plain)
                            .opacity(selectedSignalID == nil ? 1 : 0.35)
                            .accessibilityLabel("\(friend.name), \(friend.hood)")
                        }.annotationTitles(.hidden)
                    }
                }
                ForEach(mapSignals) { signal in
                    Annotation(signal.hostName, coordinate: signal.anchorCoordinate) {
                        Button { focus(on: signal) } label: { SignalPinView(signal: signal) }
                            .buttonStyle(.plain)
                            .opacity(selectedSignalID == signal.id ? 0 : selectedSignalID == nil ? 1 : 0.35)
                            .accessibilityLabel("\(signal.hostName)’s signal: \(signal.title)")
                            .accessibilityIdentifier("signal-pin-\(signal.id)")
                    }.annotationTitles(.hidden)
                }
                if !mapSignals.contains(where: { $0.hostID == (profile?.id.uuidString.lowercased() ?? "you") }) {
                    Annotation("You", coordinate: Friend.youCoordinate) { YouDotView() }
                        .annotationTitles(.hidden)
                }
            }
            .mapStyle(satellite ? .hybrid(elevation: .flat) : .standard(elevation: .flat, pointsOfInterest: .excludingAll))
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
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Menu {
                    Picker("Map appearance", selection: $satellite) {
                        Text("Standard").tag(false)
                        Text("Satellite").tag(true)
                    }
                } label: {
                    Image(systemName: "map").font(.title3).frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Map appearance")
                Button {
                    clearFocus()
                    withAnimation(focusAnimation) { cameraPosition = .rect(Self.overviewRect) }
                } label: {
                    Image(systemName: "location.fill").font(.title3).frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Show everyone on the map")
            }
            .tint(.primary)
        }
    }

    private var panel: some View {
        NavigationStack {
            Group {
                if let selectedSignal {
                    SignalDetailSheet(signal: selectedSignal, onJoin: { join(selectedSignal) })
                } else if let selectedFriend {
                    friendDetails(selectedFriend)
                } else {
                    overviewList
                }
            }
            .navigationTitle(panelTitle)
            .toolbarTitleDisplayMode(hasSelection ? .inline : .inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if hasSelection {
                        Button("Back", systemImage: "chevron.left", action: clearFocus)
                            .accessibilityIdentifier("close-signal-detail")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !hasSelection {
                        Button("Your settings", systemImage: "person.crop.circle") { showSettings = true }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New signal", systemImage: "plus") { showComposer = true }
                        .accessibilityIdentifier("new-signal")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let toast {
                    Text(toast).font(.footnote).foregroundStyle(.secondary)
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
        }) { ComposerView(onPost: handlePost).presentationDragIndicator(.visible) }
        .sheet(item: $confirmation) { posted in
            ConfirmationView(confirmation: posted) { confirmation = nil }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            if let accountStore {
                AccountSettingsView(store: accountStore, isOnboarding: false)
            } else {
                NavigationStack {
                    ContentUnavailableView("Your account", systemImage: "person.crop.circle", description: Text("Sign in to personalize your profile and sharing preferences. You’re viewing the map preview."))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
                }
            }
        }
    }

    private var overviewList: some View {
        List {
            Section {
                if section == .people {
                    ForEach(Friend.mock) { friend in
                        Button { focus(on: friend) } label: { PersonRow(friend: friend) }
                            .buttonStyle(.plain)
                    }
                } else {
                    ForEach(signals) { signal in
                        SignalRowView(signal: signal, onJoin: { join(signal) }, onTap: { focus(on: signal) })
                    }
                }
            } footer: {
                Label("Preview · sample people and plans", systemImage: "info.circle")
                    .font(.footnote).padding(.top, 8)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 10) {
                Picker("Map content", selection: $section) {
                    ForEach(MapSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    Text(section == .people ? "\(Friend.mock.count) friends" : "\(signals.count) signals")
                    Spacer()
                    Text("Preview")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
        }
        .animation(focusAnimation, value: section)
    }

    private func friendDetails(_ friend: Friend) -> some View {
        List {
            Section {
                HStack(spacing: 16) {
                    PersonAvatar(initials: friend.initials, color: friend.color, size: 64)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(friend.name).font(.title2.bold())
                        Label(friend.isFree ? "Free to hang out" : "Not available", systemImage: friend.isFree ? "circle.fill" : "moon.fill")
                            .font(.subheadline).foregroundStyle(friend.isFree ? Theme.accent : .secondary)
                    }
                }.padding(.vertical, 8)
                Label(friend.hood, systemImage: "location")
                LabeledContent("Distance", value: friend.distanceLabel)
                Text(friend.note).foregroundStyle(.secondary)
            }
            let hosted = signals.filter { $0.hostID == friend.id }
            if !hosted.isEmpty {
                Section("Signals") {
                    ForEach(hosted) { signal in
                        Button { focus(on: signal) } label: {
                            Label(signal.title, systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                }
            }
            Section { Text("This is a sample profile and location.").font(.footnote).foregroundStyle(.secondary) }
        }
        .scrollContentBackground(.hidden)
    }

    private func rememberOverview() {
        if !hasSelection { overviewCamera = lastCamera.map { .camera($0) } ?? cameraPosition }
    }

    private func focus(on signal: Signal) {
        rememberOverview()
        selectedFriend = nil
        selectedSignalID = signal.id
        panelDetent = .medium
    }

    private func focus(on friend: Friend) {
        rememberOverview()
        selectedSignalID = nil
        selectedFriend = friend
        panelDetent = .medium
    }

    private func clearFocus() {
        selectedSignalID = nil
        selectedFriend = nil
        connectionProgress = 0
        if let overviewCamera { withAnimation(focusAnimation) { cameraPosition = overviewCamera } }
        overviewCamera = nil
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
            hostID: profile?.id.uuidString.lowercased() ?? "you", hostName: profile?.displayName ?? "You",
            hostInitials: profile?.initials ?? "You", hostColor: .teal,
            title: draft.text.trimmingCharacters(in: .whitespacesAndNewlines), place: draft.placeText,
            window: draft.whenText, distance: "you", seats: draft.seats,
            going: [profile?.initials ?? "You"], isJoined: true, isMine: true,
            anchorCoordinate: Friend.youCoordinate, anchorPlace: "Mission", destinationCoordinate: draft.placeCoordinate)
        signals.insert(signal, at: 0)
        section = .signals
        clearFocus()
        pendingConfirmation = PostedConfirmation(signal: signal, pinged: draft.selectedFriends,
            note: draft.selectedFriends.isEmpty ? "No friends selected" : "\(draft.selectedFriends.count) friends selected")
        showComposer = false
    }

    private func join(_ signal: Signal) {
        guard let index = signals.firstIndex(where: { $0.id == signal.id }), !signals[index].isJoined, !signals[index].isMine else { return }
        signals[index].isJoined = true
        signals[index].going.append(profile?.initials ?? "You")
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
    let hasSignal: Bool
    var body: some View {
        VStack(spacing: 4) {
            PersonAvatar(initials: initials, color: color, size: 42)
                .padding(3).background(.white, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                .overlay(alignment: .bottomTrailing) {
                    if hasSignal {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Theme.accent, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            Text(name).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
        }
        .fixedSize()
    }
}

struct FriendAvatarView: View {
    let friend: Friend
    var body: some View { PersonAvatar(initials: friend.initials, color: friend.color) }
}

struct SignalPinView: View {
    let signal: Signal
    var isFocused = false
    var body: some View {
        PersonMapMarker(initials: signal.hostInitials, name: signal.hostFirstName, color: signal.hostColor, hasSignal: true)
    }
}

struct SignalDestinationView: View {
    let signal: Signal
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "mappin.circle.fill").font(.system(size: 38))
                .symbolRenderingMode(.palette).foregroundStyle(.white, Theme.accent)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            Text(signal.place).font(.caption.weight(.semibold)).padding(8)
                .background(.regularMaterial, in: Capsule())
        }.fixedSize()
    }
}

struct PersonRow: View {
    let friend: Friend
    var body: some View {
        HStack(spacing: 14) {
            PersonAvatar(initials: friend.initials, color: friend.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(friend.name).font(.headline)
                Text(friend.hood).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text(friend.distanceLabel).font(.subheadline).foregroundStyle(.secondary)
                if friend.isFree { Text("Free now").font(.caption).foregroundStyle(Theme.accent) }
            }
        }.padding(.vertical, 5).foregroundStyle(.primary).contentShape(Rectangle())
    }
}

struct SignalRowView: View {
    let signal: Signal
    let onJoin: () -> Void
    let onTap: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    PersonAvatar(initials: signal.hostInitials, color: signal.hostColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(signal.title).font(.headline).lineLimit(2)
                        Text("\(signal.hostFirstName) · \(signal.window)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle()).foregroundStyle(.primary)
            }.buttonStyle(.plain).accessibilityHint("Show signal details")
            Button(action: onJoin) {
                if signal.isJoined || signal.isMine { Image(systemName: "checkmark") }
                else { Text("Join").fontWeight(.semibold) }
            }
            .buttonStyle(.bordered).buttonBorderShape(.capsule)
            .disabled(signal.isJoined || signal.isMine)
            .accessibilityLabel(signal.isMine ? "Your signal" : signal.isJoined ? "Already joined" : "Join \(signal.hostFirstName)’s signal")
        }.padding(.vertical, 5)
    }
}

struct SignalDetailSheet: View {
    let signal: Signal
    let onJoin: () -> Void
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        PersonAvatar(initials: signal.hostInitials, color: signal.hostColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(signal.isMine ? "Your signal" : "\(signal.hostFirstName)’s signal").font(.headline)
                            Text(signal.anchorPlace).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Text(signal.title).font(.title2.bold())
                    Label(signal.place, systemImage: "mappin.and.ellipse")
                    Label(signal.window, systemImage: "clock")
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                LabeledContent("Going", value: "\(signal.going.count)")
                if signal.seats > 0 { LabeledContent("Group limit", value: "\(signal.seats)") }
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button(action: onJoin) {
                    Label(signal.isMine ? "Your signal" : signal.isJoined ? "You’re in" : "Join \(signal.hostFirstName)",
                          systemImage: signal.isJoined ? "checkmark.circle.fill" : "person.badge.plus")
                        .frame(maxWidth: .infinity).font(.headline).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                .disabled(signal.isMine || signal.isJoined).accessibilityIdentifier("join-signal")
                Text("Preview only · No notifications sent").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.regularMaterial)
        }
        .accessibilityIdentifier("signal-detail")
    }
}

struct YouDotView: View {
    var body: some View {
        Circle().fill(.blue).frame(width: 16, height: 16)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .padding(12).background(.blue.opacity(0.12), in: Circle())
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
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.9), value: progress)

                SignalDestinationView(signal: signal)
                    .position(projection.destination)
            }

            SignalPinView(signal: signal, isFocused: true)
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

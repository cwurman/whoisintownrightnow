//
//  MapHomeView.swift
//  whoisintownrightnow
//
//  Screen 01: the map home + live "Happening" sheet.
//  Full-bleed MapKit map, friend blobs at neighborhood granularity,
//  signal pins, and the bat-signal FAB.
//

import SwiftUI
import MapKit

struct MapHomeView: View {
    var profile: AccountProfile? = nil
    var avatarData: Data? = nil
    var onSettings: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewportHeight: CGFloat = 800
    @State private var selectedSignalID: Signal.ID?
    @State private var connectionProgress = 0.0
    @State private var lastCamera: MapCamera?
    @State private var focusProjection: SignalMapProjection?
    @State private var overviewCamera: MapCameraPosition?
    @State private var signals = Signal.mock
    @State private var sheetExpanded = false
    @State private var showComposer = false
    @State private var confirmation: PostedConfirmation?
    @State private var pendingConfirmation: PostedConfirmation?
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            // Center sits south of the visual middle so everyone clears the
            // top chrome and the bottom sheet.
            center: CLLocationCoordinate2D(latitude: 37.7660, longitude: -122.4300),
            span: MKCoordinateSpan(latitudeDelta: 0.113, longitudeDelta: 0.05)
        )
    )

    // MARK: Derived

    private var nearbyCount: Int { Friend.mock.filter { $0.distanceMiles < 2 }.count }
    private var freeCount: Int { Friend.mock.filter { $0.isFree }.count }
    private var visibleSignals: [Signal] { sheetExpanded ? signals : Array(signals.prefix(2)) }
    private var hiddenCount: Int { signals.count - visibleSignals.count }

    private var selectedSignal: Signal? { signals.first { $0.id == selectedSignalID } }
    private var signalingHostIDs: Set<String> { Set(signals.map(\.hostID)) }

    // A person has one anchor, even if they have sent several signals.
    private var mapSignals: [Signal] {
        var seen = Set<String>()
        return signals.filter { seen.insert($0.hostID).inserted }.map { signal in
            if let selectedSignal, selectedSignal.hostID == signal.hostID { return selectedSignal }
            return signal
        }
    }

    /// Matches the prototype: peek is fixed, open grows with visible rows.
    private var sheetHeight: CGFloat {
        if selectedSignal != nil { return min(374, viewportHeight * 0.48) }
        return sheetExpanded ? min(168 + CGFloat(visibleSignals.count) * 76, viewportHeight * 0.65) : 262
    }

    var body: some View {
        ZStack {
            map

            // Keep the layout stable while overview controls fade out of focus.
            VStack(alignment: .leading, spacing: 10) {
                topBar
                Text("Preview · sample people and plans")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(chromeBackground(cornerRadius: 10))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .opacity(selectedSignalID == nil ? 1 : 0)
            .allowsHitTesting(selectedSignalID == nil)
            .accessibilityHidden(selectedSignalID != nil)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: selectedSignalID != nil)

            // FAB rides just above the sheet and animates with it
            VStack(spacing: 18) {
                Spacer()
                if let selectedSignal {
                    SignalDetailSheet(signal: selectedSignal, onClose: clearFocus, onJoin: { join(selectedSignal) })
                        .frame(height: sheetHeight)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    HStack {
                        Spacer()
                        batSignalFAB
                            .padding(.trailing, 16)
                    }
                    HappeningSheet(
                        signals: visibleSignals,
                        hiddenCount: hiddenCount,
                        expanded: sheetExpanded,
                        onToggle: toggleSheet,
                        onJoin: join(_:),
                        onRowTap: focus(on:)
                    )
                    .frame(height: sheetHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .animation(focusAnimation, value: sheetExpanded)
            .animation(focusAnimation, value: selectedSignalID)

            if let toast {
                ToastView(message: toast)
                    .padding(.bottom, sheetHeight + 60)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: toast)
        .task(id: selectedSignalID) {
            // Apply camera movement after the focus layout has updated. Animating
            // the map's insets and its camera together makes MapKit refit twice.
            withAnimation(focusAnimation) {
                if let selectedSignal {
                    cameraPosition = .rect(SignalConnection(signal: selectedSignal).mapRect)
                } else if let overviewCamera {
                    cameraPosition = overviewCamera
                }
            }
            if selectedSignalID == nil { overviewCamera = nil }
            await drawConnection()
        }
        .sheet(isPresented: $showComposer, onDismiss: {
            confirmation = pendingConfirmation
            pendingConfirmation = nil
        }) {
            ComposerView(onPost: handlePost(_:))
                .presentationDragIndicator(.hidden)
                .presentationBackground(Theme.sheetSurface)
        }
        .sheet(item: $confirmation) { posted in
            ConfirmationView(confirmation: posted) { confirmation = nil }
                .presentationDetents([.height(440)])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.sheetSurface)
        }
        .onDisappear { toastTask?.cancel() }
    }

    // MARK: Map

    private var map: some View {
        MapReader { proxy in
            mapContent
                .onMapCameraChange(frequency: .continuous) { context in
                    lastCamera = context.camera
                    updateFocusProjection(using: proxy)
                }
                .onChange(of: selectedSignalID) {
                    updateFocusProjection(using: proxy)
                }
                .overlay {
                    GeometryReader { geometry in
                        ZStack {
                            // A screen-sized layer fades without being retiled during zoom.
                            Color.black
                                .opacity(selectedSignalID == nil ? 0 : 0.22)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: selectedSignalID != nil)

                            if let selectedSignal, let focusProjection,
                               focusProjection.signalID == selectedSignal.id {
                                SignalFocusOverlay(
                                    signal: selectedSignal,
                                    projection: focusProjection,
                                    progress: connectionProgress,
                                    reduceMotion: reduceMotion
                                )
                                .id(selectedSignal.id)
                                // Convert global projection points into this overlay's frame.
                                .offset(x: -geometry.frame(in: .global).minX,
                                        y: -geometry.frame(in: .global).minY)
                                // The live camera already animates these positions.
                                .transaction { $0.animation = nil }
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .ignoresSafeArea()
        }
    }

    private func updateFocusProjection(using proxy: MapProxy) {
        focusProjection = selectedSignal.flatMap { SignalMapProjection(signal: $0, proxy: proxy) }
    }

    private var mapContent: some View {
        Map(position: $cameraPosition) {
            ForEach(Friend.mock) { friend in
                MapCircle(center: friend.coordinate, radius: 850)
                    .foregroundStyle(Theme.signalYellow.opacity(selectedSignalID == nil ? 0.10 : 0.02))
                    .stroke(Theme.signalYellow.opacity(selectedSignalID == nil ? 0.22 : 0.04), lineWidth: 1)

                if !signalingHostIDs.contains(friend.id) {
                    Annotation(friend.name, coordinate: friend.coordinate) {
                        FriendAvatarView(friend: friend)
                            .blur(radius: selectedSignalID == nil ? 0 : 4)
                            .opacity(selectedSignalID == nil ? 1 : 0.25)
                            .animation(focusAnimation, value: selectedSignalID)
                            .onTapGesture {
                                if selectedSignalID == nil {
                                    showToast("\(friend.firstName)'s card — next screen")
                                }
                            }
                    }
                    .annotationTitles(.hidden)
                }
            }

            ForEach(mapSignals) { signal in
                Annotation(signal.hostName, coordinate: signal.anchorCoordinate) {
                    Button { focus(on: signal) } label: {
                        SignalPinView(signal: signal, isFocused: selectedSignalID == signal.id)
                    }
                    .buttonStyle(.plain)
                    .blur(radius: isDimmed(signal) ? 4 : 0)
                    .opacity(isDimmed(signal) ? 0.25 : 1)
                    .animation(focusAnimation, value: selectedSignalID)
                    // The focused pin is drawn above the dimming layer instead.
                    .opacity(selectedSignalID == signal.id ? 0 : 1)
                    .animation(nil, value: selectedSignalID == signal.id)
                    .accessibilityLabel("\(signal.isMine ? "Your" : signal.hostName + "'s") bat signal: \(signal.title)")
                    .accessibilityHint("Show their location, destination, and event details")
                    .accessibilityIdentifier("signal-pin-\(signal.id)")
                }
                .annotationTitles(.hidden)
            }

            if !signalingHostIDs.contains(profile?.id.uuidString.lowercased() ?? "you") {
                Annotation("You", coordinate: Friend.youCoordinate) {
                    YouDotView()
                        .blur(radius: selectedSignalID == nil ? 0 : 4)
                        .opacity(selectedSignalID == nil ? 1 : 0.25)
                        .animation(focusAnimation, value: selectedSignalID)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        // Camera fitting reserves room for the event panel and the floating labels.
        .safeAreaPadding(.top, selectedSignalID == nil ? 0 : min(110, viewportHeight * 0.15))
        .safeAreaPadding(.bottom, selectedSignalID == nil ? 0 : sheetHeight + 45)
        .safeAreaPadding(.horizontal, selectedSignalID == nil ? 0 : 70)
        .ignoresSafeArea()
    }

    private var focusAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88)
    }

    private func isDimmed(_ signal: Signal) -> Bool {
        selectedSignalID != nil && selectedSignalID != signal.id
    }

    // MARK: Top chrome

    private var topBar: some View {
        HStack(spacing: 8) {
            // Status pill — tap toggles the sheet
            Button(action: toggleSheet) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.ink)
                        .frame(width: 7, height: 7)
                        .background(Circle().fill(Theme.signalYellow).frame(width: 15, height: 15))
                    Text("\(nearbyCount) friends nearby")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\(freeCount) free")
                        .font(.system(size: 14))
                        .foregroundStyle(.black.opacity(0.42))
                }
                .padding(.horizontal, 13)
                .frame(height: 40)
                .background(chromeBackground(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            // Activity isn't connected yet; don't imply unread notifications exist.
            Button {
                showToast("Your activity feed isn’t available yet.")
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(chromeBackground(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Activity")

            // Profile
            Button {
                onSettings?()
            } label: {
                AccountAvatar(data: avatarData, initials: profile?.initials ?? "You")
                    .background(chromeBackground(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Your settings")
        }
    }

    private func chromeBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.white.opacity(0.84))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.09), radius: 5, y: 2)
    }

    // MARK: FAB

    private var batSignalFAB: some View {
        Button {
            showComposer = true
        } label: {
            HStack(spacing: 10) {
                BatSignalShape()
                    .fill(Theme.signalYellow)
                    .frame(width: 30, height: 14)
                Text("Send out bat signal")
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(Theme.signalYellow)
            }
            .padding(.leading, 17)
            .padding(.trailing, 20)
            .padding(.vertical, 15)
            .background(Capsule().fill(Theme.ink))
            .shadow(color: Theme.signalYellow.opacity(0.48), radius: 13, y: 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func toggleSheet() {
        if selectedSignalID != nil { clearFocus() }
        else { sheetExpanded.toggle() }
    }

    private func focus(on signal: Signal) {
        guard selectedSignalID != signal.id else { return }
        if selectedSignalID == nil {
            overviewCamera = lastCamera.map { .camera($0) } ?? cameraPosition
        }
        connectionProgress = 0
        selectedSignalID = signal.id
    }

    private func clearFocus() {
        selectedSignalID = nil
        connectionProgress = 0
    }

    @MainActor
    private func drawConnection() async {
        guard let selectedSignal, !selectedSignal.destinationIsAtAnchor else { return }
        connectionProgress = 0
        if reduceMotion {
            connectionProgress = 1
            return
        }
        // Let the camera start settling, then reveal the arc from the host outward.
        // The view task is cancelled automatically when focus changes or closes.
        do {
            try await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            connectionProgress = 1
        } catch { /* A new selection owns the next drawing. */ }
    }

    private func handlePost(_ draft: ComposerDraft) {
        guard showComposer, draft.canPost else { return }
        let signal = Signal(
            id: "me-\(UUID().uuidString)",
            hostID: profile?.id.uuidString.lowercased() ?? "you", hostName: profile?.displayName ?? "You", hostInitials: profile?.initials ?? "You", hostColor: Theme.ink,
            title: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
            place: draft.placeText,
            window: draft.whenText,
            distance: "you",
            seats: draft.seats,
            going: [profile?.initials ?? "You"], isJoined: true, isMine: true,
            anchorCoordinate: Friend.youCoordinate, anchorPlace: "Mission",
            destinationCoordinate: draft.placeCoordinate
        )
        signals.insert(signal, at: 0)
        showComposer = false

        let confirmationNote = draft.selectedFriends.isEmpty
            ? "No friends selected"
            : "\(draft.autoCount) nearby" + (draft.extraCount > 0 ? " + \(draft.extraCount) you added" : "")
        // Presentation follows actual sheet dismissal, rather than a guessed animation duration.
        pendingConfirmation = PostedConfirmation(signal: signal, pinged: draft.selectedFriends, note: confirmationNote)
    }

    private func join(_ signal: Signal) {
        guard let index = signals.firstIndex(where: { $0.id == signal.id }) else { return }
        if signals[index].isJoined || signals[index].isMine { return }
        signals[index].isJoined = true
        signals[index].going.append(profile?.initials ?? "You")
        showToast("Joined in this preview. \(signal.hostFirstName) hasn’t been notified.")
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.9))
            if !Task.isCancelled { toast = nil }
        }
    }
}

// MARK: - Focus presentation above the dimmed map

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
                        .stroke(Theme.ink, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
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

// MARK: - Friend avatar

struct FriendAvatarView: View {
    let friend: Friend

    var body: some View {
        Text(friend.initials)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(friend.color))
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
    }
}

// MARK: - Signal pin

struct SignalPinView: View {
    let signal: Signal
    var isFocused = false

    private var pillColor: Color { signal.isMine ? Theme.ink : Theme.signalYellow }
    private var labelColor: Color { signal.isMine ? Theme.signalYellow : Theme.ink }

    var body: some View {
        Text(signal.hostInitials)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(Circle().fill(signal.hostColor))
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .padding(4)
            .background(Circle().fill(Theme.signalYellow))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            .overlay(alignment: .top) {
                // Focus shows event details in the panel, leaving the avatar clear.
                if !isFocused {
                    HStack(spacing: 4) {
                        BatSignalShape().fill(labelColor).frame(width: 13, height: 6)
                        Text(signal.pinTitle)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(labelColor)
                            .lineLimit(1)
                            .frame(maxWidth: 100)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(pillColor))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .offset(y: -4)
                }
            }
            .overlay(alignment: .bottom) {
                if isFocused {
                    Text("\(signal.hostFirstName) · now")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white, in: Capsule())
                        .fixedSize()
                        .offset(y: 29)
                }
            }
    }
}

struct SignalDestinationView: View {
    let signal: Signal

    var body: some View {
        Image(systemName: "mappin")
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(Theme.signalYellow)
            .frame(width: 42, height: 42)
            .background(Theme.ink, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            .overlay(alignment: .bottom) {
                VStack(spacing: 2) {
                    Text(signal.place).font(.system(size: 12, weight: .bold))
                    Text(signal.window).font(.system(size: 11))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .fixedSize()
                .offset(y: 52)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Destination: \(signal.place), \(signal.window)")
    }
}

// MARK: - Event focus panel

struct SignalDetailSheet: View {
    let signal: Signal
    let onClose: () -> Void
    let onJoin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.black.opacity(0.16))
                .frame(width: 38, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
                .gesture(DragGesture().onEnded { value in
                    if value.translation.height > 35 { onClose() }
                })
                .accessibilityLabel("Close event details")
                .accessibilityAddTraits(.isButton)

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(spacing: 10) {
                        Text(signal.hostInitials)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(signal.hostColor, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(signal.isMine ? "Your bat signal" : "\(signal.hostFirstName)'s bat signal")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Around \(signal.anchorPlace) right now")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 36, height: 36)
                                .background(.black.opacity(0.05), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close event details")
                        .accessibilityIdentifier("close-signal-detail")
                    }

                    Text(signal.title)
                        .font(.system(size: 25, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "mappin.and.ellipse")
                            .accessibilityHidden(true)
                            .font(.system(size: 20))
                            .frame(width: 36, height: 40)
                            .background(Theme.signalYellow.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(signal.destinationIsAtAnchor ? "MEETING HERE" : "HEADING TO")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1.4)
                                .foregroundStyle(.secondary)
                            Text(signal.place).font(.system(size: 15, weight: .semibold))
                            Label(signal.window, systemImage: "clock")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack {
                        Label("\(signal.going.count) going", systemImage: "person.2")
                        if signal.seats > 0 {
                            Text("·")
                            Text("\(signal.seats) seats")
                        }
                        Spacer()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                    Button(action: onJoin) {
                        HStack {
                            Text(signal.isMine ? "Your signal is live" : signal.isJoined ? "You're in" : "Join \(signal.hostFirstName)")
                            Spacer()
                            Image(systemName: signal.isMine || signal.isJoined ? "checkmark" : "arrow.up.right")
                        }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.signalYellow)
                        .padding(16)
                        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .buttonStyle(.plain)
                    .disabled(signal.isMine || signal.isJoined)
                    .accessibilityIdentifier("join-signal")
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26)
                .fill(Theme.sheetSurface)
                .shadow(color: .black.opacity(0.14), radius: 18, y: -5)
        )
        .accessibilityIdentifier("signal-detail")
    }
}

// MARK: - You dot

struct YouDotView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack {
            // Expanding pulse ring
            Circle()
                .fill(Theme.signalYellow.opacity(0.35))
                .frame(width: 42, height: 42)
                .scaleEffect(reduceMotion ? 1 : pulsing ? 1.9 : 0.6)
                .opacity(reduceMotion ? 0.3 : pulsing ? 0 : 0.55)
                .animation(reduceMotion ? nil : .easeOut(duration: 2.6).repeatForever(autoreverses: false), value: pulsing)

            // Soft halo + dot
            Circle()
                .fill(Theme.signalYellow.opacity(0.14))
                .frame(width: 32, height: 32)
            Circle()
                .fill(Theme.ink)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .frame(width: 80, height: 80)
        .task(id: reduceMotion) { pulsing = !reduceMotion }
    }
}

// MARK: - Happening sheet

struct HappeningSheet: View {
    let signals: [Signal]
    let hiddenCount: Int
    let expanded: Bool
    let onToggle: () -> Void
    let onJoin: (Signal) -> Void
    let onRowTap: (Signal) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle — tap toggles peek/open
            Button(action: onToggle) {
                Capsule()
                    .fill(.black.opacity(0.16))
                    .frame(width: 38, height: 5)
                    .padding(.top, 13)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse signals" : "Show all signals")

            HStack(alignment: .firstTextBaseline) {
                Text("Happening")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(signals.count + hiddenCount) signals")
                    .font(.system(size: 13))
                    .foregroundStyle(.black.opacity(0.4))
            }
            .padding(.bottom, 12)

            ScrollView {
              LazyVStack(spacing: 9) {
                ForEach(signals) { signal in
                    SignalRowView(
                        signal: signal,
                        onJoin: { onJoin(signal) },
                        onTap: { onRowTap(signal) }
                    )
                }
                if !expanded && hiddenCount > 0 {
                    Button(action: onToggle) {
                        Text("+\(hiddenCount) more")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                }
              }
              .padding(.bottom, 34)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(Theme.sheetSurface.opacity(0.94))
                .background(
                    .ultraThinMaterial,
                    in: UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                )
                .shadow(color: .black.opacity(0.13), radius: 13, y: -4)
        )
    }
}

// MARK: - Signal row

struct SignalRowView: View {
    let signal: Signal
    let onJoin: () -> Void
    let onTap: () -> Void

    private var ctaLabel: String {
        if signal.isMine { return "Live" }
        return signal.isJoined ? "In ✓" : "Join"
    }
    private var ctaForeground: Color {
        signal.isJoined || signal.isMine ? Theme.signalYellow : Theme.ink
    }
    private var ctaBackground: Color {
        signal.isMine || signal.isJoined ? Theme.ink : Theme.signalYellow.opacity(0.4)
    }

    var body: some View {
        HStack(spacing: 11) {
            Button(action: onTap) {
              HStack(spacing: 11) {
                Text(signal.hostInitials)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(signal.hostColor))

                VStack(alignment: .leading, spacing: 2) {
                    Text(signal.title + (signal.seats > 0 ? " · \(signal.seats) seats" : ""))
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("\(signal.isMine ? "You" : signal.hostFirstName) · \(signal.window) · \(signal.distance)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.black.opacity(0.45))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Show signal details")

            Button(action: onJoin) {
                    Text(ctaLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ctaForeground)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9).fill(ctaBackground))
                }
                .buttonStyle(.plain)
                .disabled(signal.isMine || signal.isJoined)
                .accessibilityLabel(signal.isMine ? "Your signal" : signal.isJoined ? "Already joined" : "Join \(signal.hostFirstName)’s signal")
        }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white)
                    .stroke(
                        signal.isMine ? Theme.ink.opacity(0.16) : .black.opacity(0.07),
                        lineWidth: 1
                    )
            )
    }
}

// MARK: - Bat signal icon

/// A bat silhouette — pointed ears, swept wing tops, scalloped wing
/// membranes, and a center tail — drawn in a 100x46 design space.
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

#Preview("Bat shape") {
    BatSignalShape()
        .fill(Theme.ink)
        .frame(width: 260, height: 120)
        .padding(40)
        .background(Theme.signalYellow)
}

// MARK: - Toast

struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.ink))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
    }
}

#Preview {
    MapHomeView()
}

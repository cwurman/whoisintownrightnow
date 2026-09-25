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
    @State private var signals = Signal.mock
    @State private var sheetExpanded = false
    @State private var showComposer = false
    @State private var confirmation: PostedConfirmation?
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
    private var visibleSignals: [Signal] { Array(signals.prefix(sheetExpanded ? 4 : 2)) }
    private var hiddenCount: Int { signals.count - visibleSignals.count }

    /// Matches the prototype: peek is fixed, open grows with visible rows.
    private var sheetHeight: CGFloat {
        sheetExpanded ? 168 + CGFloat(visibleSignals.count) * 76 : 262
    }

    var body: some View {
        ZStack {
            map

            // Top chrome: status pill, notifications, profile
            VStack(alignment: .leading, spacing: 10) {
                topBar
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            // FAB rides just above the sheet and animates with it
            VStack(spacing: 18) {
                Spacer()
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
                    onRowTap: { _ in showToast("Signal detail — next screen") }
                )
                .frame(height: sheetHeight)
            }
            .ignoresSafeArea(edges: .bottom)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: sheetExpanded)

            if let toast {
                ToastView(message: toast)
                    .padding(.bottom, sheetHeight + 60)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: toast)
        .sheet(isPresented: $showComposer) {
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
    }

    // MARK: Map

    private var map: some View {
        Map(position: $cameraPosition) {
            // Neighborhood-granularity blobs — everyone sees the same fuzz
            ForEach(Friend.mock) { friend in
                MapCircle(center: friend.coordinate, radius: 850)
                    .foregroundStyle(Theme.signalYellow.opacity(0.10))
                    .stroke(Theme.signalYellow.opacity(0.22), lineWidth: 1)

                Annotation(friend.name, coordinate: friend.coordinate) {
                    FriendAvatarView(friend: friend)
                        .onTapGesture {
                            showToast("\(friend.firstName)'s card — next screen")
                        }
                }
                .annotationTitles(.hidden)
            }

            // Live signals as pill pins
            ForEach(signals) { signal in
                Annotation(signal.title, coordinate: signal.coordinate, anchor: .bottom) {
                    SignalPinView(signal: signal)
                        .onTapGesture {
                            showToast("Signal detail — next screen")
                        }
                }
                .annotationTitles(.hidden)
            }

            // You: black dot with a pulsing yellow ring
            Annotation("You", coordinate: Friend.youCoordinate) {
                YouDotView()
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .ignoresSafeArea()
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

            // Notifications bell with unread dot
            Button {
                showToast("The sky — next screen")
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(chromeBackground(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(Theme.signalYellow)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .padding(7)
                    }
            }
            .buttonStyle(.plain)

            // Profile
            Button {
                showToast("You screen — next screen")
            } label: {
                Text("JD")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(chromeBackground(cornerRadius: 12))
            }
            .buttonStyle(.plain)
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
        sheetExpanded.toggle()
    }

    private func handlePost(_ draft: ComposerDraft) {
        let signal = Signal(
            id: "me-\(UUID().uuidString)",
            hostName: "You", hostInitials: "JD", hostColor: Theme.ink,
            title: draft.text.trimmingCharacters(in: .whitespaces),
            place: draft.placeText,
            window: draft.whenText,
            distance: "you",
            seats: draft.seats,
            going: ["JD"], isJoined: true, isMine: true,
            coordinate: draft.placeCoordinate
        )
        signals.insert(signal, at: 0)
        showComposer = false

        let confirmationNote = draft.selectedFriends.isEmpty
            ? "nobody — map only"
            : "\(draft.autoCount) nearby" + (draft.extraCount > 0 ? " + \(draft.extraCount) you added" : "")
        let posted = PostedConfirmation(signal: signal, pinged: draft.selectedFriends, note: confirmationNote)

        // Let the composer sheet finish dismissing before presenting the confirmation.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            confirmation = posted
        }
    }

    private func join(_ signal: Signal) {
        guard let index = signals.firstIndex(where: { $0.id == signal.id }) else { return }
        if signals[index].isJoined || signals[index].isMine { return }
        signals[index].isJoined = true
        signals[index].going.append("JD")
        showToast("Opening Messages with \(signal.hostFirstName)…")
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

    private var pillColor: Color { signal.isMine ? Theme.ink : Theme.signalYellow }
    private var labelColor: Color { signal.isMine ? Theme.signalYellow : Theme.ink }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(signal.hostInitials)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(pillColor)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(labelColor))
                Text(signal.pinLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 9)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(pillColor))
            .shadow(color: Theme.signalYellow.opacity(0.4), radius: 8, y: 5)

            Rectangle()
                .fill(pillColor)
                .frame(width: 2, height: 13)

            Circle()
                .fill(pillColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .offset(y: -2)
        }
    }
}

// MARK: - You dot

struct YouDotView: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            // Expanding pulse ring
            Circle()
                .fill(Theme.signalYellow.opacity(0.35))
                .frame(width: 42, height: 42)
                .scaleEffect(pulsing ? 1.9 : 0.6)
                .opacity(pulsing ? 0 : 0.55)

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
        .onAppear {
            withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
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

            HStack(alignment: .firstTextBaseline) {
                Text("Happening")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(expanded ? "expiring within 4 hrs" : "tonight")
                    .font(.system(size: 13))
                    .foregroundStyle(.black.opacity(0.4))
            }
            .padding(.bottom, 12)

            VStack(spacing: 9) {
                ForEach(signals) { signal in
                    SignalRowView(
                        signal: signal,
                        onJoin: { onJoin(signal) },
                        onTap: { onRowTap(signal) }
                    )
                }
                if hiddenCount > 0 {
                    Button(action: onToggle) {
                        Text("+\(hiddenCount) more")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
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

                Button(action: onJoin) {
                    Text(ctaLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ctaForeground)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9).fill(ctaBackground))
                }
                .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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

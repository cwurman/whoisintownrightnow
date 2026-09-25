//
//  ComposerView.swift
//  whoisintownrightnow
//
//  Screen 02: the bat-signal composer, plus its two sub-screens
//  (place picker, recipients picker) and the post confirmation.
//

import SwiftUI
import MapKit

// MARK: - Draft model

enum PlaceMode: Equatable { case pin, region }
enum TimeMode: Equatable { case now, later }

struct PlaceOption: Identifiable {
    let name: String
    let sub: String
    let dist: String
    let coordinate: CLLocationCoordinate2D?
    var id: String { name }
}

struct RadiusOption {
    let label: String
    let meters: CLLocationDistance
}

/// Everything the composer collects before a signal goes up.
@Observable
final class ComposerDraft {
    var text = ""
    var mode: PlaceMode = .pin
    var chosenPlace = "Lucia"
    var placeQuery = ""
    var radiusIdx = 1
    var timeMode: TimeMode = .now
    var dayIdx = 0
    var startMins = 20 * 60   // 8:00pm
    var durHrs = 3
    var seats = 0
    var recipientIDs: Set<String> = ComposerDraft.defaultRecipients

    static let defaultRecipients: Set<String> = ["mk", "rs"]
    static let days = ["Today", "Tomorrow", "Sat", "Sun"]
    static let radii: [RadiusOption] = [
        RadiusOption(label: "0.2 mi", meters: 322),
        RadiusOption(label: "0.5 mi", meters: 805),
        RadiusOption(label: "1 mi", meters: 1609),
        RadiusOption(label: "2 mi", meters: 3219),
    ]
    static let places: [PlaceOption] = [
        PlaceOption(name: "Lucia", sub: "18th St · italian, loud", dist: "0.4 mi",
                    coordinate: CLLocationCoordinate2D(latitude: 37.7648, longitude: -122.4290)),
        PlaceOption(name: "Dolores Park", sub: "the good side of the hill", dist: "0.5 mi",
                    coordinate: CLLocationCoordinate2D(latitude: 37.7596, longitude: -122.4269)),
        PlaceOption(name: "Bar Part Time", sub: "Van Ness · records", dist: "0.9 mi",
                    coordinate: CLLocationCoordinate2D(latitude: 37.7744, longitude: -122.4183)),
        PlaceOption(name: "Drop a pin on the map", sub: "wherever you land", dist: "", coordinate: nil),
    ]

    var canPost: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }
    var radius: RadiusOption { Self.radii[radiusIdx] }
    var startLabel: String { Self.formatMinutes(startMins) }

    var whenText: String {
        timeMode == .now
            ? "next \(durHrs) \(durHrs == 1 ? "hr" : "hrs")"
            : Self.days[dayIdx].lowercased() + ", " + Self.formatMinutes(startMins)
    }

    var placeText: String {
        mode == .pin ? chosenPlace : "Within \(radius.label)"
    }

    var durationLabel: String {
        var label = "\(durHrs) \(durHrs == 1 ? "hr" : "hrs")"
        if timeMode == .later {
            label += " · till " + Self.formatMinutes(startMins + durHrs * 60)
        }
        return label
    }

    var whenSummary: String {
        timeMode == .now
            ? "Live the moment you send it, gone in \(durHrs) \(durHrs == 1 ? "hour." : "hours.")"
            : "Goes up on your map now, marked for \(Self.days[dayIdx].lowercased()) at \(Self.formatMinutes(startMins))."
    }

    var seatsLabel: String { seats > 0 ? String(seats) : "∞" }
    var seatsHint: String { seats > 0 ? "\(seats) can join, then it closes" : "off — anyone can come" }

    var selectedFriends: [Friend] { Friend.mock.filter { recipientIDs.contains($0.id) } }
    var autoCount: Int { selectedFriends.filter { $0.distanceMiles < 2 }.count }
    var extraCount: Int { selectedFriends.count - autoCount }

    var audienceTitle: String {
        selectedFriends.isEmpty
            ? "Nobody yet"
            : "Pinging \(selectedFriends.count) \(selectedFriends.count == 1 ? "friend" : "friends")"
    }
    var audienceSub: String {
        selectedFriends.isEmpty
            ? "it will only show on the map"
            : "\(autoCount) nearby" + (extraCount > 0 ? " + \(extraCount) you added" : "") + " · tap to change"
    }

    /// Where the posted signal's pin lands on the big map.
    var placeCoordinate: CLLocationCoordinate2D {
        if mode == .pin, let c = Self.places.first(where: { $0.name == chosenPlace })?.coordinate {
            return c
        }
        // Dropped pin / region blob: hover just off "you"
        return CLLocationCoordinate2D(
            latitude: Friend.youCoordinate.latitude + 0.006,
            longitude: Friend.youCoordinate.longitude - 0.006
        )
    }

    static func formatMinutes(_ mins: Int) -> String {
        let h24 = (mins / 60) % 24
        let mm = mins % 60
        let h = h24 % 12 == 0 ? 12 : h24 % 12
        return "\(h):" + String(format: "%02d", mm) + (h24 < 12 ? "am" : "pm")
    }
}

// MARK: - Composer

struct ComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ComposerDraft()
    @State private var route: Route = .form
    let onPost: (ComposerDraft) -> Void

    enum Route: Equatable { case form, place, recipients }

    var body: some View {
        ZStack {
            Theme.sheetSurface.ignoresSafeArea()
            switch route {
            case .form:
                formScreen
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .place:
                PlacePickerView(draft: draft) { route = .form }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .recipients:
                RecipientsView(draft: draft) { route = .form }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: route)
    }

    private var formScreen: some View {
        VStack(spacing: 0) {
            // Header: Cancel · Bat signal · Light it
            ZStack {
                Text("Bat signal")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 15))
                        .foregroundStyle(.black.opacity(0.5))
                    Spacer()
                    Button("Light it") {
                        guard draft.canPost else { return }
                        onPost(draft)
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(draft.canPost ? Theme.ink : .black.opacity(0.25))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel("What's the move")

                    TextField("dinner at Lucia, 2 seats", text: $draft.text)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                        .background(cardBackground(cornerRadius: 14))

                    SectionLabel("Where")
                        .padding(.top, 20)

                    Button {
                        route = .place
                    } label: {
                        HStack(spacing: 11) {
                            Circle().fill(Theme.ink).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(draft.mode == .pin ? draft.chosenPlace : "Within \(draft.radius.label) of you")
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                                Text(draft.mode == .pin ? "exact pin · tap to change" : "a circle on the map · tap to resize")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.black.opacity(0.45))
                            }
                            Spacer()
                            Text("›")
                                .font(.system(size: 20))
                                .foregroundStyle(.black.opacity(0.25))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .background(cardBackground(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)

                    SectionLabel("When")
                        .padding(.top, 20)

                    HStack(spacing: 8) {
                        TabButton(label: "Right now", selected: draft.timeMode == .now) { draft.timeMode = .now }
                        TabButton(label: "Pick a time", selected: draft.timeMode == .later) { draft.timeMode = .later }
                    }
                    .padding(.bottom, 9)

                    timeCard

                    Text(draft.whenSummary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.black.opacity(0.5))
                        .padding(.top, 9)
                        .padding(.horizontal, 2)

                    // Seats
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cap the group")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            Text(draft.seatsHint)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.black.opacity(0.45))
                        }
                        Spacer()
                        StepperControl(
                            value: draft.seatsLabel,
                            onDecrement: { draft.seats = max(0, draft.seats - 1) },
                            onIncrement: { draft.seats = min(12, draft.seats + 1) }
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                    .background(cardBackground(cornerRadius: 14))
                    .padding(.top, 22)

                    SectionLabel("Who gets pinged")
                        .padding(.top, 20)

                    Button {
                        route = .recipients
                    } label: {
                        HStack(spacing: 0) {
                            AvatarStack(friends: Array(draft.selectedFriends.prefix(4)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(draft.audienceTitle)
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                                Text(draft.audienceSub)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.black.opacity(0.45))
                            }
                            .padding(.leading, draft.selectedFriends.isEmpty ? 0 : 18)
                            Spacer()
                            Text("›")
                                .font(.system(size: 20))
                                .foregroundStyle(.black.opacity(0.25))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(cardBackground(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
        }
    }

    private var timeCard: some View {
        VStack(spacing: 0) {
            if draft.timeMode == .later {
                HStack(spacing: 7) {
                    ForEach(Array(ComposerDraft.days.enumerated()), id: \.offset) { index, label in
                        Button {
                            draft.dayIdx = index
                        } label: {
                            Text(label)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(index == draft.dayIdx ? Theme.signalYellow : .black.opacity(0.55))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(index == draft.dayIdx ? Theme.ink : .black.opacity(0.05))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 13)
                .padding(.bottom, 11)

                Divider().opacity(0.6)

                HStack {
                    Text("Kicks off")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    StepperControl(
                        value: draft.startLabel,
                        valueWidth: 66,
                        onDecrement: { draft.startMins = max(360, draft.startMins - 30) },
                        onIncrement: { draft.startMins = min(1410, draft.startMins + 30) }
                    )
                }
                .padding(.vertical, 11)

                Divider().opacity(0.6)
            }

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Signal stays up")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(draft.durationLabel)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.5))
                }
                Slider(
                    value: Binding(
                        get: { Double(draft.durHrs) },
                        set: { draft.durHrs = Int($0.rounded()) }
                    ),
                    in: 1...6, step: 1
                )
                .tint(Theme.ink)
                .padding(.top, 4)
                HStack {
                    Text("1 hr")
                    Spacer()
                    Text("6 hrs")
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.black.opacity(0.32))
            }
            .padding(.vertical, 13)
        }
        .padding(.horizontal, 14)
        .background(cardBackground(cornerRadius: 14))
    }
}

// MARK: - Place picker

struct PlacePickerView: View {
    @Bindable var draft: ComposerDraft
    let onDone: () -> Void

    private var filteredPlaces: [PlaceOption] {
        let query = draft.placeQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return ComposerDraft.places }
        return ComposerDraft.places.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Where is it")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                HStack {
                    Button("‹ Back") { onDone() }
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.ink)
                        .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            miniMap
                .frame(height: 184)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.black.opacity(0.1), lineWidth: 1))
                .overlay(alignment: .bottomLeading) {
                    Text(draft.mode == .pin ? "EXACT PIN · EVERYONE SEES THE DOOR" : "FRIENDS SEE THE CIRCLE, NOT YOU INSIDE IT")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.6))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.9)))
                        .padding(10)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 12)

            HStack(spacing: 8) {
                TabButton(label: "Exact spot", selected: draft.mode == .pin) { draft.mode = .pin }
                TabButton(label: "A circle", selected: draft.mode == .region) { draft.mode = .region }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 12) {
                    if draft.mode == .pin {
                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.35))
                            TextField("Search a bar, park, address…", text: $draft.placeQuery)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.ink)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .background(cardBackground(cornerRadius: 12))

                        VStack(spacing: 0) {
                            ForEach(filteredPlaces) { place in
                                Button {
                                    draft.chosenPlace = place.coordinate == nil ? "Dropped pin" : place.name
                                    onDone()
                                } label: {
                                    HStack(spacing: 12) {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Theme.signalYellow.opacity(0.12))
                                            .frame(width: 32, height: 32)
                                            .overlay(Circle().fill(Theme.ink).frame(width: 8, height: 8))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(place.name)
                                                .font(.system(size: 14.5, weight: .semibold))
                                                .foregroundStyle(Theme.ink)
                                            Text(place.sub)
                                                .font(.system(size: 12.5))
                                                .foregroundStyle(.black.opacity(0.45))
                                        }
                                        Spacer()
                                        Text(place.dist)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(.black.opacity(0.35))
                                    }
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(.plain)
                                if place.id != filteredPlaces.last?.id {
                                    Divider().opacity(0.5).padding(.leading, 59)
                                }
                            }
                        }
                        .background(cardBackground(cornerRadius: 16))
                    } else {
                        VStack(spacing: 0) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("How big a circle")
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Text(draft.radius.label)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Theme.ink)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(draft.radiusIdx) },
                                    set: { draft.radiusIdx = Int($0.rounded()) }
                                ),
                                in: 0...3, step: 1
                            )
                            .tint(Theme.ink)
                            .padding(.top, 6)
                            HStack {
                                Text("a block")
                                Spacer()
                                Text("the whole neighborhood")
                            }
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.black.opacity(0.32))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 15)
                        .background(cardBackground(cornerRadius: 16))

                        HStack(spacing: 12) {
                            Circle()
                                .fill(Theme.signalYellow.opacity(0.3))
                                .frame(width: 32, height: 32)
                                .overlay(Circle().stroke(Theme.signalYellow, lineWidth: 1.5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Centred on you · the Mission")
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                                Text("Anyone in the circle knows roughly where to look. Nobody gets your table.")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.black.opacity(0.45))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                        .background(cardBackground(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 18)
            }

            Button {
                onDone()
            } label: {
                Text(draft.mode == .pin ? "Use \(draft.chosenPlace)" : "Use this circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.signalYellow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Theme.ink))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
    }

    private var miniMap: some View {
        let center = draft.mode == .pin
            ? (ComposerDraft.places.first(where: { $0.name == draft.chosenPlace })?.coordinate ?? Friend.youCoordinate)
            : Friend.youCoordinate
        let latDelta = draft.mode == .region
            ? max(0.012, draft.radius.meters * 3.2 / 111_000)
            : 0.014
        return Map(
            initialPosition: .region(
                MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: latDelta)
                )
            ),
            interactionModes: []
        ) {
            if draft.mode == .region {
                MapCircle(center: Friend.youCoordinate, radius: draft.radius.meters)
                    .foregroundStyle(Theme.signalYellow.opacity(0.3))
                    .stroke(Theme.signalYellow, lineWidth: 2)
                Annotation("", coordinate: Friend.youCoordinate) {
                    Circle()
                        .fill(Theme.ink)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Theme.signalYellow, lineWidth: 2.5))
                }
                .annotationTitles(.hidden)
            } else {
                Annotation("", coordinate: center, anchor: .bottom) {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.signalYellow).frame(width: 7, height: 7)
                            Text(draft.chosenPlace)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.signalYellow)
                                .fixedSize()
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.ink))
                        Rectangle().fill(Theme.ink).frame(width: 2, height: 13)
                        Circle()
                            .fill(Theme.signalYellow)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Theme.ink, lineWidth: 2))
                            .offset(y: -2)
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .id("\(draft.mode == .pin ? "pin-\(draft.chosenPlace)" : "region-\(draft.radiusIdx)")")
    }
}

// MARK: - Recipients picker

struct RecipientsView: View {
    @Bindable var draft: ComposerDraft
    let onDone: () -> Void

    private var nearbyFriends: [Friend] { Friend.mock.filter { $0.distanceMiles < 2 } }
    private var farFriends: [Friend] { Friend.mock.filter { $0.distanceMiles >= 2 } }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Who gets pinged")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.ink)
                HStack {
                    Button("‹ Back") { onDone() }
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Reset") { draft.recipientIDs = ComposerDraft.defaultRecipients }
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Friends within 2 miles get a push automatically. Everyone else can still see the signal on their map — add them here if you want their phone to buzz.")
                        .font(.system(size: 13))
                        .foregroundStyle(.black.opacity(0.6))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardBackground(cornerRadius: 14))
                        .padding(.bottom, 14)

                    SectionLabel("Nearby right now · auto")
                    recipientList(nearbyFriends)
                        .padding(.bottom, 16)

                    SectionLabel("Further out · add anyone")
                    recipientList(farFriends)
                }
                .padding(.horizontal, 18)
            }

            Button {
                onDone()
            } label: {
                Text(draft.selectedFriends.isEmpty ? "Signal nobody" : "Signal these \(draft.selectedFriends.count)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.signalYellow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Theme.ink))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
    }

    private func recipientList(_ friends: [Friend]) -> some View {
        VStack(spacing: 0) {
            ForEach(friends) { friend in
                let isOn = draft.recipientIDs.contains(friend.id)
                Button {
                    if isOn {
                        draft.recipientIDs.remove(friend.id)
                    } else {
                        draft.recipientIDs.insert(friend.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(friend.initials)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(friend.color))
                            .opacity(isOn ? 1 : 0.4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(friend.name)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            Text(friend.hood + " · " + friend.distanceLabel + (friend.isFree ? " · free" : ""))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.black.opacity(0.45))
                        }
                        Spacer()
                        Circle()
                            .fill(isOn ? Theme.ink : .clear)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(isOn ? Theme.ink : .black.opacity(0.2), lineWidth: 1.5))
                            .overlay {
                                if isOn {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                if friend.id != friends.last?.id {
                    Divider().opacity(0.5).padding(.leading, 63)
                }
            }
        }
        .background(cardBackground(cornerRadius: 16))
    }
}

// MARK: - Confirmation

struct PostedConfirmation: Identifiable {
    let id = UUID()
    let signal: Signal
    let pinged: [Friend]
    let note: String
}

struct ConfirmationView: View {
    let confirmation: PostedConfirmation
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Theme.signalYellow)
                .frame(width: 60, height: 60)
                .overlay(
                    BatSignalShape()
                        .fill(Theme.ink)
                        .frame(width: 36, height: 17)
                )
                .background(Circle().fill(Theme.signalYellow.opacity(0.22)).frame(width: 76, height: 76))
                .padding(.top, 26)
                .padding(.bottom, 14)

            Text("Bat signal's up")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.ink)

            Text("\u{201C}\(confirmation.signal.title)\u{201D} · \(confirmation.signal.place) · \(confirmation.signal.window)")
                .font(.system(size: 14))
                .foregroundStyle(.black.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 38)
                .padding(.top, 7)
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 9) {
                Text("PINGED JUST NOW")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.black.opacity(0.35))
                HStack(spacing: 0) {
                    AvatarStack(friends: confirmation.pinged)
                    Text(confirmation.note)
                        .font(.system(size: 13))
                        .foregroundStyle(.black.opacity(0.45))
                        .padding(.leading, confirmation.pinged.isEmpty ? 0 : 18)
                    Spacer()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground(cornerRadius: 14))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            Button(action: onClose) {
                Text("Also text the group")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.signalYellow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Theme.ink))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.bottom, 9)

            Button(action: onClose) {
                Text("Back to the map")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 15).fill(.black.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Shared bits

/// Uppercased mono section label, e.g. "WHAT'S THE MOVE".
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(.black.opacity(0.38))
            .padding(.bottom, 8)
    }
}

/// − value + stepper matching the prototype's pill buttons.
struct StepperControl: View {
    let value: String
    var valueWidth: CGFloat = 18
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            stepButton("−", action: onDecrement)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .frame(minWidth: valueWidth)
            stepButton("+", action: onIncrement)
        }
    }

    private func stepButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

/// Selected/pinned/on-off toggle tab, prototype style.
struct TabButton: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Theme.ink : .black.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(selected ? Theme.signalYellow.opacity(0.1) : .white)
                        .stroke(selected ? Theme.ink : .black.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Overlapping avatar row.
struct AvatarStack: View {
    let friends: [Friend]

    var body: some View {
        HStack(spacing: -8) {
            ForEach(friends) { friend in
                Text(friend.initials)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(friend.color))
                    .overlay(Circle().stroke(.white, lineWidth: 2))
            }
        }
    }
}

/// White card with the standard hairline border.
func cardBackground(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius)
        .fill(.white)
        .stroke(.black.opacity(0.12), lineWidth: 1)
}

#Preview("Composer") {
    ComposerView { _ in }
}

#Preview("Confirmation") {
    ConfirmationView(
        confirmation: PostedConfirmation(
            signal: Signal(
                id: "preview", hostName: "You", hostInitials: "JD", hostColor: Theme.ink,
                title: "dinner at Lucia, 2 seats", place: "Lucia", window: "next 3 hrs",
                distance: "you", seats: 2, going: ["JD"], isJoined: true, isMine: true,
                coordinate: Friend.youCoordinate
            ),
            pinged: Array(Friend.mock.prefix(2)),
            note: "2 nearby"
        ),
        onClose: {}
    )
}

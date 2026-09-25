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
    var scheduledAt = Date().addingTimeInterval(3600)
    var droppedCoordinate: CLLocationCoordinate2D?
    var durHrs = 3
    var seats = 0
    var recipientIDs: Set<String> = ComposerDraft.defaultRecipients

    static let defaultRecipients: Set<String> = ["mk", "rs"]
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
    ]

    var canPost: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (timeMode == .now || scheduledAt > Date())
    }
    var radius: RadiusOption { Self.radii[radiusIdx] }
    var whenText: String {
        timeMode == .now ? "Next \(durHrs) \(durHrs == 1 ? "hour" : "hours")" : scheduledAt.formatted(date: .abbreviated, time: .shortened)
    }
    var placeText: String { mode == .pin ? chosenPlace : "Within \(radius.label)" }
    var seatsLabel: String { seats == 0 ? "No limit" : "\(seats) people" }

    var selectedFriends: [Friend] { Friend.mock.filter { recipientIDs.contains($0.id) } }
    var autoCount: Int { selectedFriends.filter { $0.distanceMiles < 2 }.count }
    var extraCount: Int { selectedFriends.count - autoCount }

    var placeCoordinate: CLLocationCoordinate2D {
        if mode == .region { return Friend.youCoordinate }
        if chosenPlace == "Dropped pin", let droppedCoordinate { return droppedCoordinate }
        return Self.places.first(where: { $0.name == chosenPlace })?.coordinate ?? Friend.youCoordinate
    }
}

// MARK: - Native composer

struct ComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ComposerDraft()
    let onPost: (ComposerDraft) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("What’s the plan?") {
                    TextField("Dinner, a walk, a quick coffee…", text: $draft.text, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.sentences)
                        .accessibilityIdentifier("signal-title")
                }
                Section {
                    NavigationLink {
                        PlacePickerView(draft: draft)
                    } label: {
                        Label {
                            LabeledContent("Location", value: draft.placeText)
                        } icon: { Image(systemName: "mappin.and.ellipse").foregroundStyle(Theme.accent) }
                    }
                    NavigationLink {
                        RecipientsView(draft: draft)
                    } label: {
                        Label {
                            LabeledContent("Invite friends", value: draft.selectedFriends.isEmpty ? "None" : "\(draft.selectedFriends.count) selected")
                        } icon: { Image(systemName: "person.2").foregroundStyle(Theme.accent) }
                    }
                }
                Section {
                    Picker("When", selection: $draft.timeMode) {
                        Text("Now").tag(TimeMode.now)
                        Text("Scheduled").tag(TimeMode.later)
                    }.pickerStyle(.segmented)
                    if draft.timeMode == .later {
                        DatePicker("Starts", selection: $draft.scheduledAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    }
                    Picker("Duration", selection: $draft.durHrs) {
                        ForEach(1...6, id: \.self) { Text("\($0) \($0 == 1 ? "hour" : "hours")").tag($0) }
                    }
                } header: { Text("Time") } footer: {
                    if draft.timeMode == .later && draft.scheduledAt <= Date() { Text("Choose a future start time.").foregroundStyle(.red) }
                }
                Section {
                    Stepper(value: $draft.seats, in: 0...12) {
                        LabeledContent("Group limit", value: draft.seatsLabel)
                    }
                } footer: {
                    Text("This is a preview. Plans stay on this device until you leave the map. Invitations, expiration, and group limits aren’t active yet.")
                }
            }
            .navigationTitle("New signal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { if draft.canPost { onPost(draft) } }
                        .buttonStyle(.glassProminent)
                        .disabled(!draft.canPost)
                        .accessibilityIdentifier("post-signal")
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .tint(Theme.accent)
    }
}

struct PlacePickerView: View {
    @Bindable var draft: ComposerDraft
    @Environment(\.dismiss) private var dismiss
    @State private var showPinPicker = false
    private var places: [PlaceOption] {
        let query = draft.placeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? ComposerDraft.places : ComposerDraft.places.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            Section {
                Map(initialPosition: .region(MKCoordinateRegion(center: draft.placeCoordinate,
                    latitudinalMeters: draft.mode == .region ? draft.radius.meters * 3 : 1800,
                    longitudinalMeters: draft.mode == .region ? draft.radius.meters * 3 : 1800)), interactionModes: []) {
                    if draft.mode == .region {
                        MapCircle(center: draft.placeCoordinate, radius: draft.radius.meters)
                            .foregroundStyle(Theme.accent.opacity(0.15)).stroke(Theme.accent, lineWidth: 2)
                    } else { Marker(draft.chosenPlace, coordinate: draft.placeCoordinate).tint(Theme.accent) }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                .frame(height: 190)
                .id("\(draft.mode)-\(draft.placeCoordinate.latitude)-\(draft.placeCoordinate.longitude)-\(draft.radiusIdx)")
                .listRowInsets(EdgeInsets())
                Picker("Location type", selection: $draft.mode) {
                    Text("Exact spot").tag(PlaceMode.pin)
                    Text("An area").tag(PlaceMode.region)
                }.pickerStyle(.segmented)
            }
            if draft.mode == .pin {
                Section("Suggested places") {
                    ForEach(places) { place in
                        Button {
                            draft.chosenPlace = place.name
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: place.name.contains("Park") ? "tree.fill" : "fork.knife")
                                    .foregroundStyle(Theme.accent).frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(place.name).foregroundStyle(.primary)
                                    Text(place.sub).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if draft.chosenPlace == place.name { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.accent) }
                            }.padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(draft.chosenPlace == place.name ? .isSelected : [])
                    }
                    if places.isEmpty {
                        ContentUnavailableView.search(text: draft.placeQuery)
                    }
                }
                Section {
                    Button { showPinPicker = true } label: {
                        Label(draft.chosenPlace == "Dropped pin" ? "Adjust dropped pin" : "Choose a spot on the map", systemImage: "mappin.circle")
                    }
                } footer: { Text("Suggested places are samples near the Mission. You can place a pin anywhere on the map.") }
            } else {
                Section {
                    Picker("Radius", selection: $draft.radiusIdx) {
                        ForEach(ComposerDraft.radii.indices, id: \.self) { Text(ComposerDraft.radii[$0].label).tag($0) }
                    }.pickerStyle(.inline)
                } footer: { Text("Centered on your sample location in the Mission. This is the plan’s area, separate from your account’s location-sharing preference.") }
            }
        }
        .searchable(text: $draft.placeQuery, prompt: "Search sample places")
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $showPinPicker) { PinPickerView(draft: draft) }
    }
}

private struct PinPickerView: View {
    @Bindable var draft: ComposerDraft
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition
    @State private var coordinate: CLLocationCoordinate2D

    init(draft: ComposerDraft) {
        self.draft = draft
        _coordinate = State(initialValue: draft.placeCoordinate)
        _camera = State(initialValue: .region(MKCoordinateRegion(center: draft.placeCoordinate,
            latitudinalMeters: 1600, longitudinalMeters: 1600)))
    }

    var body: some View {
        NavigationStack {
            Map(position: $camera)
                .mapStyle(.standard(elevation: .flat))
                .onMapCameraChange(frequency: .continuous) { coordinate = $0.region.center }
                .overlay {
                    Image(systemName: "plus").font(.title3.weight(.light)).foregroundStyle(.primary)
                        .padding(6).background(.regularMaterial, in: Circle()).allowsHitTesting(false)
                }
                .safeAreaInset(edge: .bottom) {
                    Label("Move the map to choose the exact spot", systemImage: "hand.draw")
                        .font(.subheadline).padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
                .navigationTitle("Place a pin")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use pin") {
                            draft.droppedCoordinate = coordinate
                            draft.chosenPlace = "Dropped pin"
                            draft.mode = .pin
                            dismiss()
                        }.buttonStyle(.glassProminent)
                    }
                }
        }
        .tint(Theme.accent)
    }
}

struct RecipientsView: View {
    @Bindable var draft: ComposerDraft
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var friends: [Friend] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Friend.mock.filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
    }
    var body: some View {
        List {
            Section {
                ForEach(friends) { friend in
                    Button {
                        if draft.recipientIDs.contains(friend.id) { draft.recipientIDs.remove(friend.id) }
                        else { draft.recipientIDs.insert(friend.id) }
                    } label: {
                        HStack(spacing: 14) {
                            PersonAvatar(initials: friend.initials, color: friend.color)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(friend.name).foregroundStyle(.primary)
                                Text(friend.hood).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: draft.recipientIDs.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title2).foregroundStyle(draft.recipientIDs.contains(friend.id) ? Theme.accent : Color.secondary)
                        }.padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.recipientIDs.contains(friend.id) ? .isSelected : [])
                }
            } header: { Text("\(draft.selectedFriends.count) selected") } footer: { Text("Sample friends. No invitations or notifications are sent in this preview.") }
            if friends.isEmpty { ContentUnavailableView.search(text: query) }
            Section { Button("Reset selection") { draft.recipientIDs = ComposerDraft.defaultRecipients } }
        }
        .searchable(text: $query, prompt: "Find a friend")
        .navigationTitle("Invite friends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

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
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 56))
                        .foregroundStyle(Theme.accent).padding(.top, 16)
                    VStack(spacing: 8) {
                        Text("Added to your map").font(.title2.bold())
                        Text(confirmation.signal.title).font(.headline)
                        Text("\(confirmation.signal.place) · \(confirmation.signal.window)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                    ShareLink(item: "\(confirmation.signal.title)\n\(confirmation.signal.place) · \(confirmation.signal.window)") {
                        Label("Share this plan", systemImage: "square.and.arrow.up")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.glassProminent)
                    Text("\(confirmation.note). No invitations have been sent in this preview.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(.horizontal, 28).padding(.bottom, 24)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) } }
        }.tint(Theme.accent)
    }
}

#Preview { ComposerView { _ in } }

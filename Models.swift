//
//  Models.swift
//  whoisintownrightnow
//
//  Data models + design tokens for the map home screen.
//

import SwiftUI
import MapKit

// MARK: - Design tokens

enum Theme {
    /// Cocoa & Orchid. Text accents deepen on ivory; filled actions keep the pastel orchid.
    static let accent = Color("AccentColor")
    static let label = Color("AppLabel")
    static let secondaryLabel = Color("AppSecondaryLabel")
    static let background = Color("AppBackground")
    static let surface = Color("AppSurface")
    static let orchid = Color(hex: 0xE6B5F4)
    static let cocoa = Color(hex: 0x4A3630)
    static let ink = Color(hex: 0x332521)
    static let panelRow = surface.opacity(0.42)
}

/// Shared native surfaces keep composer, pickers, and account screens in the same palette.
struct ThemedForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content.listRowBackground(Theme.surface) }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
    }
}

struct ThemedList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List { content.listRowBackground(Theme.surface) }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Friend

struct Friend: Identifiable {
    let id: String
    let name: String
    let initials: String
    let color: Color
    let hood: String
    let coordinate: CLLocationCoordinate2D
    let distanceMiles: Double
    let isFree: Bool
    let note: String

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
    var distanceLabel: String { String(format: "%.1f mi", distanceMiles) }

    static let tara = Friend(
        id: "tw", name: "Tara Weiss", initials: "TW", color: Theme.ink,
        hood: "Duboce Triangle",
        coordinate: CLLocationCoordinate2D(latitude: 37.7702, longitude: -122.4313),
        distanceMiles: 0.9, isFree: true, note: "Heading out for dinner."
    )
    static let rae = Friend(
        id: "rs", name: "Rae Solis", initials: "RS", color: Color(hex: 0x79608F),
        hood: "Hayes Valley",
        coordinate: CLLocationCoordinate2D(latitude: 37.7765, longitude: -122.4262),
        distanceMiles: 1.1, isFree: true,
        note: "Out walking with no destination. Posted a hang 20 minutes ago."
    )

    static let mock: [Friend] = [
        tara, rae,
        Friend(id: "mk", name: "Maya Kwan", initials: "MK", color: Color(hex: 0x956558),
               hood: "Mission",
               coordinate: CLLocationCoordinate2D(latitude: 37.7614, longitude: -122.4216),
               distanceMiles: 0.6, isFree: true,
               note: "Free for the next couple hours. Somewhere around 18th & Valencia."),
        Friend(id: "al", name: "Alex Lund", initials: "AL", color: Color(hex: 0x82577F),
               hood: "Nob Hill",
               coordinate: CLLocationCoordinate2D(latitude: 37.7930, longitude: -122.4155),
               distanceMiles: 2.3, isFree: false,
               note: "Home-ish. No hangs tonight."),
        Friend(id: "dv", name: "Devi Rao", initials: "DV", color: Color(hex: 0x6B596F),
               hood: "North Beach",
               coordinate: CLLocationCoordinate2D(latitude: 37.8003, longitude: -122.4098),
               distanceMiles: 3.0, isFree: false,
               note: "Neighborhood only — this is as close as the map gets."),
        Friend(id: "jp", name: "Jonas Pike", initials: "JP", color: Color(hex: 0x87695A),
               hood: "Presidio",
               coordinate: CLLocationCoordinate2D(latitude: 37.7989, longitude: -122.4550),
               distanceMiles: 4.2, isFree: false,
               note: "Way out west. Probably running."),
    ]

    /// Where "you" sit on the map (the Mission, per the prototype).
    static let youCoordinate = CLLocationCoordinate2D(latitude: 37.7599, longitude: -122.4148)
}

// MARK: - Hang activity

enum HangActivity {
    /// A title emoji takes precedence; otherwise use familiar activity words.
    static func emoji(for title: String) -> String {
        if let emoji = title.first(where: { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
        }) {
            return String(emoji)
        }

        let normalized = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = Set(normalized.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return suggestions.first { !words.isDisjoint(with: $0.words) }?.emoji ?? "👋"
    }

    private static let suggestions: [(emoji: String, words: Set<String>)] = [
        ("☕️", ["coffee", "cafe", "caffeine", "espresso", "latte", "tea", "matcha"]),
        ("🍕", ["pizza", "pizzeria"]),
        ("🌮", ["taco", "tacos", "burrito", "burritos"]),
        ("🍣", ["sushi", "omakase"]),
        ("🍜", ["ramen", "noodles", "pho"]),
        ("🍔", ["burger", "burgers"]),
        ("🍦", ["icecream", "gelato", "dessert"]),
        ("🥐", ["breakfast", "brunch", "bakery", "pastries"]),
        ("🍝", ["dinner", "pasta", "italian"]),
        ("🥪", ["lunch", "sandwich", "sandwiches", "food", "eat", "eating"]),
        ("🍺", ["beer", "beers", "brewery", "pub"]),
        ("🍷", ["wine", "winery"]),
        ("🍹", ["drinks", "cocktail", "cocktails", "bar"]),
        ("🥾", ["hike", "hikes", "hiking", "trail", "trails"]),
        ("🚴", ["bike", "bikes", "biking", "bicycle", "cycling"]),
        ("🏃", ["run", "running", "jog", "jogging"]),
        ("🚶", ["walk", "walks", "walking", "stroll", "strolling", "wandering"]),
        ("🎬", ["movie", "movies", "cinema", "film"]),
        ("🎮", ["gaming", "videogames"]),
        ("🎲", ["game", "games", "boardgames", "cards"]),
        ("💃", ["dance", "dancing", "clubbing"]),
        ("🎵", ["music", "concert", "gig", "karaoke", "jazz"]),
        ("🏋️", ["gym", "workout", "lifting"]),
        ("🧘", ["yoga", "meditation", "pilates"]),
        ("🎾", ["tennis", "pickleball"]),
        ("🏀", ["basketball", "hoops"]),
        ("⚽️", ["soccer", "football"]),
        ("🏖️", ["beach", "surf", "surfing"]),
        ("🧺", ["picnic", "park"]),
        ("🛍️", ["shopping", "thrifting", "market"]),
        ("📚", ["study", "studying", "reading", "library", "bookstore"]),
    ]
}

// MARK: - Signal

/// Owns a temporary clip until the last draft, hang, or player releases it.
nonisolated final class HangVideoFile: Sendable {
    let url: URL
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HangInvitationVideos", isDirectory: true)
    }

    init(url: URL) { self.url = url }

    deinit {
        guard url.deletingLastPathComponent().standardizedFileURL == Self.directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

nonisolated struct HangVideo: Identifiable, Sendable {
    let id = UUID()
    let file: HangVideoFile
    let poster: Data
    let duration: Double

    var durationLabel: String { "0:\(String(format: "%02d", Int(duration.rounded(.up))))" }
}

/// A hang with an optional personal video invitation.
struct Signal: Identifiable {
    let id: String
    let hostID: String
    let hostName: String
    let hostInitials: String
    let hostColor: Color
    let title: String
    let place: String
    let window: String
    let distance: String
    let seats: Int
    var going: [String]
    var isJoined: Bool
    let isMine: Bool
    /// The host's shared neighborhood anchor at the time they send the signal.
    let anchorCoordinate: CLLocationCoordinate2D
    let anchorPlace: String
    /// Kept separate from the host anchor; only revealed on the map in focus.
    let destinationCoordinate: CLLocationCoordinate2D
    var video: HangVideo? = nil

    var hostFirstName: String { hostName.split(separator: " ").first.map(String.init) ?? hostName }
    var activityEmoji: String { HangActivity.emoji(for: title) }

    var destinationIsAtAnchor: Bool {
        MKMapPoint(anchorCoordinate).distance(to: MKMapPoint(destinationCoordinate)) < 1
    }

    var pinTitle: String {
        let firstSegment = title.split(whereSeparator: { $0 == "," || $0 == "·" }).first.map(String.init) ?? title
        return firstSegment.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The expanded label shown while this person's signal is in focus.
    var pinLabel: String { "\(pinTitle) · \(window)" }

    static let mock: [Signal] = [
        Signal(id: "s1", hostID: Friend.tara.id, hostName: "Tara Weiss", hostInitials: "TW", hostColor: Theme.ink,
               title: "Dinner at Lucia", place: "Lucia · 18th St", window: "8:00pm",
               distance: "0.4 mi", seats: 2, going: ["TW", "MK"], isJoined: false, isMine: false,
               anchorCoordinate: Friend.tara.coordinate, anchorPlace: Friend.tara.hood,
               destinationCoordinate: CLLocationCoordinate2D(latitude: 37.7635, longitude: -122.4395)),
        Signal(id: "s2", hostID: Friend.rae.id, hostName: "Rae Solis", hostInitials: "RS", hostColor: Friend.rae.color,
               title: "Aimless, walking around", place: "Hayes Valley", window: "next 2 hrs",
               distance: "1.1 mi", seats: 0, going: ["RS"], isJoined: false, isMine: false,
               anchorCoordinate: Friend.rae.coordinate, anchorPlace: Friend.rae.hood,
               destinationCoordinate: CLLocationCoordinate2D(latitude: 37.7790, longitude: -122.4330)),
    ]
}

// MARK: - Signal connection geometry

/// A visual connection between shared locations, not turn-by-turn directions.
struct SignalConnection {
    let signal: Signal

    func coordinates(through progress: Double) -> [CLLocationCoordinate2D] {
        let start = MKMapPoint(signal.anchorCoordinate)
        let end = MKMapPoint(signal.destinationCoordinate)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let control = MKMapPoint(x: (start.x + end.x) / 2 - dy * 0.18,
                                 y: (start.y + end.y) / 2 + dx * 0.18)
        let progress = min(max(progress, 0), 1)
        let steps = max(1, Int(ceil(progress * 60)))
        return (0...steps).map { step in
            let t = progress * Double(step) / Double(steps)
            let u = 1 - t
            return MKMapPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                              y: u * u * start.y + 2 * u * t * control.y + t * t * end.y).coordinate
        }
    }

    var mapRect: MKMapRect {
        let points = coordinates(through: 1).map(MKMapPoint.init)
        let minX = points.map(\.x).min()!
        let maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!
        let maxY = points.map(\.y).max()!
        // A minimum extent also covers signals whose destination is their anchor.
        let minimum = MKMapPointsPerMeterAtLatitude(signal.anchorCoordinate.latitude) * 750
        let width = max(maxX - minX, minimum) * 1.5
        let height = max(maxY - minY, minimum) * 1.5
        return MKMapRect(x: (minX + maxX - width) / 2, y: (minY + maxY - height) / 2,
                         width: width, height: height)
    }
}

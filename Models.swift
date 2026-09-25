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
    /// Signal yellow — the app's single accent (#f2c230)
    static let signalYellow = Color(hex: 0xF2C230)
    /// Ink black (#111)
    static let ink = Color(hex: 0x111111)
    /// Warm paper background (#f4f2ee)
    static let cream = Color(hex: 0xF4F2EE)
    /// Sheet surface (#fcfbf9)
    static let sheetSurface = Color(hex: 0xFCFBF9)
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

    static let mock: [Friend] = [
        Friend(id: "mk", name: "Maya Kwan", initials: "MK", color: Color(hex: 0xC96F4A),
               hood: "Mission",
               coordinate: CLLocationCoordinate2D(latitude: 37.7614, longitude: -122.4216),
               distanceMiles: 0.6, isFree: true,
               note: "Free for the next couple hours. Somewhere around 18th & Valencia."),
        Friend(id: "rs", name: "Rae Solis", initials: "RS", color: Color(hex: 0x4A6C96),
               hood: "Hayes Valley",
               coordinate: CLLocationCoordinate2D(latitude: 37.7765, longitude: -122.4262),
               distanceMiles: 1.1, isFree: true,
               note: "Out walking with no destination. Put out a signal 20 minutes ago."),
        Friend(id: "al", name: "Alex Lund", initials: "AL", color: Color(hex: 0x7B6BA8),
               hood: "Nob Hill",
               coordinate: CLLocationCoordinate2D(latitude: 37.7930, longitude: -122.4155),
               distanceMiles: 2.3, isFree: false,
               note: "Home-ish. No signal out tonight."),
        Friend(id: "dv", name: "Devi Rao", initials: "DV", color: Color(hex: 0x5C8A6A),
               hood: "North Beach",
               coordinate: CLLocationCoordinate2D(latitude: 37.8003, longitude: -122.4098),
               distanceMiles: 3.0, isFree: false,
               note: "Neighborhood only — this is as close as the map gets."),
        Friend(id: "jp", name: "Jonas Pike", initials: "JP", color: Color(hex: 0xA8734A),
               hood: "Presidio",
               coordinate: CLLocationCoordinate2D(latitude: 37.7989, longitude: -122.4550),
               distanceMiles: 4.2, isFree: false,
               note: "Way out west. Probably running."),
    ]

    /// Where "you" sit on the map (the Mission, per the prototype).
    static let youCoordinate = CLLocationCoordinate2D(latitude: 37.7599, longitude: -122.4148)
}

// MARK: - Signal

/// The only object in the app: text + place + time window (+ optional seat cap).
struct Signal: Identifiable {
    let id: String
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
    let coordinate: CLLocationCoordinate2D

    var hostFirstName: String { hostName.split(separator: " ").first.map(String.init) ?? hostName }

    /// Short label shown on the map pin, e.g. "dinner at lucia · 8:00pm".
    var pinLabel: String {
        if isMine { return "you · \(window)" }
        let firstSegment = title.split(whereSeparator: { $0 == "," || $0 == "·" }).first.map(String.init) ?? title
        return firstSegment.trimmingCharacters(in: .whitespaces).lowercased() + " · " + window
    }

    static let mock: [Signal] = [
        Signal(id: "s1", hostName: "Tara Weiss", hostInitials: "TW", hostColor: Theme.ink,
               title: "Dinner at Lucia", place: "Lucia · 18th St", window: "8:00pm",
               distance: "0.4 mi", seats: 2, going: ["TW", "MK"], isJoined: false, isMine: false,
               coordinate: CLLocationCoordinate2D(latitude: 37.7635, longitude: -122.4395)),
        Signal(id: "s2", hostName: "Rae Solis", hostInitials: "RS", hostColor: Color(hex: 0x4A6C96),
               title: "Aimless, walking around", place: "Hayes Valley", window: "next 2 hrs",
               distance: "1.1 mi", seats: 0, going: ["RS"], isJoined: false, isMine: false,
               coordinate: CLLocationCoordinate2D(latitude: 37.7790, longitude: -122.4330)),
    ]
}

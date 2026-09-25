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
    /// System green and semantic surfaces follow iOS appearance and accessibility settings.
    static let accent = Color.green
    static let label = Color.primary
    #if os(iOS)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    #else
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    #endif
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

    static let tara = Friend(
        id: "tw", name: "Tara Weiss", initials: "TW", color: Theme.ink,
        hood: "Duboce Triangle",
        coordinate: CLLocationCoordinate2D(latitude: 37.7702, longitude: -122.4313),
        distanceMiles: 0.9, isFree: true, note: "Heading out for dinner."
    )
    static let rae = Friend(
        id: "rs", name: "Rae Solis", initials: "RS", color: Color(hex: 0x4A6C96),
        hood: "Hayes Valley",
        coordinate: CLLocationCoordinate2D(latitude: 37.7765, longitude: -122.4262),
        distanceMiles: 1.1, isFree: true,
        note: "Out walking with no destination. Put out a signal 20 minutes ago."
    )

    static let mock: [Friend] = [
        tara, rae,
        Friend(id: "mk", name: "Maya Kwan", initials: "MK", color: Color(hex: 0xC96F4A),
               hood: "Mission",
               coordinate: CLLocationCoordinate2D(latitude: 37.7614, longitude: -122.4216),
               distanceMiles: 0.6, isFree: true,
               note: "Free for the next couple hours. Somewhere around 18th & Valencia."),
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

    var hostFirstName: String { hostName.split(separator: " ").first.map(String.init) ?? hostName }

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
        Signal(id: "s2", hostID: Friend.rae.id, hostName: "Rae Solis", hostInitials: "RS", hostColor: Color(hex: 0x4A6C96),
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

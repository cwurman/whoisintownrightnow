import CoreLocation
import MapKit
import Observation

/// Only this subset goes to Jev. The phone's GPS and the venue coordinates stay on device.
nonisolated struct HangVenueCandidate: Codable, Sendable {
    let id: String
    let name: String
    let address: String
    let category: String
    let distanceMeters: Int?
}

nonisolated struct HangVenue: Codable, Identifiable, Sendable {
    let candidate: HangVenueCandidate
    let latitude: Double
    let longitude: Double
    var id: String { candidate.id }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var isValid: Bool { !candidate.name.isEmpty && latitude.isFinite && longitude.isFinite && CLLocationCoordinate2DIsValid(coordinate) }
}

/// One foreground fix per request; never starts background location sharing.
@MainActor
final class HangSearchLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation?, Never>?
    private var timeout: Task<Void, Never>?

    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }

    static func usable(_ location: CLLocation, now: Date = Date()) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate) && location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= 10_000 && abs(location.timestamp.timeIntervalSince(now)) <= 120
    }

    func locate() async -> CLLocation? {
        guard !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard pending == nil else { continuation.resume(returning: nil); return }
                pending = continuation
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    if !Task.isCancelled { self?.finish(nil) }
                }
                switch manager.authorizationStatus {
                case .notDetermined: manager.requestWhenInUseAuthorization()
                case .authorizedAlways, .authorizedWhenInUse: requestFix()
                default: finish(nil)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(nil) } }
    }

    private func requestFix() {
        if let location = manager.location, Self.usable(location) { finish(location) }
        else { manager.requestLocation() }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard pending != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: requestFix()
        case .denied, .restricted: finish(nil)
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last(where: { Self.usable($0) }))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }
    private func finish(_ location: CLLocation?) {
        timeout?.cancel(); timeout = nil
        manager.stopUpdatingLocation()
        let continuation = pending; pending = nil
        continuation?.resume(returning: location)
    }
}

@MainActor
enum HangPlaceSearch {
    static let maximumCandidates = 8

    static func search(_ query: String, near location: CLLocation?) async throws -> [HangVenue] {
        try Task.checkCancellation()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = String(query.prefix(120))
        request.resultTypes = [.pointOfInterest, .address]
        if let location {
            // A preference, not a strict boundary: explicitly spoken cities can override proximity.
            request.region = MKCoordinateRegion(center: location.coordinate,
                latitudinalMeters: max(10_000, location.horizontalAccuracy * 2),
                longitudinalMeters: max(10_000, location.horizontalAccuracy * 2))
            request.regionPriority = .default
        }
        let search = MKLocalSearch(request: request)
        let deadline = Task { try? await Task.sleep(for: .seconds(6)); if !Task.isCancelled { search.cancel() } }
        defer { deadline.cancel() }
        let response = try await withTaskCancellationHandler { try await search.start() }
            onCancel: { search.cancel() }
        try Task.checkCancellation()
        return response.mapItems.prefix(maximumCandidates).compactMap { item in
            guard let name = item.name, !name.isEmpty, !item.isCurrentLocation else { return nil }
            let coordinate = item.location.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            let candidate = HangVenueCandidate(id: item.identifier?.rawValue ?? UUID().uuidString,
                name: String(name.prefix(160)), address: String((item.address?.fullAddress ?? "").prefix(300)),
                category: String((item.pointOfInterestCategory?.rawValue ?? "place").prefix(100)),
                distanceMeters: location.map { Int(($0.distance(from: item.location) / 100).rounded()) * 100 })
            let venue = HangVenue(candidate: candidate, latitude: coordinate.latitude, longitude: coordinate.longitude)
            return venue.isValid ? venue : nil
        }
    }

    /// Round-robin preserves candidates from each spoken query, rather than letting one query fill the list.
    static func merge(_ groups: [[HangVenue]]) -> [HangVenue] {
        var result: [HangVenue] = []
        for rank in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where rank < group.count {
                let venue = group[rank]
                if !result.contains(where: { $0.id == venue.id ||
                    ($0.candidate.name == venue.candidate.name && abs($0.latitude - venue.latitude) < 0.0001 && abs($0.longitude - venue.longitude) < 0.0001) }) {
                    result.append(venue)
                }
                if result.count == maximumCandidates { return result }
            }
        }
        return result
    }

    static func candidates(for transcript: String, near location: CLLocation) async -> [HangVenue] {
        let queries = HangPlaceCandidates.searchQueries(from: transcript)
        guard !queries.isEmpty else { return [] }
        // Three independent bounded searches overlap instead of adding their latency together.
        async let first = try? search(queries.first ?? "", near: location)
        async let second: [HangVenue]? = queries.count > 1 ? try? search(queries[1], near: location) : nil
        async let third: [HangVenue]? = queries.count > 2 ? try? search(queries[2], near: location) : nil
        let groups = await [first, second, third].compactMap { $0 }
        return Task.isCancelled ? [] : merge(groups)
    }
}

@MainActor @Observable
final class HangPlacePickerSearch {
    private(set) var results: [HangVenue] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var generation = UUID()

    func run(_ query: String, near location: CLLocation?,
             search: @escaping @MainActor (String, CLLocation?) async throws -> [HangVenue] = HangPlaceSearch.search) async {
        let token = UUID(); generation = token
        results = []; errorMessage = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { isSearching = false; return }
        isSearching = true
        defer { if generation == token { isSearching = false } }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let venues = try await search(text, location)
            try Task.checkCancellation()
            guard generation == token else { return }
            results = venues
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            errorMessage = "Places couldn’t load. Try searching again, or choose a spot on the map."
        }
    }
}

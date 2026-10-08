import MapKit
import SwiftUI
import XCTest
@testable import whoisintownrightnow

@MainActor
final class MapLifetimeTests: XCTestCase {
    func testRepeatedFocusReusesMarkersAndReleasesTheMap() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        defer { window.isHidden = true; window.rootViewController = nil }
        weak var releasedMap: MKMapView?
        weak var releasedHost: UIViewController?

        do {
            let model = MapLifetimeScenario()
            let host = UIHostingController(rootView: MapLifetimeHarness(model: model))
            window.rootViewController = host
            window.isHidden = false
            try await Task.sleep(for: .milliseconds(200))
            let map = try XCTUnwrap(findMap(in: host.view))
            releasedMap = map
            releasedHost = host
            let initialMarkers = Set(map.annotations.map { ObjectIdentifier($0) })
            XCTAssertEqual(initialMarkers.count, Friend.mock.count + 1)

            for index in 0..<80 {
                let signal = Signal.mock[index % Signal.mock.count]
                model.selection = signal
                model.camera.focus(on: SignalConnection(signal: signal).mapRect, panel: .details, animated: false)
                try await Task.sleep(for: .milliseconds(25))
                XCTAssertEqual(map.annotations.count, initialMarkers.count + 1, "Each selection should add exactly one destination")
                XCTAssertEqual(map.overlays.count, 2, "Only the current connection's two lines should remain")
                XCTAssertTrue(initialMarkers.isSubset(of: Set(map.annotations.map { ObjectIdentifier($0) })),
                              "The same avatar annotations should survive selection changes")

                model.selection = nil
                model.camera.showOverview(panel: .overview, animated: false)
                try await Task.sleep(for: .milliseconds(25))
                XCTAssertEqual(Set(map.annotations.map { ObjectIdentifier($0) }), initialMarkers)
                XCTAssertTrue(map.overlays.isEmpty)
            }
            window.rootViewController = nil
            window.isHidden = true
        }

        // MapKit releases rendering work asynchronously after removing its view.
        for _ in 0..<30 where releasedMap != nil || releasedHost != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(releasedHost, "The hosting controller must not form a retain cycle")
        XCTAssertNil(releasedMap, "Closing the map must release its renderer and annotation hosts")
    }

    private func findMap(in view: UIView) -> MKMapView? {
        if let map = view as? MKMapView { return map }
        return view.subviews.lazy.compactMap { self.findMap(in: $0) }.first
    }
}

@MainActor @Observable
private final class MapLifetimeScenario {
    let camera = HangMapCameraController()
    var selection: Signal?
}

private struct MapLifetimeHarness: View {
    let model: MapLifetimeScenario

    var body: some View {
        HangMapView(camera: model.camera,
                    overviewRect: Friend.mock.reduce(MKMapRect.null) {
                        $0.union(MKMapRect(origin: MKMapPoint($1.coordinate), size: MKMapSize(width: 1, height: 1)))
                    },
                    signals: Signal.mock, selectedSignal: model.selection, selectedFriend: nil,
                    ownHostID: "you", panelHeight: 334, reduceMotion: false,
                    onSelectSignal: { _ in }, onSelectFriend: { _ in }, onCameraSettled: {})
            .ignoresSafeArea()
    }
}

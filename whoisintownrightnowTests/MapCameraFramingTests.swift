import MapKit
import XCTest
@testable import whoisintownrightnow

@MainActor
final class MapCameraFramingTests: XCTestCase {
    private var overview: MKMapRect {
        let points = (Friend.mock.map(\.coordinate) + [Friend.youCoordinate]).map(MKMapPoint.init)
        let rect = points.reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1))) }
        return rect.insetBy(dx: -rect.width * 0.12, dy: -rect.height * 0.12)
    }

    func testContentFitsAboveTheSheetAtEveryRotation() throws {
        let viewport = CGRect(x: 58, y: 170, width: 286, height: 224)
        let projectionCenter = CGPoint(x: 201, y: 437)
        for heading in [0.0, 35, 90, 180, 270, 345] {
            let fit = try XCTUnwrap(MapCameraFraming.fit(overview, in: viewport, projectionCenter: projectionCenter, heading: heading))
            let center = MKMapPoint(fit.center)
            let angle = heading * .pi / 180
            for x in [overview.minX, overview.maxX] {
                for y in [overview.minY, overview.maxY] {
                    let dx = x - center.x, dy = y - center.y
                    let point = CGPoint(x: projectionCenter.x + (cos(angle) * dx + sin(angle) * dy) / fit.mapPointsPerPoint,
                                        y: projectionCenter.y + (-sin(angle) * dx + cos(angle) * dy) / fit.mapPointsPerPoint)
                    XCTAssertTrue(viewport.insetBy(dx: -0.001, dy: -0.001).contains(point), "Corner outside viewport at heading \(heading): \(point)")
                }
            }
        }
    }

    func testInvalidGeometryDoesNotProduceACamera() {
        XCTAssertNil(MapCameraFraming.fit(.null, in: CGRect(x: 0, y: 0, width: 400, height: 800), projectionCenter: .zero, heading: 0))
        XCTAssertNil(MapCameraFraming.fit(overview, in: .zero, projectionCenter: .zero, heading: 0))
        XCTAssertNil(MapCameraFraming.fit(overview, in: CGRect(x: 0, y: 0, width: 400, height: 800), projectionCenter: .zero, heading: .nan))
    }

    func testFocusStartsImmediatelyWithOneNativeCameraRequest() {
        let (map, controller) = makeMap()
        controller.focus(on: SignalConnection(signal: Signal.mock[0]).mapRect, panel: .details, animated: true)
        XCTAssertEqual(map.requests.count, 1, "A tap must not queue a second camera move after sheet layout")
        XCTAssertTrue(map.requests[0])
    }

    func testOverviewFitsEveryoneAfterFocusAndAnUnrelatedPan() {
        let (map, controller) = makeMap()
        controller.focus(on: SignalConnection(signal: Signal.mock[0]).mapRect, panel: .details, animated: false)
        map.setCenter(CLLocationCoordinate2D(latitude: 37.9, longitude: -122.6), animated: false)
        controller.showOverview(panel: .overview, animated: false)
        let visible = CGRect(x: 35, y: 95, width: 332, height: 415)
        for coordinate in Friend.mock.map(\.coordinate) + [Friend.youCoordinate] {
            XCTAssertTrue(visible.contains(map.convert(coordinate, toPointTo: map)), "Every avatar should return above the panel")
        }
    }

    func testAttributionMarginsDoNotMoveCameraOrResizeMap() {
        let (map, controller) = makeMap()
        controller.showOverview(panel: .overview, animated: false)
        let before = map.camera.copy() as! MKMapCamera
        let bounds = map.bounds
        let projected = map.convert(Friend.youCoordinate, toPointTo: map)
        for bottom in [90.0, 334, 437, 650, 334] {
            map.layoutMargins = UIEdgeInsets(top: 110, left: 20, bottom: bottom, right: 20)
            map.layoutIfNeeded()
            XCTAssertEqual(map.bounds, bounds)
            XCTAssertEqual(map.convert(Friend.youCoordinate, toPointTo: map).y, projected.y, accuracy: 0.1)
            XCTAssertEqual(map.camera.centerCoordinate.latitude, before.centerCoordinate.latitude, accuracy: 0.000001)
            XCTAssertEqual(map.camera.centerCoordinate.longitude, before.centerCoordinate.longitude, accuracy: 0.000001)
            XCTAssertEqual(map.camera.centerCoordinateDistance, before.centerCoordinateDistance, accuracy: 0.1)
        }
    }

    func testReducedMotionAndImmediateRetargetDoNotScheduleDelayedMoves() {
        let (map, controller) = makeMap()
        controller.focus(on: SignalConnection(signal: Signal.mock[0]).mapRect, panel: .details, animated: false)
        controller.showOverview(panel: .collapsed, animated: false)
        controller.focus(on: SignalConnection(signal: Signal.mock[1]).mapRect, panel: .details, animated: false)
        XCTAssertEqual(map.requests, [false, false, false])
    }

    func testSheetGeometryWaitsUntilTheCameraSettles() {
        let (map, controller) = makeMap()
        controller.updateAttribution(panelHeight: 334)
        let margins = map.layoutMargins
        controller.focus(on: SignalConnection(signal: Signal.mock[0]).mapRect, panel: .details, animated: true)
        controller.updateAttribution(panelHeight: 390)
        controller.updateAttribution(panelHeight: 437)
        XCTAssertEqual(map.layoutMargins, margins, "Updating margins during a MapKit animation cancels the interpolation")
        controller.cameraDidSettle()
        XCTAssertEqual(map.layoutMargins.bottom, 469)
        XCTAssertEqual(map.requests, [true], "Moving attribution must not issue another camera request")
    }

    func testAlreadyFramedOverviewDoesNotWaitForAnAnimationThatNeverStarts() {
        let (map, controller) = makeMap()
        XCTAssertTrue(controller.showOverview(panel: .overview, animated: false))
        map.requests = []
        XCTAssertFalse(controller.showOverview(panel: .overview, animated: true))
        XCTAssertTrue(map.requests.isEmpty)
        controller.updateAttribution(panelHeight: 120)
        XCTAssertEqual(map.layoutMargins.bottom, 152, "A no-op must not freeze attribution updates")
    }

    func testVisibleMapAnimatesWithoutResizingAndFitsTheSelectedHang() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIViewController()
        window.rootViewController = host
        let map = MKMapView(frame: window.bounds)
        host.view.addSubview(map)
        window.isHidden = false
        defer { map.delegate = nil; window.isHidden = true }
        let controller = HangMapCameraController()
        controller.attach(map, overview: overview)
        controller.updateAttribution(panelHeight: 334)
        map.setVisibleMapRect(overview, animated: false)
        try await Task.sleep(for: .milliseconds(150))
        controller.showOverview(panel: .overview, animated: false)
        try await Task.sleep(for: .milliseconds(150))

        let probe = CameraMotionProbe()
        probe.onSettle = { controller.cameraDidSettle() }
        map.delegate = probe
        let originalBounds = map.bounds
        controller.focus(on: SignalConnection(signal: Signal.mock[0]).mapRect, panel: .details, animated: true)
        controller.updateAttribution(panelHeight: 437)
        try await Task.sleep(for: .seconds(1))
        controller.cameraDidSettle()
        XCTAssertGreaterThan(probe.centers.count, 4, "Focus should interpolate through multiple camera frames")
        XCTAssertTrue(probe.bounds.allSatisfy { $0 == originalBounds }, "The rendered map must never resize during zoom")
        let visible = CGRect(x: 25, y: 135, width: 352, height: 260)
        for coordinate in [Signal.mock[0].anchorCoordinate, Signal.mock[0].destinationCoordinate] {
            XCTAssertTrue(visible.contains(map.convert(coordinate, toPointTo: map)), "The host and destination must fit above the detail sheet")
        }

        // Exercise the real MapKit animator being interrupted by subsequent taps.
        controller.showOverview(panel: .overview, animated: true)
        try await Task.sleep(for: .milliseconds(80))
        controller.focus(on: SignalConnection(signal: Signal.mock[1]).mapRect, panel: .details, animated: true)
        try await Task.sleep(for: .milliseconds(80))
        controller.showOverview(panel: .overview, animated: true)
        controller.updateAttribution(panelHeight: 334)
        try await Task.sleep(for: .seconds(1))
        controller.cameraDidSettle()
        let overviewViewport = CGRect(x: 30, y: 130, width: 342, height: 395)
        for coordinate in Friend.mock.map(\.coordinate) + [Friend.youCoordinate] {
            XCTAssertTrue(overviewViewport.contains(map.convert(coordinate, toPointTo: map)), "The latest request wins even when previous animations are interrupted")
        }
        XCTAssertTrue(probe.bounds.allSatisfy { $0 == originalBounds })

        let friend = Friend.mock.first { $0.id == "jp" }!
        let point = MKMapPoint(friend.coordinate)
        let side = MKMapPointsPerMeterAtLatitude(friend.coordinate.latitude) * 2000
        controller.focus(on: MKMapRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
                         panel: .details, animated: true)
        controller.updateAttribution(panelHeight: 437)
        try await Task.sleep(for: .seconds(1))
        let expectedY = (map.safeAreaInsets.top + 110 + map.bounds.height * 0.5 - 70) / 2
        XCTAssertEqual(map.convert(friend.coordinate, toPointTo: map).y, expectedY, accuracy: 3,
                       "A friend should land in the center of the usable map area")
    }

    private func makeMap() -> (CameraSpyMap, HangMapCameraController) {
        let map = CameraSpyMap(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        map.isPitchEnabled = false
        map.setVisibleMapRect(overview, animated: false)
        map.layoutIfNeeded()
        map.requests = []
        let controller = HangMapCameraController()
        controller.attach(map, overview: overview)
        return (map, controller)
    }
}

@MainActor
private final class CameraMotionProbe: NSObject, MKMapViewDelegate {
    var centers: [CLLocationCoordinate2D] = []
    var bounds: [CGRect] = []
    var onSettle: (() -> Void)?

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        onSettle?()
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        centers.append(mapView.camera.centerCoordinate)
        bounds.append(mapView.bounds)
    }
}

@MainActor
private final class CameraSpyMap: MKMapView {
    var requests: [Bool] = []

    override func setCamera(_ camera: MKMapCamera, animated: Bool) {
        requests.append(animated)
        // Settle synchronously so tests can inspect geometry without relying on timing.
        super.setCamera(camera, animated: false)
    }
}

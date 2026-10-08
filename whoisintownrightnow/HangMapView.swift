import MapKit
import SwiftUI

enum MapPanelExtent {
    case collapsed, overview, details, expanded

    func height(in map: MKMapView) -> CGFloat {
        switch self {
        case .collapsed: 90 + map.safeAreaInsets.bottom
        case .overview: 300 + map.safeAreaInsets.bottom
        case .details: map.bounds.height * 0.5
        // Keep a useful camera beneath a full-screen sheet for when it is lowered.
        case .expanded: map.bounds.height * 0.5
        }
    }
}

/// Camera changes are imperative MapKit operations. SwiftUI never drives the map's
/// frame, and camera frames never invalidate the surrounding SwiftUI screen.
@MainActor
final class HangMapCameraController {
    private weak var map: MKMapView?
    private var overviewRect = MKMapRect.null
    private var isMoving = false
    private var isIssuingCamera = false
    private var pendingPanelHeight: CGFloat?
    private var attributionInsets: UIEdgeInsets?

    func updateAttribution(panelHeight: CGFloat) {
        pendingPanelHeight = panelHeight
        // MapKit restarts its camera projection when margins change mid-flight.
        // Keep them fixed until its completion callback; never debounce the tap.
        guard !isMoving, let map else { return }
        let bottom = min(panelHeight + 32, map.bounds.height * 0.78) - map.safeAreaInsets.bottom
        let margins = UIEdgeInsets(top: 110, left: 20, bottom: max(0, bottom), right: 20)
        if attributionInsets != margins {
            attributionInsets = margins
            map.layoutMargins = margins
        }
    }

    @discardableResult
    func cameraDidSettle() -> Bool {
        // Retargeting can synchronously end the previous animation. That is not
        // completion of the new request and must not unlock its layout margins.
        guard !isIssuingCamera else { return false }
        isMoving = false
        if let pendingPanelHeight { updateAttribution(panelHeight: pendingPanelHeight) }
        return true
    }

    func attach(_ map: MKMapView, overview: MKMapRect) {
        self.map = map
        overviewRect = overview
    }

    @discardableResult
    func showOverview(panel: MapPanelExtent, animated: Bool) -> Bool {
        move(to: overviewRect, panel: panel, animated: animated)
    }

    @discardableResult
    func focus(on rect: MKMapRect, panel: MapPanelExtent, animated: Bool) -> Bool {
        move(to: rect, panel: panel, animated: animated)
    }

    private func move(to rect: MKMapRect, panel: MapPanelExtent, animated: Bool) -> Bool {
        guard let map, map.bounds.width > 0, map.bounds.height > 0 else { return false }
        let camera = map.camera
        // Calibrate from the actual MapKit projection instead of assuming a field
        // of view. This also preserves a user's map rotation during focus.
        let anchor = map.convert(camera.centerCoordinate, toPointTo: map)
        let sample = CGPoint(x: anchor.x + 100, y: anchor.y)
        let a = MKMapPoint(map.convert(anchor, toCoordinateFrom: map))
        let b = MKMapPoint(map.convert(sample, toCoordinateFrom: map))
        let currentScale = hypot(b.x - a.x, b.y - a.y) / 100
        let top = map.safeAreaInsets.top + 110
        let bottom = min(panel.height(in: map) + 70, map.bounds.height - top - 100)
        let viewport = map.bounds.inset(by: UIEdgeInsets(top: top, left: 58, bottom: bottom, right: 58))
        // MapKit's coordinate conversion keeps the previous projection center
        // after a margin change until the next camera request. The new camera
        // uses the current effective margins, so fit against that destination.
        let projectionBounds = map.bounds.inset(by: map.layoutMargins)
        let targetAnchor = CGPoint(x: projectionBounds.midX, y: projectionBounds.midY)
        guard currentScale > 0,
              let fit = MapCameraFraming.fit(rect, in: viewport, projectionCenter: targetAnchor, heading: camera.heading) else { return false }
        let latitudeScale = MKMetersPerMapPointAtLatitude(fit.center.latitude)
            / MKMetersPerMapPointAtLatitude(camera.centerCoordinate.latitude)
        let distance = camera.centerCoordinateDistance * fit.mapPointsPerPoint / currentScale * latitudeScale
        guard distance.isFinite, distance > 0 else { return false }
        if !isMoving,
           MKMapPoint(fit.center).distance(to: MKMapPoint(camera.centerCoordinate)) < 0.1,
           abs(distance - camera.centerCoordinateDistance) < 0.1 {
            return false
        }
        let target = MKMapCamera(lookingAtCenter: fit.center, fromDistance: distance,
                                 pitch: 0, heading: camera.heading)
        // One native transition starts on the tap. MapKit owns interpolation and
        // lets a new camera request or a map gesture interrupt it naturally.
        isMoving = animated
        isIssuingCamera = true
        map.setCamera(target, animated: animated)
        isIssuingCamera = false
        return true
    }
}

struct HangMapView: UIViewRepresentable {
    let camera: HangMapCameraController
    let overviewRect: MKMapRect
    let signals: [Signal]
    let selectedSignal: Signal?
    let selectedFriend: Friend?
    let ownHostID: String
    let panelHeight: CGFloat
    let reduceMotion: Bool
    let onSelectSignal: (Signal) -> Void
    let onSelectFriend: (Friend) -> Void
    let onCameraSettled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FixedCanvasMapView {
        let map = FixedCanvasMapView()
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
        configuration.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = configuration
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = true
        map.delegate = context.coordinator
        camera.attach(map, overview: overviewRect)
        map.onFirstLayout = { [weak map, camera] in
            guard let map else { return }
            camera.updateAttribution(panelHeight: panelHeight)
            // Establish a projection once before the first visible frame.
            map.setVisibleMapRect(overviewRect, animated: false)
            camera.showOverview(panel: .overview, animated: false)
        }
        context.coordinator.update(self, map: map)
        return map
    }

    func updateUIView(_ map: FixedCanvasMapView, context: Context) {
        context.coordinator.update(self, map: map)
    }

    static func dismantleUIView(_ map: FixedCanvasMapView, coordinator: Coordinator) {
        map.delegate = nil
        map.onFirstLayout = nil
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var parent: HangMapView
        private var annotations: [String: HangMapAnnotation] = [:]
        private var overlaySelection: String?

        init(_ parent: HangMapView) { self.parent = parent }

        func update(_ parent: HangMapView, map: FixedCanvasMapView) {
            self.parent = parent
            parent.camera.updateAttribution(panelHeight: parent.panelHeight)
            var desired: [String: HangMapAnnotation.Content] = [:]
            for friend in Friend.mock where !parent.signals.contains(where: { $0.hostID == friend.id }) {
                desired["person-\(friend.id)"] = .friend(friend)
            }
            for signal in parent.signals { desired["person-\(signal.hostID)"] = .hang(signal) }
            if !parent.signals.contains(where: { $0.hostID == parent.ownHostID }) { desired["you"] = .you }
            if let signal = parent.selectedSignal, !signal.destinationIsAtAnchor {
                desired["destination-\(signal.id)"] = .destination(signal)
            }
            for id in Set(annotations.keys).subtracting(desired.keys) {
                if let annotation = annotations.removeValue(forKey: id) { map.removeAnnotation(annotation) }
            }
            for (id, content) in desired {
                if let annotation = annotations[id] {
                    annotation.content = content
                    if let view = map.view(for: annotation) as? HangMapAnnotationView { configure(view, annotation: annotation) }
                } else {
                    let annotation = HangMapAnnotation(id: id, content: content)
                    annotations[id] = annotation
                    map.addAnnotation(annotation)
                }
            }

            let selection = parent.selectedSignal.map { "hang-\($0.id)" }
                ?? parent.selectedFriend.map { "friend-\($0.id)" }
            if selection != overlaySelection {
                overlaySelection = selection
                map.removeOverlays(map.overlays)
                if let signal = parent.selectedSignal, !signal.destinationIsAtAnchor {
                    let coordinates = SignalConnection(signal: signal).coordinates(through: 1)
                    let outline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                    outline.title = "outline"
                    let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
                    map.addOverlays([outline, line], level: .aboveRoads)
                } else if let friend = parent.selectedFriend {
                    map.addOverlay(MKCircle(center: friend.coordinate, radius: 805), level: .aboveRoads)
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if parent.camera.cameraDidSettle() { parent.onCameraSettled() }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? HangMapAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "person") as? HangMapAnnotationView)
                ?? HangMapAnnotationView(annotation: annotation, reuseIdentifier: "person")
            view.annotation = annotation
            configure(view, annotation: annotation)
            return view
        }

        private func configure(_ view: HangMapAnnotationView, annotation: HangMapAnnotation) {
            let selectedID = parent.selectedSignal.map { "person-\($0.hostID)" }
                ?? parent.selectedFriend.map { "person-\($0.id)" }
            let isSelected = annotation.id == selectedID
            let isDestination = annotation.id.hasPrefix("destination-")
            let dimmed = selectedID != nil && !isSelected && !isDestination
            view.update(content: annotation.content, dimmed: dimmed,
                        animateHalo: selectedID == nil && !parent.reduceMotion)
            view.layer.zPosition = isSelected ? 10 : isDestination ? 5 : 0
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? HangMapAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            switch annotation.content {
            case .friend(let friend): parent.onSelectFriend(friend)
            case .hang(let signal): parent.onSelectSignal(signal)
            case .destination, .you: break
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = line.title == "outline" ? .white.withAlphaComponent(0.95) : UIColor(Theme.orchid)
                renderer.lineWidth = line.title == "outline" ? 8 : 4
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor(Theme.orchid).withAlphaComponent(0.15)
                renderer.strokeColor = UIColor(Theme.orchid).withAlphaComponent(0.65)
                renderer.lineWidth = 1
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

final class FixedCanvasMapView: MKMapView {
    var onFirstLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, bounds.height > 0, let onFirstLayout {
            self.onFirstLayout = nil
            onFirstLayout()
        }
    }
}

private final class HangMapAnnotation: NSObject, MKAnnotation {
    enum Content {
        case friend(Friend), hang(Signal), destination(Signal), you

        var coordinate: CLLocationCoordinate2D {
            switch self {
            case .friend(let friend): friend.coordinate
            case .hang(let signal): signal.anchorCoordinate
            case .destination(let signal): signal.destinationCoordinate
            case .you: Friend.youCoordinate
            }
        }
    }

    let id: String
    var content: Content {
        didSet {
            if coordinate.latitude != content.coordinate.latitude || coordinate.longitude != content.coordinate.longitude {
                coordinate = content.coordinate
            }
        }
    }
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(id: String, content: Content) {
        self.id = id
        self.content = content
        coordinate = content.coordinate
    }
}

private final class HangMapAnnotationView: MKAnnotationView {
    private var host: (UIView & UIContentView)?
    private var appearance = ""

    func update(content: HangMapAnnotation.Content, dimmed: Bool, animateHalo: Bool) {
        let root: AnyView
        let label: String
        let identifier: String
        let key: String
        switch content {
        case .friend(let friend):
            root = AnyView(PersonMapMarker(initials: friend.initials, name: friend.firstName, color: friend.color))
            label = "\(friend.name), \(friend.hood)"
            identifier = "friend-pin-\(friend.id)"
            key = "friend-\(friend.id)-\(friend.initials)-\(friend.firstName)-\(friend.color)"
        case .hang(let signal):
            root = AnyView(SignalPinView(signal: signal, animatesHalo: animateHalo))
            label = "\(signal.hostName)’s hang: \(signal.title)"
            identifier = "signal-pin-\(signal.id)"
            key = "hang-\(signal.id)-\(signal.title)-\(signal.hostName)-\(signal.hostInitials)-\(signal.hostColor)-\(animateHalo)"
        case .destination(let signal):
            root = AnyView(SignalDestinationView(signal: signal))
            label = signal.place
            identifier = "hang-destination"
            key = "destination-\(signal.id)-\(signal.place)"
        case .you:
            root = AnyView(YouDotView())
            label = "Your sample location"
            identifier = "your-location"
            key = "you"
        }
        alpha = dimmed ? 0.35 : 1
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityIdentifier = identifier
        accessibilityTraits = identifier.hasPrefix("signal-pin") || identifier.hasPrefix("friend-pin") ? .button : .image
        displayPriority = .required
        collisionMode = .circle
        canShowCallout = false
        guard key != appearance else { return }
        appearance = key
        let configuration = UIHostingConfiguration { root }.margins(.all, 0)
        let contentView = host ?? configuration.makeContentView()
        contentView.configuration = configuration
        if host == nil {
            host = contentView
            contentView.isUserInteractionEnabled = false
            addSubview(contentView)
        }
        let size = contentView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        bounds = CGRect(origin: .zero, size: size)
        contentView.frame = bounds
        // Anchor the avatar itself, rather than the combined avatar/name stack.
        centerOffset = CGPoint(x: 0, y: identifier == "your-location" ? 0 : 12)
    }
}

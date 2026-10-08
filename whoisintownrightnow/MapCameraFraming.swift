import MapKit

/// Fits geographic content into the unobscured part of a fixed-size, flat map.
/// Insets change the destination camera, never the map view's frame.
enum MapCameraFraming {
    struct Fit {
        let center: CLLocationCoordinate2D
        let mapPointsPerPoint: Double
    }

    static func fit(_ rect: MKMapRect, in viewport: CGRect,
                    projectionCenter: CGPoint, heading: Double) -> Fit? {
        guard viewport.width > 1, viewport.height > 1, !rect.isNull,
              rect.width.isFinite, rect.height.isFinite, heading.isFinite else { return nil }
        let angle = heading * .pi / 180
        let cosine = cos(angle), sine = sin(angle)
        let width = abs(rect.width * cosine) + abs(rect.height * sine)
        let height = abs(rect.width * sine) + abs(rect.height * cosine)
        let scale = max(width / viewport.width, height / viewport.height)
        guard scale.isFinite, scale > 0 else { return nil }
        let dx = (viewport.midX - projectionCenter.x) * scale
        let dy = (viewport.midY - projectionCenter.y) * scale
        let center = MKMapPoint(x: rect.midX - (cosine * dx - sine * dy),
                                y: rect.midY - (sine * dx + cosine * dy))
        return Fit(center: center.coordinate, mapPointsPerPoint: scale)
    }
}

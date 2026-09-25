import MapKit

// Run from the repository root:
// xcrun swiftc Models.swift Tests/SignalConnectionTests.swift -o /tmp/signal-connection-tests
// /tmp/signal-connection-tests
@main
struct SignalConnectionTests {
    static func main() {
        for signal in Signal.mock {
            let connection = SignalConnection(signal: signal)
            let origin = MKMapPoint(signal.anchorCoordinate)
            let destination = MKMapPoint(signal.destinationCoordinate)
            let hidden = connection.coordinates(through: 0)
            let partial = connection.coordinates(through: 0.4)
            let complete = connection.coordinates(through: 1)

            require(hidden.allSatisfy { MKMapPoint($0).distance(to: origin) < 0.01 },
                    "An unrevealed connection must remain at the host")
            require(MKMapPoint(partial.first!).distance(to: origin) < 0.01,
                    "Drawing must start at the host's anchor")
            require(MKMapPoint(partial.last!).distance(to: destination) > 1,
                    "An intermediate frame must not reveal the destination yet")
            require(MKMapPoint(complete.last!).distance(to: destination) < 0.01,
                    "The completed line must reach the event location")
            require(complete.allSatisfy { connection.mapRect.contains(MKMapPoint($0)) },
                    "Camera bounds must include the entire curved connection")
            require(MKMapPoint(connection.coordinates(through: -1).last!).distance(to: origin) < 0.01,
                    "Negative progress must clamp to the host")
            require(MKMapPoint(connection.coordinates(through: 2).last!).distance(to: destination) < 0.01,
                    "Progress beyond completion must clamp to the destination")

            let host = Friend.mock.first { $0.id == signal.hostID }!
            require(MKMapPoint(host.coordinate).distance(to: origin) < 0.01,
                    "Mock signals must share their host's original map anchor")
        }

        let local = Signal(
            id: "local", hostID: "you", hostName: "You", hostInitials: "JD", hostColor: Theme.ink,
            title: "Meet here", place: "Mission", window: "Now", distance: "you", seats: 0,
            going: ["JD"], isJoined: true, isMine: true,
            anchorCoordinate: Friend.youCoordinate, anchorPlace: "Mission",
            destinationCoordinate: Friend.youCoordinate
        )
        let localConnection = SignalConnection(signal: local)
        require(local.destinationIsAtAnchor, "A local event must use the shared-location presentation")
        require(!Signal.mock[0].destinationIsAtAnchor, "A distant event must reveal a separate destination")
        require(localConnection.mapRect.size.width > 0 && localConnection.mapRect.size.height > 0,
                "A shared origin and destination must still have usable camera bounds")
        require(localConnection.coordinates(through: 1).allSatisfy {
            $0.latitude.isFinite && $0.longitude.isFinite
        }, "A shared origin and destination must never produce invalid coordinates")
        print("Passed: origin anchoring, progressive drawing, destination endpoint, camera fitting, progress clamping, and shared-location geometry.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}

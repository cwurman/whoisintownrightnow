import XCTest
@testable import whoisintownrightnow

@MainActor
final class MapDetailTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testLocationAgeMovesFromNowToMinutesAndHours() {
        let status = LocationFreshness.updated(now)
        XCTAssertEqual(status.label(at: now), "Now")
        XCTAssertEqual(status.label(at: now.addingTimeInterval(120)), "2 min ago")
        XCTAssertEqual(status.label(at: now.addingTimeInterval(3_600)), "1 hr ago")
        XCTAssertEqual(status.label(at: now.addingTimeInterval(-30)), "Now", "Clock skew must not produce negative ages")
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(LocationFreshness.updated(yesterday).label(at: now), "Yesterday")
    }

    func testUpdatingAndUnavailablePreserveTheAgeOfTheLastKnownLocation() {
        let previous = now.addingTimeInterval(-300)
        let updating = LocationFreshness.updating(lastUpdated: previous)
        XCTAssertEqual(updating.label(at: now), "Updating")
        XCTAssertEqual(updating.detail(at: now), "Last updated 5 min ago")
        let unavailable = LocationFreshness.unavailable(lastUpdated: previous)
        XCTAssertEqual(unavailable.label(at: now), "Location unavailable")
        XCTAssertEqual(unavailable.detail(at: now), "Last updated 5 min ago")
        XCTAssertNil(LocationFreshness.unavailable(lastUpdated: nil).detail(at: now))
    }

    func testRemainingSpotsIncludeTheHostAndPreventOverfilling() {
        var hang = Signal.mock[0]
        XCTAssertEqual(hang.remainingSpots, 2)
        XCTAssertTrue(hang.canJoin)
        hang.going.append("AB")
        XCTAssertEqual(hang.remainingSpots, 1)
        hang.going.append("CD")
        XCTAssertEqual(hang.remainingSpots, 0)
        XCTAssertFalse(hang.canJoin)
        hang.going.append("EF")
        XCTAssertEqual(hang.remainingSpots, 0, "Capacity must never show negative spots")
    }

    func testUnlimitedAndJoinedHangsHaveDistinctJoinStates() {
        var hang = Signal.mock[1]
        XCTAssertNil(hang.remainingSpots)
        XCTAssertTrue(hang.canJoin)
        hang.isJoined = true
        XCTAssertFalse(hang.canJoin)
        XCTAssertFalse(hang.isFull)
    }
}

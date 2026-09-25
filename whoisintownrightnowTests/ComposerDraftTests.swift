import MapKit
import XCTest
@testable import whoisintownrightnow

@MainActor
final class ComposerDraftTests: XCTestCase {
    func testChosenPinAndAreaUseTheCoordinatesShownInThePicker() {
        let draft = ComposerDraft()
        let selected = CLLocationCoordinate2D(latitude: 37.81, longitude: -122.46)
        draft.chosenPlace = "Dropped pin"
        draft.droppedCoordinate = selected
        XCTAssertEqual(draft.placeCoordinate.latitude, selected.latitude)
        XCTAssertEqual(draft.placeCoordinate.longitude, selected.longitude)

        draft.mode = .region
        XCTAssertEqual(draft.placeCoordinate.latitude, Friend.youCoordinate.latitude)
        XCTAssertEqual(draft.placeCoordinate.longitude, Friend.youCoordinate.longitude)

        draft.mode = .pin
        draft.chosenPlace = "Dolores Park"
        XCTAssertEqual(draft.placeCoordinate.latitude, 37.7596)
        XCTAssertEqual(draft.placeCoordinate.longitude, -122.4269)
    }

    func testPostingRequiresTextAndAFutureScheduledTime() {
        let draft = ComposerDraft()
        draft.text = " \n\t "
        XCTAssertFalse(draft.canPost)
        draft.text = "Coffee in the park"
        XCTAssertTrue(draft.canPost)
        draft.timeMode = .later
        draft.scheduledAt = Date().addingTimeInterval(-60)
        XCTAssertFalse(draft.canPost)
        draft.scheduledAt = Date().addingTimeInterval(3600)
        XCTAssertTrue(draft.canPost)
        XCTAssertEqual(draft.whenText, draft.scheduledAt.formatted(date: .abbreviated, time: .shortened))
    }
}

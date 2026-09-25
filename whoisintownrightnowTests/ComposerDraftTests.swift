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
        draft.choosePlace(ComposerDraft.places[1])
        XCTAssertEqual(draft.placeCoordinate.latitude, 37.7596)
        XCTAssertEqual(draft.placeCoordinate.longitude, -122.4269)
    }

    func testPostingWaitsForVideoImportAndCancellationRestoresTextOnlyPosting() {
        let draft = ComposerDraft()
        draft.text = "Coffee?"
        draft.choosePlace(ComposerDraft.places[1])
        draft.timeMode = .now
        XCTAssertTrue(draft.canPost)
        draft.videoAttachment.prepare {
            try await Task.sleep(for: .seconds(30))
            throw HangVideoError.exportFailed
        }
        XCTAssertFalse(draft.canPost)
        draft.videoAttachment.cancelImport()
        XCTAssertTrue(draft.canPost)
        XCTAssertNil(draft.videoAttachment.video)
    }

    func testPostingRequiresTextAndAFutureScheduledTime() {
        let draft = ComposerDraft()
        draft.text = " \n\t "
        XCTAssertFalse(draft.canPost)
        draft.text = "Coffee in the park"
        XCTAssertFalse(draft.canPost)
        draft.choosePlace(ComposerDraft.places[1])
        XCTAssertFalse(draft.canPost)
        draft.timeMode = .now
        XCTAssertTrue(draft.canPost)
        draft.timeMode = .later
        draft.scheduledAt = Date().addingTimeInterval(-60)
        XCTAssertFalse(draft.canPost)
        draft.scheduledAt = Date().addingTimeInterval(3600)
        XCTAssertTrue(draft.canPost)
        XCTAssertEqual(draft.whenText, draft.scheduledAt.formatted(date: .abbreviated, time: .shortened))
    }

    func testSuggestionsRequirePlaceConfirmationAndDoNotGuessMissingTime() {
        let draft = ComposerDraft()
        draft.apply(HangDraftSuggestion(transcript: "Coffee at Lucia", title: "Coffee", placeName: "Lucia",
            startMode: "unspecified", startsAt: nil, durationMinutes: nil, groupLimit: nil))
        XCTAssertFalse(draft.hasPlace, "A matching sample name does not establish which venue was meant")
        XCTAssertEqual(draft.timeMode, .unspecified)
        XCTAssertFalse(draft.canPost)
        XCTAssertTrue(draft.recipientIDs.isEmpty)
        draft.choosePin(CLLocationCoordinate2D(latitude: 40, longitude: -73))
        XCTAssertEqual(draft.chosenPlace, "Lucia")
        XCTAssertTrue(draft.hasPlace)
        draft.timeMode = .now
        XCTAssertTrue(draft.canPost)
    }

    func testSuggestionDatesAndNumericBoundsAreValidated() {
        let draft = ComposerDraft()
        let now = Date(timeIntervalSince1970: 0)
        draft.apply(HangDraftSuggestion(transcript: "Dinner", title: "Dinner", placeName: nil,
            startMode: "scheduled", startsAt: "2026-09-25T20:00:00.000-07:00", durationMinutes: 90, groupLimit: 4), now: now)
        XCTAssertEqual(draft.timeMode, .later)
        XCTAssertEqual(draft.durationMinutes, 90)
        XCTAssertEqual(draft.seats, 4)
        draft.apply(HangDraftSuggestion(transcript: "Dinner", title: nil, placeName: nil,
            startMode: "scheduled", startsAt: "invalid", durationMinutes: -1, groupLimit: 900), now: now)
        XCTAssertEqual(draft.timeMode, .unspecified)
        XCTAssertNil(draft.durationMinutes)
        XCTAssertNil(draft.seats)
        XCTAssertFalse(draft.canPost)
    }
}

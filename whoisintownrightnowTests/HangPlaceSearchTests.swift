import CoreLocation
import XCTest
@testable import whoisintownrightnow

@MainActor
final class HangPlaceSearchTests: XCTestCase {
    private func venue(_ id: String, name: String = "Lucia", latitude: Double = 37) -> HangVenue {
        HangVenue(candidate: HangVenueCandidate(id: id, name: name, address: "Test address", category: "restaurant", distanceMeters: 500), latitude: latitude, longitude: -122)
    }

    func testQueriesKeepVenueAndSpokenCityAndRejectVagueLocations() {
        XCTAssertEqual(HangPlaceCandidates.searchQueries(from: "Let's get dinner at Lucia tonight").first, "Lucia")
        XCTAssertEqual(HangPlaceCandidates.searchQueries(from: "Dinner at Lucia in Oakland tonight at 8").first, "Lucia in Oakland")
        XCTAssertFalse(HangPlaceCandidates.searchQueries(from: "Meet at my place tonight").contains("my place"))
        XCTAssertFalse(HangPlaceCandidates.searchQueries(from: "Meet at 8 PM").contains("8 PM"))
        XCTAssertTrue(HangPlaceCandidates.searchQueries(from: "Let's hang").isEmpty)
    }

    func testSearchBiasRejectsStaleOrInvalidGPSAndAcceptsReducedAccuracy() {
        let now = Date()
        func fix(age: TimeInterval, accuracy: Double) -> CLLocation {
            CLLocation(coordinate: .init(latitude: 37, longitude: -122), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertTrue(HangSearchLocation.usable(fix(age: 20, accuracy: 5000), now: now))
        XCTAssertFalse(HangSearchLocation.usable(fix(age: 121, accuracy: 10), now: now))
        XCTAssertFalse(HangSearchLocation.usable(fix(age: 0, accuracy: -1), now: now))
        XCTAssertFalse(HangSearchLocation.usable(fix(age: 0, accuracy: 50_000), now: now))
    }

    func testCandidatesAreDeduplicatedAndBoundedWithoutDroppingOtherQueries() {
        let a = (0..<10).map { venue("a\($0)", latitude: Double($0)) }
        let b = [venue("b", name: "Lucia Oakland", latitude: 38), a[0]]
        let merged = HangPlaceSearch.merge([a, b])
        XCTAssertEqual(merged.count, 8)
        XCTAssertEqual(merged[0].id, "a0")
        XCTAssertEqual(merged[1].id, "b")
        XCTAssertEqual(Set(merged.map(\.id)).count, 8)
        XCTAssertEqual(HangPlaceSearch.merge([[a[0]], [venue("alternate", latitude: 0)]]).count, 1)
    }

    func testJevChoiceUsesTheRetrievedCoordinatesAndUnknownChoiceStaysUnset() {
        let draft = ComposerDraft()
        var suggestion = HangDraftSuggestion(transcript: "Lucia", title: "Dinner", placeName: "Wrong free text",
            startMode: "now", startsAt: nil, durationMinutes: nil, groupLimit: nil)
        suggestion.placeID = "apple-venue"
        suggestion.resolvedVenue = venue("apple-venue", latitude: 38.2)
        draft.apply(suggestion)
        XCTAssertEqual(draft.chosenPlace, "Lucia")
        XCTAssertEqual(draft.placeCoordinate.latitude, 38.2)
        XCTAssertTrue(draft.canPost)
        suggestion.resolvedVenue = nil
        draft.areaCoordinate = .init(latitude: 40, longitude: -73)
        draft.apply(suggestion)
        XCTAssertFalse(draft.hasPlace)
        XCTAssertNil(draft.selectedVenue)
        XCTAssertNil(draft.areaCoordinate, "A retake must not inherit an old plan's area")
        suggestion.resolvedVenue = venue("invalid", latitude: .nan)
        draft.apply(suggestion)
        XCTAssertFalse(draft.hasPlace)
    }

    func testProviderPayloadDoesNotIncludeCoordinates() throws {
        let data = try JSONEncoder().encode(venue("apple-id").candidate)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "name", "address", "category", "distanceMeters"]))
    }

    func testLateSearchResultsCannotReplaceANewerQuery() async throws {
        let model = HangPlacePickerSearch()
        let oldStarted = expectation(description: "old search")
        var pending: CheckedContinuation<[HangVenue], Never>?
        let old = Task { await model.run("old", near: nil) { _, _ in
            await withCheckedContinuation { pending = $0; oldStarted.fulfill() }
        } }
        await fulfillment(of: [oldStarted], timeout: 2)
        await model.run("new", near: nil) { _, _ in [self.venue("new")] }
        pending?.resume(returning: [venue("old")])
        await old.value
        XCTAssertEqual(model.results.map(\.id), ["new"])
        XCTAssertFalse(model.isSearching)
        await model.run("", near: nil)
        XCTAssertTrue(model.results.isEmpty)
    }
}

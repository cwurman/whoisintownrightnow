import XCTest
@testable import whoisintownrightnow

@MainActor
final class HangDraftAssistantTests: XCTestCase {
    private var suggestion: HangDraftSuggestion {
        HangDraftSuggestion(transcript: "Coffee now", title: "Coffee", placeName: nil,
            startMode: "now", startsAt: nil, durationMinutes: nil, groupLimit: nil)
    }

    func testSuccessfulAnalysisPreparesAnEditableDraft() async throws {
        let assistant = HangDraftAssistant()
        let draft = ComposerDraft()
        let value = suggestion
        assistant.analyze({ value }, apply: { draft.apply($0) })
        try await finish(assistant)
        XCTAssertEqual(assistant.stage, .review)
        XCTAssertEqual(draft.text, "Coffee")
        XCTAssertFalse(draft.canPost, "A transcript without a confirmed place cannot be posted")
    }

    func testFailureAllowsManualReview() async throws {
        let assistant = HangDraftAssistant()
        assistant.analyze({ throw HangAnalysisError.noSpeech }, apply: { _ in XCTFail("Failed extraction must not change the form") })
        try await finish(assistant)
        XCTAssertEqual(assistant.stage, .failed)
        XCTAssertNotNil(assistant.errorMessage)
        assistant.reviewManually()
        XCTAssertEqual(assistant.stage, .review)
    }

    func testLateResultCannotOverwriteManualEdits() async throws {
        let assistant = HangDraftAssistant()
        let draft = ComposerDraft()
        var continuation: CheckedContinuation<HangDraftSuggestion, Never>?
        let started = expectation(description: "Analysis began")
        let returned = expectation(description: "Late result returned")
        assistant.analyze({
            let value = await withCheckedContinuation { continuation = $0; started.fulfill() }
            returned.fulfill()
            return value
        }, apply: { draft.apply($0) })
        await fulfillment(of: [started], timeout: 2)
        assistant.reviewManually()
        draft.text = "My own plan"
        continuation?.resume(returning: suggestion)
        await fulfillment(of: [returned], timeout: 2)
        await Task.yield()
        XCTAssertEqual(draft.text, "My own plan")
        XCTAssertEqual(assistant.stage, .review)
        XCTAssertNil(assistant.suggestion)
    }

    func testNamedEntityProposalsStayVerbatimBoundedAndUnique() {
        let text = "Dinner in San Francisco at Golden Gate Park, then back to San Francisco."
        let values = HangPlaceCandidates.extract(from: text)
        XCTAssertLessThanOrEqual(values.count, 24)
        XCTAssertEqual(Set(values).count, values.count)
        for value in values { XCTAssertTrue(text.contains(value)); XCTAssertLessThanOrEqual(value.count, 72) }
    }

    private func finish(_ assistant: HangDraftAssistant) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while assistant.stage == .processing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(assistant.stage, .processing)
    }
}

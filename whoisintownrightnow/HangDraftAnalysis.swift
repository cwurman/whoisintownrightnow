import Foundation
import Observation

nonisolated struct HangDraftSuggestion: Codable, Sendable {
    let transcript: String
    let title: String?
    let placeName: String?
    let startMode: String
    let startsAt: String?
    let durationMinutes: Int?
    let groupLimit: Int?
    var confidence: [String: Double]? = nil
}

nonisolated enum HangAnalysisError: LocalizedError {
    case noAudio, unavailable, signInRequired, rateLimited, noSpeech, invalidResponse

    var errorDescription: String? {
        switch self {
        case .noAudio: "This video doesn’t have an audio track. Record an invitation with sound, or fill in the details yourself."
        case .unavailable: "AI drafting isn’t available right now. Your video is saved here—try again or fill in the details yourself."
        case .signInRequired: "Sign in to turn your video into a draft. You can still fill in the details in this preview."
        case .rateLimited: "You’ve reached the drafting limit for now. Try again later or fill in the details yourself."
        case .noSpeech: "We couldn’t hear an invitation clearly. Try recording again, or fill in the details yourself."
        case .invalidResponse: "We couldn’t turn that invitation into a draft. Try again or fill in the details yourself."
        }
    }
}

@MainActor @Observable
final class HangDraftAssistant {
    enum Stage { case record, processing, review, failed }
    private(set) var stage: Stage = .record
    private(set) var errorMessage: String?
    private(set) var suggestion: HangDraftSuggestion?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    deinit { task?.cancel() }

    func analyze(_ operation: @escaping @MainActor () async throws -> HangDraftSuggestion,
                 apply: @escaping @MainActor (HangDraftSuggestion) -> Void) {
        cancel()
        stage = .processing
        errorMessage = nil
        suggestion = nil
        let current = generation
        task = Task { [weak self] in
            do {
                let suggestion = try await operation()
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                apply(suggestion)
                self.suggestion = suggestion
                self.stage = .review
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.errorMessage = (error as? HangAnalysisError)?.localizedDescription
                    ?? (error as? HangSpeechError)?.localizedDescription ?? HangAnalysisError.unavailable.localizedDescription
                self.stage = .failed
            }
            self?.task = nil
        }
    }

    func reviewManually() { cancel(); stage = .review }
    func recordAgain() { cancel(); stage = .record; suggestion = nil; errorMessage = nil }
    func cancel() { task?.cancel(); task = nil; generation = UUID() }
}

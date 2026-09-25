import Foundation
import NaturalLanguage

nonisolated enum HangPlaceCandidates {
    /// Keep a spoken city with the venue (for example “Lucia in Oakland”) so it can override GPS bias.
    static func searchQueries(from text: String) -> [String] {
        let pattern = #"\b(?:at|near|outside|inside|by|in)\s+([^.!?\n,]{1,120})"#
        let matches = (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?
            .matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        var values = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let phrase = String(text[range])
            let end = phrase.range(of: #"\b(?:today|tonight|tomorrow|this|next|for|around|with|and|starting|from|at\s+\d)\b"#,
                                   options: [.regularExpression, .caseInsensitive])?.lowerBound ?? phrase.endIndex
            return String(phrase[..<end])
        }
        values += extract(from: text)
        var queries: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let vague = ["here", "there", "home", "my place", "your place", "our place", "the usual spot", "the park", "a park", "a restaurant", "a bar", "nearby", "town"]
            guard trimmed.count >= 2, trimmed.count <= 120, trimmed.first?.isNumber != true,
                  !vague.contains(trimmed.lowercased()), !queries.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
            queries.append(trimmed)
            if queries.count == 3 { break }
        }
        return queries
    }

    /// These are proposals only. Jev decides whether each named entity is the meeting place.
    static func extract(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var candidates: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.joinNames, .omitWhitespace, .omitPunctuation]) { tag, range in
            if tag == .placeName || tag == .organizationName {
                let value = String(text[range])
                if value.count <= 72, !candidates.contains(value) { candidates.append(value) }
            }
            return candidates.count < 24
        }
        return candidates
    }
}

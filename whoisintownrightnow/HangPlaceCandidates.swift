import Foundation
import NaturalLanguage

nonisolated enum HangPlaceCandidates {
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

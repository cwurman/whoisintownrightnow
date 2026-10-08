// Local menu OCR. Compile with: xcrun swiftc menu_ocr.swift -o .bin/menu-ocr
import Foundation
import Vision

guard CommandLine.arguments.count == 2 else { exit(2) }
do {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.automaticallyDetectsLanguage = true
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    try handler.perform([request])
    let lines: [[String: Any]] = (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first,
              candidate.confidence >= 0.5 else { return nil }
        return ["text": candidate.string, "confidence": candidate.confidence]
    }
    let output: [String: Any] = ["engine": "Apple Vision VNRecognizeTextRequest accurate",
                                "text": lines.compactMap { $0["text"] as? String }.joined(separator: "\n"),
                                "lines": lines]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("Local OCR failed\n", stderr)
    exit(1)
}

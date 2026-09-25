import AVFoundation
import Speech
import XCTest
@testable import whoisintownrightnow

@MainActor
final class HangTranscriptionTests: XCTestCase {
    func testFinalPassagesReplaceProvisionalTextWithoutRepeatingOrLosingLaterWords() {
        var text = HangTranscriptAccumulator()
        text.receive("Dinner at Lucy", at: 0, isFinal: false)
        text.receive("Dinner at Lucia", at: 0, isFinal: false)
        XCTAssertEqual(text.displayText, "Dinner at Lucia")
        XCTAssertEqual(text.finalText, "", "Provisional words cannot reach Jev")
        text.receive("tonight", at: 2, isFinal: false)
        text.receive("Dinner at Lucia", at: 0, isFinal: true)
        XCTAssertEqual(text.displayText, "Dinner at Lucia tonight")
        text.receive("Dinner at Lucy", at: 0, isFinal: false)
        XCTAssertEqual(text.displayText, "Dinner at Lucia tonight", "Late provisional results cannot undo a finalized passage")
        text.receive("tonight", at: 2, isFinal: true)
        text.receive("Dinner at Lucia", at: 0, isFinal: true)
        XCTAssertEqual(text.finalText, "Dinner at Lucia tonight")
        let retake = HangTranscriptAccumulator()
        XCTAssertTrue(retake.displayText.isEmpty)
    }

    func testAudioIsConvertedAndFlushedForSpeechWithoutChangingItsDuration() async throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let speechFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let feed = HangSpeechFeed(format: speechFormat, continuation: continuation)
        for _ in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4800))
            buffer.frameLength = 4800
            for index in 0..<4800 { buffer.floatChannelData?[0][index] = Float(sin(Double(index) * .pi / 60)) * 0.2 }
            try feed.append(buffer)
        }
        XCTAssertTrue(feed.finish())
        var frames = 0
        for await input in stream {
            XCTAssertEqual(input.buffer.format.sampleRate, 16000)
            frames += Int(input.buffer.frameLength)
        }
        XCTAssertEqual(Double(frames) / 16000, 1, accuracy: 0.02)
    }

    func testDroppedSpeechBuffersInvalidateTheWholeTranscript() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(1))
        defer { withExtendedLifetime(stream) { } }
        let feed = HangSpeechFeed(format: format, continuation: continuation)
        for _ in 0..<3 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
            buffer.frameLength = 1600
            buffer.floatChannelData?[0].initialize(repeating: 0, count: 1600)
            try feed.append(buffer)
        }
        XCTAssertFalse(feed.finish(), "A transcript missing audio must not become a confident AI draft")
    }

}

import AVFoundation
import Foundation
import Speech

nonisolated enum HangSpeechError: LocalizedError {
    case unsupported, audio, noSpeech
    var errorDescription: String? {
        switch self {
        case .unsupported: "Live transcription isn’t available for this device or language. You can still record and add the details yourself."
        case .audio: "We couldn’t transcribe all of the audio. Your video is safe; you can add the details yourself."
        case .noSpeech: "We couldn’t hear an invitation clearly. Try again or add the details yourself."
        }
    }
}

/// Final passages replace provisional text; a retake gets a new accumulator.
nonisolated struct HangTranscriptAccumulator {
    private var finalized: [Double: String] = [:]
    private var provisional: [Double: String] = [:]
    var finalText: String { finalized.sorted { $0.key < $1.key }.map(\.value).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    var displayText: String { finalized.merging(provisional) { _, latest in latest }.sorted { $0.key < $1.key }.map(\.value).joined(separator: " ") }
    mutating func receive(_ text: String, at start: Double, isFinal: Bool) {
        guard start.isFinite else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal { finalized[start] = value; provisional.removeValue(forKey: start) }
        else if finalized[start] == nil { provisional[start] = value }
    }
}

/// All feed/finish calls belong to the capture queue. Buffers are copied before leaving AVFoundation.
nonisolated final class HangSpeechFeed: @unchecked Sendable {
    let format: AVAudioFormat
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private(set) var failed = false

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.format = format
        self.continuation = continuation
    }

    func append(_ sample: CMSampleBuffer) {
        guard !failed, let description = sample.formatDescription else { failed = true; return }
        let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(sample.numSamples)) else {
            failed = true; return
        }
        input.frameLength = input.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(input.frameLength), into: input.mutableAudioBufferList) == noErr else {
            failed = true; return
        }
        do { try append(input) } catch { failed = true }
    }

    func append(_ input: AVAudioPCMBuffer) throws {
        if converter == nil || converter?.inputFormat != input.format { converter = AVAudioConverter(from: input.format, to: format) }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 128) else { throw HangSpeechError.audio }
        let ownedInput = AnalyzerInput(buffer: input)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return ownedInput.buffer
        }
        if status == .error || error != nil { throw HangSpeechError.audio }
        yield(output)
    }

    func finish() -> Bool {
        if let converter, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) {
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            if status == .error || error != nil { failed = true }
            yield(buffer)
        }
        continuation.finish()
        return !failed
    }

    private func yield(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        switch continuation.yield(AnalyzerInput(buffer: buffer)) {
        case .enqueued: break
        case .dropped, .terminated: failed = true
        @unknown default: failed = true
        }
    }
}

@MainActor
final class HangSpeechSession {
    let feed: HangSpeechFeed
    private let analyzer: SpeechAnalyzer
    private let locale: String
    private let resultTask: Task<String, Error>
    private let analysisTask: Task<Void, Error>

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat, transcriber: SpeechTranscriber,
                 onText: @escaping @MainActor (String) -> Void) {
        self.analyzer = analyzer
        locale = transcriber.selectedLocales.first?.identifier ?? "en-US"
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(128))
        feed = HangSpeechFeed(format: format, continuation: continuation)
        resultTask = Task {
            var transcript = HangTranscriptAccumulator()
            for try await result in transcriber.results {
                try Task.checkCancellation()
                transcript.receive(String(result.text.characters), at: result.range.start.seconds, isFinal: result.isFinal)
                onText(transcript.displayText)
            }
            return transcript.finalText
        }
        analysisTask = Task {
            do {
                if let end = try await analyzer.analyzeSequence(stream) { try await analyzer.finalizeAndFinish(through: end) }
                else { await analyzer.cancelAndFinishNow() }
            } catch { await analyzer.cancelAndFinishNow(); throw error }
        }
    }

    static func prepare(onText: @escaping @MainActor (String) -> Void) async throws -> HangSpeechSession {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { throw HangSpeechError.unsupported }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw HangSpeechError.unsupported }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do { try await analyzer.prepareToAnalyze(in: format); try Task.checkCancellation() }
        catch { await analyzer.cancelAndFinishNow(); throw error }
        return HangSpeechSession(analyzer: analyzer, format: format, transcriber: transcriber, onText: onText)
    }

    /// The capture queue must finish the feed before this is called.
    func finish(recordedAt: Date) async throws -> HangTranscript {
        try await withTaskCancellationHandler {
            try await analysisTask.value
            let text = try await resultTask.value
            try Task.checkCancellation()
            guard !resultTask.isCancelled, !analysisTask.isCancelled else { throw CancellationError() }
            guard !text.isEmpty else { throw HangSpeechError.noSpeech }
            return HangTranscript(text: text, locale: locale, recordedAt: recordedAt)
        } onCancel: { [analyzer] in Task { await analyzer.cancelAndFinishNow() } }
    }

    func cancel() {
        feed.continuation.finish()
        resultTask.cancel(); analysisTask.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    deinit {
        feed.continuation.finish()
        resultTask.cancel(); analysisTask.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

extension HangSpeechSession {
    static func transcribe(_ video: HangVideo) async throws -> HangTranscript {
        let speech = try await prepare { _ in }
        defer { speech.cancel() }
        let timeout = Task { try? await Task.sleep(for: .seconds(20)); if !Task.isCancelled { speech.cancel() } }
        defer { timeout.cancel() }
        let complete = try await feedFile(video, to: speech.feed)
        guard complete else { throw HangSpeechError.audio }
        return try await speech.finish(recordedAt: Date())
    }

    @concurrent private static func feedFile(_ video: HangVideo, to feed: HangSpeechFeed) async throws -> Bool {
        defer { withExtendedLifetime(video) { } }
        let asset = AVURLAsset(url: video.file.url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw HangAnalysisError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw HangSpeechError.audio }
        reader.add(output)
        guard reader.startReading() else { throw HangSpeechError.audio }
        defer { reader.cancelReading() }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            frames += sample.numSamples
            guard frames <= 48000 * 16 else { throw HangVideoError.tooLong }
            feed.append(sample)
        }
        guard reader.status == .completed else { throw HangSpeechError.audio }
        return feed.finish()
    }
}

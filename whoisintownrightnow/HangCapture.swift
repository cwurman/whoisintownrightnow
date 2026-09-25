import AVFoundation
import Observation
import SwiftUI

nonisolated enum HangCaptureError: LocalizedError {
    case unavailable, recording
    var errorDescription: String? {
        switch self {
        case .unavailable: "The camera couldn’t start. Try again or choose a video from Photos."
        case .recording: "The recording couldn’t be saved. Please try again."
        }
    }
}

nonisolated struct HangRecording: Sendable {
    let source: HangVideoSource
    let speechComplete: Bool
}

/// Session configuration, sample delivery, movie writing and speech feeding share one serial queue.
nonisolated final class HangCaptureEngine: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "town.hang.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var file: HangVideoFile?
    private var feed: HangSpeechFeed?
    private var recording = false
    private var isShutDown = false
    private var firstTime: CMTime?
    private var lastTime: CMTime?
    private var generation = UUID()
    private var stopTimer: DispatchWorkItem?
    private var completion: (@MainActor @Sendable (Result<HangRecording, HangCaptureError>) -> Void)?

    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard !self.isShutDown else { throw CancellationError() }
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    self.session.sessionPreset = .hd1280x720
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                            ?? AVCaptureDevice.default(for: .video),
                          let microphone = AVCaptureDevice.default(for: .audio) else { throw HangCaptureError.unavailable }
                    for device in [camera, microphone] {
                        let input = try AVCaptureDeviceInput(device: device)
                        guard self.session.canAddInput(input) else { throw HangCaptureError.unavailable }
                        self.session.addInput(input)
                    }
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                    for output in [self.videoOutput as AVCaptureOutput, self.audioOutput] {
                        guard self.session.canAddOutput(output) else { throw HangCaptureError.unavailable }
                        self.session.addOutput(output)
                    }
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.queue)
                    self.audioOutput.setSampleBufferDelegate(self, queue: self.queue)
                    if let connection = self.videoOutput.connection(with: .video) {
                        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                        if connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false
                            connection.isVideoMirrored = camera.position == .front
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.isShutDown else { continuation.resume(throwing: CancellationError()); return }
                self.session.startRunning(); continuation.resume()
            }
        }
    }

    func start(feed: HangSpeechFeed?, completion: @escaping @MainActor @Sendable (Result<HangRecording, HangCaptureError>) -> Void) {
        queue.async {
            guard !self.isShutDown, !self.recording else { return }
            self.generation = UUID()
            self.feed = feed
            self.completion = completion
            self.recording = true
            self.firstTime = nil; self.lastTime = nil
            let timer = DispatchWorkItem { [weak self] in self?.finish() }
            self.stopTimer = timer
            self.queue.asyncAfter(deadline: .now() + HangVideoImporter.maximumDuration, execute: timer)
        }
    }

    func stop() { queue.async { self.finish() } }
    func pause() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
    func resume() { queue.async { if !self.isShutDown, !self.session.isRunning { self.session.startRunning() } } }

    func shutdown() {
        queue.async {
            self.isShutDown = true
            self.generation = UUID()
            self.stopTimer?.cancel(); self.stopTimer = nil
            self.recording = false
            self.writer?.cancelWriting()
            _ = self.feed?.finish()
            self.reset()
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let time = sampleBuffer.presentationTimeStamp
        if firstTime == nil {
            guard output === videoOutput else { return }
            do { try beginMovie(sample: sampleBuffer) } catch { fail(); return }
            firstTime = time
        }
        guard let firstTime, time >= firstTime else { return }
        guard (time - firstTime).seconds < HangVideoImporter.maximumDuration else { finish(); return }
        if output === videoOutput {
            lastTime = time
            if videoInput?.isReadyForMoreMediaData == true, videoInput?.append(sampleBuffer) != true { fail() }
        } else {
            // Transcribe exactly the audio accepted into the movie, never preview or retake audio.
            guard audioInput?.isReadyForMoreMediaData == true, audioInput?.append(sampleBuffer) == true else { fail(); return }
            feed?.append(sampleBuffer)
        }
    }

    private func beginMovie(sample: CMSampleBuffer) throws {
        guard let description = sample.formatDescription else { throw HangCaptureError.recording }
        let size = CMVideoFormatDescriptionGetDimensions(description)
        try FileManager.default.createDirectory(at: HangVideoFile.directory, withIntermediateDirectories: true)
        let file = HangVideoFile(url: HangVideoFile.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4"))
        let writer = try AVAssetWriter(outputURL: file.url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000,
        ])
        video.expectsMediaDataInRealTime = true; audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw HangCaptureError.recording }
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw HangCaptureError.recording }
        writer.startSession(atSourceTime: sample.presentationTimeStamp)
        self.file = file; self.writer = writer; videoInput = video; audioInput = audio
    }

    private func finish() {
        guard recording else { return }
        recording = false
        stopTimer?.cancel(); stopTimer = nil
        let speechComplete = feed?.finish() ?? false
        guard let writer, let file, let firstTime, let lastTime, lastTime > firstTime else { fail(); return }
        let token = generation
        let completion = completion
        writer.endSession(atSourceTime: min(lastTime + CMTime(value: 1, timescale: 30), firstTime + CMTime(seconds: 15, preferredTimescale: 600)))
        videoInput?.markAsFinished(); audioInput?.markAsFinished()
        writer.finishWriting {
            self.queue.async {
                guard self.generation == token else { return }
                let success = self.writer?.status == .completed
                self.reset()
                Task { await completion?(success ? .success(HangRecording(source: HangVideoSource(file: file), speechComplete: speechComplete)) : .failure(.recording)) }
            }
        }
    }

    private func fail() {
        let completion = completion
        stopTimer?.cancel(); stopTimer = nil
        recording = false; writer?.cancelWriting(); _ = feed?.finish()
        reset()
        Task { await completion?(.failure(.recording)) }
    }

    private func reset() {
        writer = nil; videoInput = nil; audioInput = nil; file = nil; feed = nil
        firstTime = nil; lastTime = nil; completion = nil
    }
}

@MainActor @Observable
final class HangCaptureModel {
    enum Stage { case preparing, ready, recording, finishing, review, failed }
    let engine = HangCaptureEngine()
    private(set) var stage = Stage.preparing
    private(set) var caption = ""
    private(set) var speechMessage = "Preparing live transcription…"
    private(set) var video: HangVideo?
    private(set) var errorMessage: String?
    private(set) var isInterrupted = false
    private(set) var recordedAt = Date()
    @ObservationIgnored private var speech: HangSpeechSession?
    @ObservationIgnored private var preparingSpeech: Task<Void, Never>?
    @ObservationIgnored private var finishing: Task<Void, Never>?
    @ObservationIgnored private var takeID = UUID()

    func prepare() async {
        guard stage == .preparing else { return }
        do {
            try await engine.prepare()
            try Task.checkCancellation()
            guard stage == .preparing else { return }
            stage = .ready
            prepareSpeech()
        } catch { stage = .failed; errorMessage = error.localizedDescription }
    }

    private func prepareSpeech() {
        let token = takeID
        preparingSpeech = Task { [weak self] in
            do {
                let session = try await HangSpeechSession.prepare { [weak self] text in
                    guard self?.takeID == token else { return }
                    self?.caption = text
                }
                guard let self, self.takeID == token, !Task.isCancelled else { session.cancel(); return }
                self.speech = session
                self.speechMessage = "Ready to listen"
            } catch {
                guard let self, self.takeID == token, !Task.isCancelled else { return }
                self.speechMessage = (error as? HangSpeechError)?.localizedDescription ?? "Transcription couldn’t start. You can still record your invitation."
            }
            self?.preparingSpeech = nil
        }
    }

    var isPreparingSpeech: Bool { preparingSpeech != nil }

    func start() {
        guard stage == .ready, !isInterrupted else { return }
        // The user may record before the download completes; never attach a partial transcript.
        if isPreparingSpeech { preparingSpeech?.cancel(); preparingSpeech = nil; speechMessage = "Recording without live transcription" }
        recordedAt = Date(); caption = ""; stage = .recording
        let token = takeID
        engine.start(feed: speech?.feed) { [weak self] result in
            guard let self, self.takeID == token else { return }
            self.finish(result)
        }
    }

    func stop() { guard stage == .recording else { return }; stage = .finishing; engine.stop() }

    func interrupt() { isInterrupted = true; stop() }
    func interruptionEnded() { isInterrupted = false; if stage == .ready { engine.resume() } }
    func cameraFailed() {
        if stage == .recording { stop() }
        else if stage == .ready || stage == .preparing {
            errorMessage = HangCaptureError.unavailable.localizedDescription; stage = .failed
        }
    }

    private func finish(_ result: Result<HangRecording, HangCaptureError>) {
        stage = .finishing
        let token = takeID
        finishing = Task { [weak self] in
            guard let self else { return }
            do {
                let recording = try result.get()
                async let prepared = HangVideoImporter.prepare(recording.source)
                var transcript: HangTranscript?
                if recording.speechComplete, let speech = self.speech {
                    // A bound keeps a stalled speech service from trapping the recorded video.
                    let timeout = Task { try? await Task.sleep(for: .seconds(12)); if !Task.isCancelled { speech.cancel() } }
                    do { transcript = try await speech.finish(recordedAt: self.recordedAt) }
                    catch { self.speechMessage = "Couldn’t finish the transcript. You can add the details yourself." }
                    timeout.cancel()
                } else { self.speech?.cancel() }
                var video = try await prepared
                video.transcript = transcript
                video.capturedInApp = true
                guard self.takeID == token, !Task.isCancelled else { return }
                self.video = video
                self.caption = transcript?.text ?? ""
                self.engine.pause()
                self.stage = .review
            } catch {
                guard self.takeID == token, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription; self.stage = .failed
            }
            self.finishing = nil
        }
    }

    func retake() {
        takeID = UUID(); finishing?.cancel(); finishing = nil
        preparingSpeech?.cancel(); speech?.cancel(); speech = nil
        video = nil; caption = ""; errorMessage = nil; speechMessage = "Preparing live transcription…"
        stage = .ready; engine.resume(); prepareSpeech()
    }

    func cancel() {
        takeID = UUID(); preparingSpeech?.cancel(); finishing?.cancel(); speech?.cancel()
        preparingSpeech = nil; finishing = nil; speech = nil; video = nil
        engine.shutdown()
    }
}

struct HangCaptureScreen: View {
    @Bindable var model: HangCaptureModel
    @Environment(\.scenePhase) private var scenePhase
    let completion: (HangVideo?) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.stage != .review { HangCameraPreview(session: model.engine.session).ignoresSafeArea() }
            LinearGradient(colors: [.black.opacity(0.65), .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Button("Cancel", systemImage: "xmark") { model.cancel(); completion(nil) }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44).glassEffect()
                    Spacer()
                    Text(model.stage == .review ? "Your invitation" : "Invite them to hang").font(.headline)
                    Spacer().frame(width: 44)
                }
                if model.stage == .review, let video = model.video {
                    HangVideoPoster(video: video, title: "your invitation", height: 360)
                    ScrollView { Text(model.caption.isEmpty ? "No transcript available. You can add the details yourself." : model.caption).font(.body) }
                    Spacer(minLength: 0)
                    Button("Use video") { completion(video) }
                        .buttonStyle(.glassProminent).tint(Theme.orchid).foregroundStyle(Theme.ink)
                        .accessibilityIdentifier("use-hang-recording")
                    Button("Record again") { model.retake() }
                } else {
                    Spacer()
                    if model.stage == .recording {
                        TimelineView(.periodic(from: model.recordedAt, by: 0.1)) { timeline in
                            Text("\(min(15, max(0, Int(timeline.date.timeIntervalSince(model.recordedAt))))) / 15 sec")
                                .font(.subheadline.monospacedDigit()).padding(8).background(.black.opacity(0.4), in: Capsule())
                        }
                    }
                    if !model.caption.isEmpty { Text(model.caption).font(.title3.weight(.medium)).lineLimit(4).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)) }
                    if model.stage == .preparing || model.stage == .finishing {
                        ProgressView(model.stage == .finishing ? "Finishing your invitation…" : "Opening camera…").tint(.white)
                    } else if model.stage == .failed {
                        Text(model.errorMessage ?? "The camera couldn’t start.").multilineTextAlignment(.center)
                    } else {
                        Text(model.isInterrupted ? "Camera interrupted. Waiting to resume…" : model.stage == .recording ? "Say the plan, place, and time" : model.speechMessage)
                            .font(.footnote).multilineTextAlignment(.center)
                        Button { model.stage == .recording ? model.stop() : model.start() } label: {
                            ZStack {
                                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                                RoundedRectangle(cornerRadius: model.stage == .recording ? 8 : 36)
                                    .fill(model.stage == .recording ? .red : Theme.orchid)
                                    .frame(width: model.stage == .recording ? 32 : 64, height: model.stage == .recording ? 32 : 64)
                            }.frame(width: 88, height: 88)
                        }
                        .disabled(model.isInterrupted || (model.stage == .ready && model.isPreparingSpeech))
                        .accessibilityLabel(model.stage == .recording ? "Stop recording" : "Start recording")
                        .accessibilityIdentifier("capture-hang-video")
                        if model.stage == .ready {
                            if model.isPreparingSpeech { Button("Record without transcription") { model.start() }.font(.footnote).disabled(model.isInterrupted) }
                            Text("Your voice is transcribed on this device. When you use the video, its transcript goes to Jev to draft the details.")
                                .font(.caption).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
            }.padding(24).foregroundStyle(.white)
        }
        .environment(\.colorScheme, .dark)
        .task { await model.prepare() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification, object: model.engine.session)) { _ in model.interrupt() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.interruptionEndedNotification, object: model.engine.session)) { _ in model.interruptionEnded() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification, object: model.engine.session)) { _ in model.cameraFailed() }
        .interactiveDismissDisabled()
    }
}

private struct HangCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> Preview {
        let view = Preview(); view.layerView.session = session; view.layerView.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: Preview, context: Context) { }
    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layerView: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = layerView.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        }
    }
}

/// Keep the video-first camera portrait; the rest of the app retains its orientation support.
struct HangVideoCamera: UIViewControllerRepresentable {
    let completion: (HangVideo?) -> Void
    func makeUIViewController(context: Context) -> UIViewController { PortraitCamera(completion: completion) }
    func updateUIViewController(_ controller: UIViewController, context: Context) { }
    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        (controller as? PortraitCamera)?.captureModel.cancel()
    }
    private final class PortraitCamera: UIHostingController<HangCaptureScreen> {
        let captureModel: HangCaptureModel
        init(completion: @escaping (HangVideo?) -> Void) {
            let model = HangCaptureModel()
            captureModel = model
            super.init(rootView: HangCaptureScreen(model: model, completion: completion))
        }
        required init?(coder: NSCoder) { fatalError("Use init(completion:)") }
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
        override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
        override var prefersStatusBarHidden: Bool { true }
    }
}

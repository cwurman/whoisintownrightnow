import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HangVideoComposer: View {
    @Bindable var attachment: HangVideoAttachment
    @State private var selection: PhotosPickerItem?
    @State private var showCamera = false
    @State private var requestingCamera = false
    @State private var cameraError: String?
    @State private var offerSettings = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let video = attachment.video {
                HangVideoPoster(video: video, title: "Your invitation", height: 260)
                let controls = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 12))
                controls {
                    recordButton
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    photosButton
                    Button("Remove", systemImage: "trash", role: .destructive) { attachment.remove() }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                .font(.subheadline.weight(.medium))
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "video.bubble.fill")
                        .font(.system(size: 38, weight: .regular)).foregroundStyle(Theme.accent)
                        .padding(18).background(Theme.orchid.opacity(0.25), in: Circle())
                        .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text("Invite them yourself").font(.title2.bold()).foregroundStyle(Theme.label)
                        Text("A quick video makes it personal.")
                            .font(.subheadline).foregroundStyle(Theme.secondaryLabel)
                        Text("Optional · Up to 15 seconds")
                            .font(.caption).foregroundStyle(Theme.secondaryLabel)
                    }.multilineTextAlignment(.center)
                    recordButton
                        .buttonStyle(.glassProminent).tint(Theme.orchid).foregroundStyle(Theme.ink)
                    photosButton.font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 20)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Theme.orchid.opacity(0.45)))
            }
            if attachment.isPreparing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Preparing your video…").font(.subheadline)
                    Spacer()
                    Button("Cancel") { attachment.cancelImport() }.font(.subheadline.weight(.semibold))
                }.accessibilityElement(children: .contain)
            }
            if let error = attachment.errorMessage {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .buttonStyle(.borderless)
        .onChange(of: selection) { _, item in
            if let item { attachment.choose(item); selection = nil }
        }
        .fullScreenCover(isPresented: $showCamera) {
            HangVideoCamera { result in
                showCamera = false
                switch result {
                case .success(let source): if let source { attachment.recorded(source) }
                case .failure(let error): attachment.errorMessage = error.localizedDescription
                }
            }.ignoresSafeArea()
        }
        .alert("Can’t record a video", isPresented: Binding(get: { cameraError != nil }, set: { if !$0 { cameraError = nil } })) {
            if offerSettings {
                Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
            }
            Button("OK", role: .cancel) { }
        } message: { Text(cameraError ?? "") }
    }

    private var recordButton: some View {
        let hasVideo = attachment.video != nil
        return Button {
            Task { await openCamera() }
        } label: {
            Label(hasVideo ? "Record again" : "Record a video", systemImage: "video")
                .fontWeight(.semibold).padding(.vertical, 4)
        }
        .disabled(attachment.isPreparing || requestingCamera)
        .accessibilityIdentifier("record-hang-video")
    }

    private var photosButton: some View {
        let hasVideo = attachment.video != nil
        return PhotosPicker(selection: $selection, matching: .videos, preferredItemEncoding: .current) {
            Label(hasVideo ? "Replace" : "Choose video", systemImage: "photo.on.rectangle")
                .padding(.vertical, 6)
        }
        .disabled(attachment.isPreparing || requestingCamera)
        .accessibilityIdentifier("choose-hang-video")
    }

    @MainActor private func openCamera() async {
        guard !requestingCamera else { return }
        offerSettings = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera),
              UIImagePickerController.availableMediaTypes(for: .camera)?.contains(UTType.movie.identifier) == true else {
            cameraError = "This device doesn’t have a camera available. You can choose a video from Photos instead."
            return
        }
        requestingCamera = true
        defer { requestingCamera = false }
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        guard camera else {
            offerSettings = true
            cameraError = "Allow camera access in Settings to record an invitation. You can also choose an existing video."
            return
        }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphone else {
            offerSettings = true
            cameraError = "Allow microphone access in Settings so friends can hear your invitation."
            return
        }
        showCamera = true
    }
}

private struct HangVideoCamera: UIViewControllerRepresentable {
    let completion: (Result<HangVideoSource?, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let camera = UIImagePickerController()
        camera.sourceType = .camera
        camera.mediaTypes = [UTType.movie.identifier]
        camera.cameraCaptureMode = .video
        if UIImagePickerController.isCameraDeviceAvailable(.front) { camera.cameraDevice = .front }
        camera.videoMaximumDuration = HangVideoImporter.maximumDuration
        camera.videoQuality = .typeHigh
        camera.delegate = context.coordinator
        return camera
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (Result<HangVideoSource?, Error>) -> Void
        init(completion: @escaping (Result<HangVideoSource?, Error>) -> Void) { self.completion = completion }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(.success(nil)) }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let url = info[.mediaURL] as? URL else { completion(.failure(HangVideoError.unreadable)); return }
            completion(Result { try HangVideoSource.copy(from: url) })
        }
    }
}

struct HangVideoPoster: View {
    let video: HangVideo
    let title: String
    var height: CGFloat = 330
    @State private var showPlayer = false

    var body: some View {
        Button { showPlayer = true } label: {
            GeometryReader { geometry in
                ZStack {
                    Theme.cocoa
                    if let poster = UIImage(data: video.poster) {
                        Image(uiImage: poster).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                    LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                    Image(systemName: "play.fill").font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(.white).padding(23)
                        .glassEffect(.regular, in: Circle()).environment(\.colorScheme, .dark)
                    VStack {
                        Spacer()
                        HStack(alignment: .bottom) {
                            Text("Play invitation").font(.headline)
                            Spacer()
                            Text(video.durationLabel).font(.subheadline.monospacedDigit())
                        }.foregroundStyle(.white).padding(20)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 28))
            }.frame(height: height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(title), \(Int(video.duration.rounded(.up))) seconds")
        .accessibilityIdentifier("play-hang-video")
        .fullScreenCover(isPresented: $showPlayer) { HangVideoPlayer(video: video, title: title) }
    }
}

private struct HangVideoPlayer: View {
    let video: HangVideo
    let title: String
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(video: HangVideo, title: String) {
        self.video = video
        self.title = title
        _player = State(initialValue: AVPlayer(url: video.file.url))
    }

    var body: some View {
        HangPlayerController(player: player, title: title) { dismiss() }
            .ignoresSafeArea()
            .onAppear {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try? AVAudioSession.sharedInstance().setActive(true)
                player.play()
            }
            .onDisappear {
                player.pause()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { player.pause() } }
    }
}

/// Keep the cinema appearance scoped to UIKit's player, without changing the presenting sheet's theme.
private struct HangPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let title: String
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let video = AVPlayerViewController()
        video.player = player
        video.allowsPictureInPicturePlayback = false
        video.title = title
        video.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done,
            primaryAction: UIAction { _ in onClose() })
        let navigation = UINavigationController(rootViewController: video)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.navigationBar.tintColor = UIColor(Theme.orchid)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .black
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        return navigation
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) { }

    static func dismantleUIViewController(_ controller: UINavigationController, coordinator: ()) {
        (controller.viewControllers.first as? AVPlayerViewController)?.player = nil
    }
}

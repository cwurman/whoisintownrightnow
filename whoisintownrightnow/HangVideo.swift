import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum HangVideoError: LocalizedError {
    case unreadable, tooLong, tooLarge, exportFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "That video couldn’t be opened. Try another clip."
        case .tooLong: "Choose a video 15 seconds or shorter. You can trim it in Photos first."
        case .tooLarge: "That video is too large. Try a shorter clip."
        case .exportFailed: "We couldn’t prepare that video. Please try again."
        }
    }
}

/// Copies provider-owned URLs before Photos or the camera releases them.
nonisolated struct HangVideoSource: Transferable, Sendable {
    let file: HangVideoFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try copy(from: received.file)
        }
    }

    static func copy(from source: URL) throws -> Self {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 250_000_000 else { throw HangVideoError.tooLarge }
        try FileManager.default.createDirectory(at: HangVideoFile.directory, withIntermediateDirectories: true)
        let destination = HangVideoFile.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        let file = HangVideoFile(url: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return Self(file: file)
    }
}

nonisolated enum HangVideoImporter {
    static let maximumDuration = 15.0

    @concurrent static func prepare(_ source: HangVideoSource) async throws -> HangVideo {
        defer { withExtendedLifetime(source) { } }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source.file.url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw HangVideoError.unreadable }
        // Recorders can include one final frame beyond their nominal limit.
        guard duration <= maximumDuration + 0.25 else { throw HangVideoError.tooLong }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw HangVideoError.exportFailed
        }
        let output = HangVideoFile(url: HangVideoFile.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4"))
        exporter.metadata = []
        exporter.shouldOptimizeForNetworkUse = true
        let finalDuration = min(duration, maximumDuration)
        exporter.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: finalDuration, preferredTimescale: 600))
        try await exporter.export(to: output.url, as: .mp4)
        try Task.checkCancellation()
        let outputSize = try output.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard outputSize > 0, outputSize <= 50_000_000 else { throw HangVideoError.tooLarge }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        let frame = try await generator.image(at: CMTime(seconds: min(0.2, finalDuration / 2), preferredTimescale: 600))
        guard let poster = UIImage(cgImage: frame.image).jpegData(compressionQuality: 0.8) else { throw HangVideoError.exportFailed }
        try Task.checkCancellation()
        return HangVideo(file: output, poster: poster, duration: finalDuration)
    }

    /// Clear remnants of terminated sessions; active clips are managed by reference lifetime.
    static func removeExpiredFiles(now: Date = Date()) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: HangVideoFile.directory,
            includingPropertiesForKeys: [.creationDateKey])) ?? []
        for url in urls {
            if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
               now.timeIntervalSince(created) > 86_400 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

@MainActor @Observable
final class HangVideoAttachment {
    private(set) var video: HangVideo?
    private(set) var isPreparing = false
    var errorMessage: String?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importID: UUID?

    deinit { importTask?.cancel() }

    func choose(_ item: PhotosPickerItem) {
        prepare {
            guard let source = try await item.loadTransferable(type: HangVideoSource.self) else { throw HangVideoError.unreadable }
            return try await HangVideoImporter.prepare(source)
        }
    }

    func recorded(_ source: HangVideoSource) {
        prepare { try await HangVideoImporter.prepare(source) }
    }

    /// Keep the previous clip until its replacement succeeds; cancellation never posts a partial import.
    func prepare(_ operation: @escaping @Sendable () async throws -> HangVideo) {
        cancelImport()
        errorMessage = nil
        isPreparing = true
        let id = UUID()
        importID = id
        importTask = Task { [weak self] in
            do {
                let prepared = try await operation()
                try Task.checkCancellation()
                guard let self, self.importID == id else { return }
                self.video = prepared
            } catch {
                guard let self, self.importID == id, !Task.isCancelled else { return }
                self.errorMessage = (error as? HangVideoError)?.localizedDescription
                    ?? "We couldn’t load that video. Please try again or choose another clip."
            }
            guard let self, self.importID == id else { return }
            self.isPreparing = false
            self.importTask = nil
            self.importID = nil
        }
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importID = nil
        isPreparing = false
    }

    func remove() {
        cancelImport()
        video = nil
        errorMessage = nil
    }
}

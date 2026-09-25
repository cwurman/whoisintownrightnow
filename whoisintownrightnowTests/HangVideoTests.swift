import AVFoundation
import UIKit
import XCTest
@testable import whoisintownrightnow

@MainActor
final class HangVideoTests: XCTestCase {
    func testImportCreatesPlayablePortraitVideoAndPosterWithoutLocationMetadata() async throws {
        let original = try await makeVideo(seconds: 2)
        defer { try? FileManager.default.removeItem(at: original) }
        let source = try HangVideoSource.copy(from: original)
        // The importer must not depend on the lifetime of a Photos provider URL.
        try FileManager.default.removeItem(at: original)
        let video = try await HangVideoImporter.prepare(source)
        let asset = AVURLAsset(url: video.file.url)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        XCTAssertEqual(video.duration, 2, accuracy: 0.1)
        XCTAssertEqual(video.file.url.pathExtension, "mp4")
        let poster = try XCTUnwrap(UIImage(data: video.poster))
        XCTAssertGreaterThan(poster.size.height, poster.size.width)
        let metadata = try await asset.load(.metadata)
        XCTAssertFalse(metadata.contains { $0.identifier == .quickTimeMetadataLocationISO6709 })
    }

    func testRejectsLongAndUnreadableVideos() async throws {
        let original = try await makeVideo(seconds: 16)
        defer { try? FileManager.default.removeItem(at: original) }
        do {
            _ = try await HangVideoImporter.prepare(HangVideoSource.copy(from: original))
            XCTFail("A long video must not be attached")
        } catch HangVideoError.tooLong { }

        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        try Data("not a movie".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        do {
            _ = try await HangVideoImporter.prepare(HangVideoSource.copy(from: invalid))
            XCTFail("An unreadable video must not be attached")
        } catch { }
    }

    func testAcceptedClipSurvivesFailedReplacement() async throws {
        let attachment = HangVideoAttachment()
        let first = try placeholderVideo()
        attachment.prepare { first }
        try await finish(attachment)
        XCTAssertEqual(attachment.video?.id, first.id)

        attachment.prepare { throw HangVideoError.tooLong }
        try await finish(attachment)
        XCTAssertEqual(attachment.video?.id, first.id)
        XCTAssertNotNil(attachment.errorMessage)
    }

    func testCancellationCannotReplaceAcceptedClipWithLateResult() async throws {
        let attachment = HangVideoAttachment()
        let first = try placeholderVideo()
        attachment.prepare { first }
        try await finish(attachment)
        let late = try placeholderVideo()
        attachment.prepare {
            // Simulate a provider which finishes despite cancellation.
            try? await Task.sleep(for: .milliseconds(100))
            return late
        }
        attachment.cancelImport()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(attachment.video?.id, first.id)
        XCTAssertFalse(attachment.isPreparing)
    }

    func testPostedHangRetainsClipUntilHangAndDraftAreReleased() async throws {
        let attachment = HangVideoAttachment()
        var video: HangVideo? = try placeholderVideo()
        let url = try XCTUnwrap(video?.file.url)
        attachment.prepare { [clip = video!] in clip }
        try await finish(attachment)
        var hang = Signal.mock[0]
        hang.video = attachment.video
        video = nil
        attachment.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        hang.video = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func finish(_ attachment: HangVideoAttachment) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while attachment.isPreparing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(attachment.isPreparing, "Video preparation did not finish")
    }

    private func placeholderVideo() throws -> HangVideo {
        try FileManager.default.createDirectory(at: HangVideoFile.directory, withIntermediateDirectories: true)
        let file = HangVideoFile(url: HangVideoFile.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4"))
        try Data().write(to: file.url)
        return HangVideo(file: file, poster: Data(), duration: 2)
    }

    private func makeVideo(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.value = "+37.0000-122.0000/" as NSString
        writer.metadata = [location]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 180, AVVideoHeightKey: 320,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 180, kCVPixelBufferHeightKey as String: 320,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? HangVideoError.exportFailed }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
            let frame = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(frame, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(frame), width: 180, height: 320,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(frame),
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor(UIColor(red: 0.45 + Double(index % 10) * 0.02, green: 0.3, blue: 0.55, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 180, height: 320))
            CVPixelBufferUnlockBaseAddress(frame, [])
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(seconds), timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? HangVideoError.exportFailed }
        return url
    }
}

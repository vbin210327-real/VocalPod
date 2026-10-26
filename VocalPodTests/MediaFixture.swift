import AVFoundation
import CoreVideo
import Foundation

/// A tiny, generated movie exercises the real import pipeline without shipping demo media.
enum MediaFixture {
    static let duration: TimeInterval = 1.5

    static func makeMovie(in directory: URL, includeAudio: Bool = true) async throws -> URL {
        let videoURL = directory.appendingPathComponent("silent-\(UUID().uuidString).mov")
        try await writeSilentVideo(to: videoURL)
        guard includeAudio else { return videoURL }

        let audioURL = directory.appendingPathComponent("tone-\(UUID().uuidString).wav")
        try sineWave().write(to: audioURL)
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw FixtureError.missingTrack }
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        let movieURL = directory.appendingPathComponent("recording-\(UUID().uuidString).mov")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw FixtureError.cannotExport }
        try await exporter.export(to: movieURL, as: .mov)
        try FileManager.default.removeItem(at: videoURL)
        try FileManager.default.removeItem(at: audioURL)
        return movieURL
    }

    private static func writeSilentVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 32,
            AVVideoHeightKey: 32
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32,
            kCVPixelBufferHeightKey as String: 32
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.cannotExport }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<45 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline else { throw FixtureError.writerTimeout }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { throw FixtureError.cannotAllocate }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, frame % 2 == 0 ? 64 : 96, CVPixelBufferGetBytesPerRow(buffer) * 32)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
            else { throw writer.error ?? FixtureError.cannotExport }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureError.cannotExport }
    }

    private static func sineWave() -> Data {
        let sampleRate: UInt32 = 44_100
        let frameCount = Int(Double(sampleRate) * duration)
        let byteCount = UInt32(frameCount * 2)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(byteCount + 36)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(byteCount)
        for frame in 0..<frameCount {
            let sample = Int16(sin(Double(frame) * 2 * .pi * 440 / Double(sampleRate)) * 8_000)
            append(sample)
        }
        return data
    }

    private enum FixtureError: Error {
        case missingTrack, cannotExport, cannotAllocate, writerTimeout
    }
}

import AVFoundation
import Foundation

enum AudioImportError: LocalizedError {
    case noAudio
    case unsupportedVideo
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .noAudio:
            return "这段录屏没有音轨。请确认录屏时已录入声音，再试一次。"
        case .unsupportedVideo:
            return "暂时无法读取这段视频，请换一段录屏试试。"
        case .emptyAudio:
            return "没有提取到可播放的声音，请换一段录屏试试。"
        }
    }
}

enum AudioImporter {
    /// Writes only an M4A audio file. The caller retains ownership of the source video.
    static func extractAudio(from sourceURL: URL, to outputURL: URL) async throws -> TimeInterval {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        guard sourceURL.standardizedFileURL != outputURL.standardizedFileURL,
              !fileManager.fileExists(atPath: outputURL.path) else {
            throw AudioImportError.unsupportedVideo
        }

        var completed = false
        defer {
            if !completed { try? fileManager.removeItem(at: outputURL) }
        }

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioImportError.noAudio }
        let sourceDuration = try await asset.load(.duration)
        guard sourceDuration.seconds.isFinite, sourceDuration.seconds > 0 else {
            throw AudioImportError.emptyAudio
        }

        // Screen recordings can contain separate microphone and app-audio tracks.
        // Preserve their timing and include both, without decoding or copying video.
        let composition = AVMutableComposition()
        var mixInputs: [AVMutableAudioMixInputParameters] = []
        for track in tracks {
            try Task.checkCancellation()
            let range = try await track.load(.timeRange)
            guard range.duration.seconds.isFinite, range.duration.seconds > 0,
                  let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            try compositionTrack.insertTimeRange(range, of: track, at: range.start)
            let input = AVMutableAudioMixInputParameters(track: compositionTrack)
            input.setVolume(1, at: .zero)
            mixInputs.append(input)
        }
        guard !mixInputs.isEmpty else { throw AudioImportError.emptyAudio }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioImportError.unsupportedVideo
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixInputs
        exporter.audioMix = mix
        try Task.checkCancellation()
        try await exporter.export(to: outputURL, as: .m4a)
        try Task.checkCancellation()

        let exportedAsset = AVURLAsset(url: outputURL)
        let duration = try await exportedAsset.load(.duration).seconds
        let exportedTracks = try await exportedAsset.loadTracks(withMediaType: .audio)
        let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard duration.isFinite, duration > 0, !exportedTracks.isEmpty, size > 0 else {
            throw AudioImportError.emptyAudio
        }
        completed = true
        return duration
    }
}

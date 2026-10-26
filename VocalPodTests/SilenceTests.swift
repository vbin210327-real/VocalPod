import AVFoundation
import MediaPlayer
import XCTest
@testable import VocalPod

@MainActor
final class SilenceTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("VocalPodSilenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot { try FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
    }

    func testMonoCAFTrimsOnlyOuterSilenceAndKeepsQuietEdgesAndInternalPause() async throws {
        let source = try SilenceFixture.makeAudio(in: temporaryRoot, duration: 5.2, format: .caf, segments: [
            .init(start: 1, end: 1.15, amplitude: 0.0003),
            .init(start: 1.15, end: 2.1, amplitude: 0.12),
            .init(start: 3.2, end: 4, amplitude: 0.12),
            .init(start: 4, end: 4.15, amplitude: 0.0003)
        ])

        let bounds = try await SilenceAnalyzer.analyze(url: source)

        XCTAssertGreaterThan(bounds.start, 0.7)
        XCTAssertLessThan(bounds.start, 0.98, "Keep a safety margin before the first quiet syllable.")
        XCTAssertGreaterThan(bounds.end, 4.17, "Keep a safety margin after the final quiet syllable.")
        XCTAssertLessThan(bounds.end, 4.5)
        XCTAssertLessThan(bounds.start, 1)
        XCTAssertGreaterThan(bounds.end, 4.15)
        XCTAssertGreaterThan(bounds.end - bounds.start, 3.2, "The 1.1-second internal pause belongs to the retained interval.")
    }

    func testStereoWAVDetectsQuietSoundInOnlyOneChannel() async throws {
        let source = try SilenceFixture.makeAudio(in: temporaryRoot, duration: 4, channels: 2, format: .wav, segments: [
            .init(start: 1, end: 3, amplitude: 0.0003, channel: 1)
        ])

        let bounds = try await SilenceAnalyzer.analyze(url: source, duration: 4)

        XCTAssertGreaterThan(bounds.start, 0.7)
        XCTAssertLessThan(bounds.start, 0.98)
        XCTAssertGreaterThan(bounds.end, 3.02)
        XCTAssertLessThan(bounds.end, 3.4)
    }

    func testVeryQuietMeaningfulAudioIsRetained() async throws {
        let source = try SilenceFixture.makeAudio(in: temporaryRoot, duration: 4, format: .caf, segments: [
            .init(start: 0.8, end: 1.1, amplitude: 0.0001),
            .init(start: 1.1, end: 2.7, amplitude: 0.08),
            .init(start: 2.7, end: 3, amplitude: 0.0001)
        ])

        let bounds = try await SilenceAnalyzer.analyze(url: source)

        XCTAssertLessThan(bounds.start, 0.8, "A quiet onset must not be cut because the middle is louder.")
        XCTAssertGreaterThan(bounds.end, 3, "A quiet ending must not be mistaken for trailing silence.")
        XCTAssertGreaterThan(bounds.start, 0.4)
        XCTAssertLessThan(bounds.end, 3.4)
    }

    func testOppositePhaseStereoChannelsDoNotCancelDetection() async throws {
        let source = try SilenceFixture.makeAudio(in: temporaryRoot, duration: 4, channels: 2, format: .wav, segments: [
            .init(start: 1, end: 3, amplitude: 0.02, channel: 0),
            .init(start: 1, end: 3, amplitude: -0.02, channel: 1)
        ])

        let bounds = try await SilenceAnalyzer.analyze(url: source)

        XCTAssertGreaterThan(bounds.start, 0.7)
        XCTAssertLessThan(bounds.start, 0.98)
        XCTAssertGreaterThan(bounds.end, 3.02)
        XCTAssertLessThan(bounds.end, 3.4)
    }

    func testFullySilentAudioKeepsItsFullRange() async throws {
        let source = try SilenceFixture.makeAudio(in: temporaryRoot, duration: 4, format: .caf, segments: [])

        let bounds = try await SilenceAnalyzer.analyze(url: source)

        XCTAssertEqual(bounds.start, 0, accuracy: 0.001)
        XCTAssertEqual(bounds.end, 4, accuracy: 0.02)
    }

    func testCancelledAnalysisPropagatesCancellation() async throws {
        let source = try SilenceFixture.makeAudio(in: temporaryRoot, duration: 4, format: .caf, segments: [
            .init(start: 1, end: 3, amplitude: 0.12)
        ])
        let analysis = Task { try await SilenceAnalyzer.analyze(url: source) }
        analysis.cancel()
        do {
            _ = try await analysis.value
            XCTFail("A cancelled analysis must not continue decoding media.")
        } catch is CancellationError { }
    }

    func testLegacyClipJSONDecodesWithoutSilenceFields() throws {
        let id = UUID()
        let original: [String: Any] = [
            "id": id.uuidString, "title": "旧声音", "fileName": "\(id.uuidString).m4a", "duration": 6.0, "createdAt": 0.0
        ]

        let clip = try JSONDecoder().decode(AudioClip.self, from: JSONSerialization.data(withJSONObject: original))

        XCTAssertNil(clip.soundBounds)
        XCTAssertNil(clip.autoTrimEnabled)
        XCTAssertTrue(clip.isAutoTrimEnabled)
        XCTAssertEqual(clip.playbackStart, 0)
        XCTAssertEqual(clip.playbackEnd, 6)
        XCTAssertEqual(clip.playbackDuration, 6)
        XCTAssertEqual(clip.trimmedSilenceDuration, 0)
    }

    func testInvalidSoundBoundsFallBackToOriginalRange() {
        let clip = AudioClip(title: "边界验证", fileName: "test.wav", duration: 6,
                             soundBounds: AudioBounds(start: 4, end: 1))
        XCTAssertEqual(clip.playbackStart, 0)
        XCTAssertEqual(clip.playbackEnd, 6)
        XCTAssertEqual(clip.playbackDuration, 6)
        XCTAssertEqual(clip.trimmedSilenceDuration, 0)
    }

    func testCachedBoundsAndTogglePersistWithoutRewritingOriginalAudio() async throws {
        let source = try SilenceFixture.makeAudio(in: temporaryRoot, duration: 6, format: .caf, segments: [
            .init(start: 1, end: 5, amplitude: 0.12)
        ])
        let libraryRoot = temporaryRoot.appendingPathComponent("Library", isDirectory: true)
        let library = LibraryStore(rootDirectory: libraryRoot)
        let imported = try await library.importVideo(at: source, suggestedName: "静音检测")
        let audioURL = library.fileURL(for: imported)
        let originalBytes = try Data(contentsOf: audioURL)

        let analyzed = try await library.analyzeSilence(for: imported)
        let bounds = try XCTUnwrap(analyzed.soundBounds)
        XCTAssertGreaterThan(bounds.start, 0.5)
        XCTAssertLessThan(bounds.end, analyzed.duration - 0.5)
        XCTAssertEqual(try Data(contentsOf: audioURL), originalBytes)

        let relaunched = LibraryStore(rootDirectory: libraryRoot)
        XCTAssertNil(relaunched.loadError)
        let persisted = try XCTUnwrap(relaunched.clips.first)
        XCTAssertEqual(persisted.soundBounds, bounds)

        // A cached request must not decode the audio file again.
        let temporarilyMoved = temporaryRoot.appendingPathComponent("cached-audio.m4a")
        try FileManager.default.moveItem(at: audioURL, to: temporarilyMoved)
        let cached = try await relaunched.analyzeSilence(for: persisted)
        try FileManager.default.moveItem(at: temporarilyMoved, to: audioURL)
        XCTAssertEqual(cached.soundBounds, bounds)

        let disabled = try relaunched.setAutoTrim(cached, enabled: false)
        XCTAssertFalse(disabled.isAutoTrimEnabled)
        XCTAssertEqual(disabled.playbackStart, 0)
        XCTAssertEqual(disabled.playbackEnd, disabled.duration)
        XCTAssertEqual(disabled.soundBounds, bounds, "Turning the feature off keeps its cached analysis.")
        let persistedDisabled = try XCTUnwrap(LibraryStore(rootDirectory: libraryRoot).clips.first)
        XCTAssertFalse(persistedDisabled.isAutoTrimEnabled)
        XCTAssertEqual(persistedDisabled.soundBounds, bounds)

        let enabled = try relaunched.setAutoTrim(disabled, enabled: true)
        XCTAssertTrue(enabled.isAutoTrimEnabled)
        XCTAssertEqual(enabled.playbackStart, bounds.start, accuracy: 0.001)
        XCTAssertEqual(enabled.playbackEnd, bounds.end, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(LibraryStore(rootDirectory: libraryRoot).clips.first).isAutoTrimEnabled)
        XCTAssertEqual(try Data(contentsOf: audioURL), originalBytes, "The feature changes playback metadata, never the original M4A.")
        let files = try FileManager.default.contentsOfDirectory(at: audioURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent), [audioURL.lastPathComponent], "Do not create another rendered audio copy.")
    }

    func testAutomaticTrimmingMigrationEnablesLegacyFalseWithoutChangingAudioOrOtherMetadata() async throws {
        let source = try SilenceFixture.makeAudio(in: temporaryRoot, duration: 2, format: .caf, segments: [
            .init(start: 0.4, end: 1.6, amplitude: 0.12)
        ])
        let libraryRoot = temporaryRoot.appendingPathComponent("Library", isDirectory: true)
        let originalLibrary = LibraryStore(rootDirectory: libraryRoot)
        let disabled = try await originalLibrary.importVideo(at: source, suggestedName: "旧版已关闭")
        _ = try await originalLibrary.importVideo(at: source, suggestedName: "默认开启")
        let enabled = try await originalLibrary.importVideo(at: source, suggestedName: "明确开启")
        _ = try originalLibrary.setAutoTrim(disabled, enabled: false)
        _ = try originalLibrary.setAutoTrim(enabled, enabled: true)

        let upgradedLibrary = LibraryStore(rootDirectory: libraryRoot)
        XCTAssertNil(upgradedLibrary.loadError)
        let before = upgradedLibrary.clips
        var audioBytes: [UUID: Data] = [:]
        for clip in before { audioBytes[clip.id] = try Data(contentsOf: upgradedLibrary.fileURL(for: clip)) }
        let expected = before.map { clip in
            var migrated = clip
            if migrated.autoTrimEnabled == false { migrated.autoTrimEnabled = true }
            return migrated
        }

        try upgradedLibrary.enableAutomaticTrimming()

        XCTAssertEqual(upgradedLibrary.clips, expected, "Only an explicitly disabled flag should change.")
        XCTAssertEqual(upgradedLibrary.clips.filter { $0.autoTrimEnabled == nil }.count, 1,
                       "Default-on records must keep their existing nil metadata.")
        let relaunched = LibraryStore(rootDirectory: libraryRoot)
        XCTAssertNil(relaunched.loadError)
        XCTAssertEqual(relaunched.clips, expected, "Migration must survive the next app launch.")
        for clip in relaunched.clips {
            XCTAssertEqual(try Data(contentsOf: relaunched.fileURL(for: clip)), try XCTUnwrap(audioBytes[clip.id]),
                           "Enabling playback trimming must never rewrite the original audio.")
        }
        let indexURL = libraryRoot.appendingPathComponent("library.json")
        let migratedIndex = try Data(contentsOf: indexURL)
        try relaunched.enableAutomaticTrimming()
        XCTAssertEqual(try Data(contentsOf: indexURL), migratedIndex, "A repeated startup migration must leave the stored metadata unchanged.")
        let files = try FileManager.default.contentsOfDirectory(at: libraryRoot.appendingPathComponent("Audio"), includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(before.map(\.fileName)), "Migration must not create rendered audio copies.")
    }

    func testPlayerTimelineAndSeekingAreRelativeToEffectiveRange() async throws {
        let (source, clip) = try playerFixture()
        let player = AudioPlayer()
        defer { player.stop() }
        player.play(clip, url: source)
        XCTAssertEqual(player.duration, 2, accuracy: 0.001)
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        player.pause()
        player.seek(to: 0.6)
        try await waitUntil { abs(player.currentTime - 0.6) < 0.1 }
        let metadata = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(try XCTUnwrap(metadata[MPMediaItemPropertyPlaybackDuration] as? Double), 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double), 0.6, accuracy: 0.15)
        XCTAssertFalse(player.isPlaying)
    }

    func testPlayerLoopsAtTrimEndWithoutPlayingTrailingSilence() async throws {
        let (source, clip) = try playerFixture()
        let player = AudioPlayer()
        defer { player.stop() }
        player.setLoopEnabled(true)
        player.play(clip, url: source)
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        player.seek(to: 1.8)
        try await waitUntil { player.currentTime > 1.7 }
        try await waitUntil(timeout: 1) { player.currentTime < 0.5 && player.isPlaying }
    }

    func testPlayerStopsAtTrimEndWithLoopDisabled() async throws {
        let (source, clip) = try playerFixture()
        let player = AudioPlayer()
        defer { player.stop() }
        player.setLoopEnabled(false)
        player.play(clip, url: source)
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        player.seek(to: 1.8)
        try await waitUntil(timeout: 1) { !player.isPlaying }
        XCTAssertEqual(player.currentTime, 2, accuracy: 0.1)
    }

    func testChangingTrimKeepsAbsolutePositionAndPausedState() async throws {
        let (source, clip) = try playerFixture()
        let player = AudioPlayer()
        defer { player.stop() }
        player.play(clip, url: source)
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        player.pause()
        player.seek(to: 0.7)
        var fullClip = clip
        fullClip.autoTrimEnabled = false

        player.updateClip(fullClip)
        XCTAssertEqual(player.duration, 6, accuracy: 0.001)
        try await waitUntil { abs(player.currentTime - 1.7) < 0.1 }
        XCTAssertFalse(player.isPlaying, "Changing a playback setting must not resume paused audio.")

        player.updateClip(clip)
        XCTAssertEqual(player.duration, 2, accuracy: 0.001)
        try await waitUntil { abs(player.currentTime - 0.7) < 0.1 }
        XCTAssertFalse(player.isPlaying)
    }

    private func playerFixture() throws -> (URL, AudioClip) {
        let source = try SilenceFixture.makeAudio(in: temporaryRoot, duration: 6, format: .wav, segments: [
            .init(start: 1, end: 3, amplitude: 0.12)
        ])
        let clip = AudioClip(title: "首尾静音播放验证", fileName: source.lastPathComponent, duration: 6,
                             soundBounds: AudioBounds(start: 1, end: 3), autoTrimEnabled: true)
        return (source, clip)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Playback did not reach the expected trimmed state within \(timeout) seconds.")
                throw VerificationError.timeout
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum VerificationError: Error { case timeout }
}

private enum SilenceFixture {
    enum Format: String { case caf, wav }

    struct Segment {
        let start: Double
        let end: Double
        let amplitude: Float
        var channel = 0
    }

    static func makeAudio(in directory: URL, duration: Double, channels: Int = 1, format: Format, segments: [Segment]) throws -> URL {
        let sampleRate = 22_050
        let frameCount = Int(duration * Double(sampleRate))
        var samples = Array(repeating: Array(repeating: Float.zero, count: frameCount), count: channels)
        for segment in segments {
            for frame in max(0, Int(segment.start * Double(sampleRate)))..<min(frameCount, Int(segment.end * Double(sampleRate))) {
                samples[segment.channel][frame] = sin(Float(frame) * 2 * .pi * 330 / Float(sampleRate)) * segment.amplitude
            }
        }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(format.rawValue)
        switch format {
        case .caf:
            let audioFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels))!
            let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(frameCount))!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<channels {
                for frame in 0..<frameCount { buffer.floatChannelData![channel][frame] = samples[channel][frame] }
            }
            let file = try AVAudioFile(forWriting: url, settings: audioFormat.settings)
            try file.write(from: buffer)
        case .wav:
            var data = Data()
            func append<T: FixedWidthInteger>(_ value: T) {
                var littleEndian = value.littleEndian
                withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
            }
            let byteCount = UInt32(frameCount * channels * 2)
            data.append(contentsOf: "RIFF".utf8)
            append(byteCount + 36)
            data.append(contentsOf: "WAVEfmt ".utf8)
            append(UInt32(16))
            append(UInt16(1))
            append(UInt16(channels))
            append(UInt32(sampleRate))
            append(UInt32(sampleRate * channels * 2))
            append(UInt16(channels * 2))
            append(UInt16(16))
            data.append(contentsOf: "data".utf8)
            append(byteCount)
            for frame in 0..<frameCount {
                for channel in 0..<channels { append(Int16(samples[channel][frame] * 32_767)) }
            }
            try data.write(to: url)
        }
        return url
    }
}

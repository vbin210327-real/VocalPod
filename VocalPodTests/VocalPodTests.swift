import AVFoundation
import XCTest
@testable import VocalPod

@MainActor
final class VocalPodTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("VocalPodTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot, FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
    }

    func testExtractsAudioOnlyWithOriginalDurationAndPlayableSamples() async throws {
        let source = try await MediaFixture.makeMovie(in: temporaryRoot)
        let output = temporaryRoot.appendingPathComponent("extracted.m4a")

        let duration = try await AudioImporter.extractAudio(from: source, to: output)

        XCTAssertEqual(duration, MediaFixture.duration, accuracy: 0.15)
        let exported = AVURLAsset(url: output)
        let audioTracks = try await exported.loadTracks(withMediaType: .audio)
        let videoTracks = try await exported.loadTracks(withMediaType: .video)
        let exportedDuration = try await exported.load(.duration).seconds
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertTrue(videoTracks.isEmpty, "The saved asset must contain audio only, not the original recording.")
        XCTAssertEqual(exportedDuration, MediaFixture.duration, accuracy: 0.15)

        let decoded = try AVAudioFile(forReading: output)
        XCTAssertGreaterThan(decoded.length, 40_000, "The M4A must contain decodable samples.")
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 1_024))
        try decoded.read(into: samples)
        let channel = try XCTUnwrap(samples.floatChannelData?[0])
        XCTAssertGreaterThan((0..<Int(samples.frameLength)).map { abs(channel[$0]) }.max() ?? 0, 0.01,
                             "A silent placeholder must not pass extraction validation.")
    }

    func testVideoWithoutAudioFailsWithoutLeavingOutput() async throws {
        let source = try await MediaFixture.makeMovie(in: temporaryRoot, includeAudio: false)
        let output = temporaryRoot.appendingPathComponent("should-not-exist.m4a")
        do {
            _ = try await AudioImporter.extractAudio(from: source, to: output)
            XCTFail("Importing a silent video should report that it has no audio track.")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testMalformedInputFailsWithoutLeavingOutput() async throws {
        let source = temporaryRoot.appendingPathComponent("invalid.mov")
        try Data("This is not a movie".utf8).write(to: source)
        let output = temporaryRoot.appendingPathComponent("should-not-exist.m4a")
        do {
            _ = try await AudioImporter.extractAudio(from: source, to: output)
            XCTFail("An invalid input must not create a library item.")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testLibraryImportRenameRelaunchAndDeletePersist() async throws {
        let source = try await MediaFixture.makeMovie(in: temporaryRoot)
        let libraryRoot = temporaryRoot.appendingPathComponent("Library", isDirectory: true)
        let library = LibraryStore(rootDirectory: libraryRoot)
        XCTAssertNil(library.loadError)

        let clip = try await library.importVideo(at: source, suggestedName: "测试录屏")

        XCTAssertEqual(library.clips.count, 1)
        XCTAssertFalse(library.isImporting)
        XCTAssertEqual(clip.duration, MediaFixture.duration, accuracy: 0.15)
        let savedAudio = library.fileURL(for: clip)
        XCTAssertEqual(savedAudio.pathExtension, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Import must preserve the selected source.")

        try library.rename(clip, to: "听力练习")
        let relaunched = LibraryStore(rootDirectory: libraryRoot)
        XCTAssertNil(relaunched.loadError)
        XCTAssertEqual(relaunched.clips.count, 1)
        let renamed = try XCTUnwrap(relaunched.clips.first)
        XCTAssertEqual(renamed.id, clip.id)
        XCTAssertEqual(renamed.title, "听力练习")
        XCTAssertEqual(relaunched.fileURL(for: renamed), savedAudio)

        try relaunched.delete(renamed)
        XCTAssertTrue(relaunched.clips.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: savedAudio.path))
        XCTAssertTrue(LibraryStore(rootDirectory: libraryRoot).clips.isEmpty)
        let audioContents = try FileManager.default.contentsOfDirectory(at: libraryRoot.appendingPathComponent("Audio"), includingPropertiesForKeys: nil)
        XCTAssertTrue(audioContents.isEmpty, "Deleting a clip must also free its saved audio file.")
    }

    func testLibraryReorderPersistsWithoutChangingAudioAndNewImportsPrepend() async throws {
        let source = try await MediaFixture.makeMovie(in: temporaryRoot)
        let root = temporaryRoot.appendingPathComponent("Library", isDirectory: true)
        let library = LibraryStore(rootDirectory: root)
        for title in ["A", "B", "C"] { _ = try await library.importVideo(at: source, suggestedName: title) }
        let original = library.clips
        let audio = try Dictionary(uniqueKeysWithValues: original.map { ($0.id, try Data(contentsOf: library.fileURL(for: $0))) })
        try library.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let expected = [original[2], original[0], original[1]]
        XCTAssertEqual(library.clips, expected)
        let relaunched = LibraryStore(rootDirectory: root)
        XCTAssertEqual(relaunched.clips, expected, "Creation dates must not override the saved custom order.")
        for clip in relaunched.clips {
            XCTAssertEqual(try Data(contentsOf: relaunched.fileURL(for: clip)), audio[clip.id])
        }
        let index = root.appendingPathComponent("library.json")
        let unchangedIndex = try Data(contentsOf: index)
        try relaunched.move(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        XCTAssertEqual(try Data(contentsOf: index), unchangedIndex, "A no-op drag must not rewrite metadata.")
        XCTAssertThrowsError(try relaunched.move(fromOffsets: IndexSet(integer: 0), toOffset: 99))
        XCTAssertEqual(relaunched.clips, expected)
        let newest = try await relaunched.importVideo(at: source, suggestedName: "D")
        XCTAssertEqual(relaunched.clips, [newest] + expected)
        XCTAssertEqual(LibraryStore(rootDirectory: root).clips, [newest] + expected)
    }

    func testFailedLibraryImportDoesNotPersistClipOrPartialAudio() async throws {
        let source = try await MediaFixture.makeMovie(in: temporaryRoot, includeAudio: false)
        let libraryRoot = temporaryRoot.appendingPathComponent("Library", isDirectory: true)
        let library = LibraryStore(rootDirectory: libraryRoot)
        do {
            _ = try await library.importVideo(at: source, suggestedName: "无声音")
            XCTFail("A movie with no audio must not be added to the library.")
        } catch {
            XCTAssertFalse(library.isImporting)
        }
        XCTAssertTrue(library.clips.isEmpty)
        XCTAssertTrue(LibraryStore(rootDirectory: libraryRoot).clips.isEmpty)
        let audioContents = try FileManager.default.contentsOfDirectory(at: libraryRoot.appendingPathComponent("Audio"), includingPropertiesForKeys: nil)
        XCTAssertTrue(audioContents.isEmpty)
    }

    func testCorruptLibraryIsReportedAndPreserved() async throws {
        let libraryRoot = temporaryRoot.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let index = libraryRoot.appendingPathComponent("library.json")
        let original = Data("preserve this invalid index".utf8)
        try original.write(to: index)
        let library = LibraryStore(rootDirectory: libraryRoot)
        XCTAssertNotNil(library.loadError)
        let source = try await MediaFixture.makeMovie(in: temporaryRoot)
        do {
            _ = try await library.importVideo(at: source, suggestedName: "录屏")
            XCTFail("Import must not silently overwrite a corrupt existing library.")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: index), original)
    }

    func testPlayerAcceptsCustomRateLoopAndSeekAndStopsCleanly() async throws {
        let source = try await MediaFixture.makeMovie(in: temporaryRoot)
        let output = temporaryRoot.appendingPathComponent("playback.m4a")
        let duration = try await AudioImporter.extractAudio(from: source, to: output)
        let clip = AudioClip(title: "播放验证", fileName: output.lastPathComponent, duration: duration)
        let player = AudioPlayer()
        defer { player.stop() }

        player.setRate(1.65)
        player.setLoopEnabled(false)
        player.play(clip, url: output)
        XCTAssertEqual(player.currentClip?.id, clip.id)
        XCTAssertEqual(player.rate, 1.65, accuracy: 0.001)
        XCTAssertFalse(player.loopEnabled)
        XCTAssertEqual(player.duration, duration, accuracy: 0.15)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("audio"))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }

        player.pause()
        XCTAssertFalse(player.isPlaying)
        player.seek(to: 0.5)
        try await waitUntil { abs(player.currentTime - 0.5) < 0.15 }

        player.stop()
        XCTAssertNil(player.currentClip)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0, accuracy: 0.001)
    }

    func testPlayerReplaysAfterEndWhenLoopIsEnabled() async throws {
        let source = try await MediaFixture.makeMovie(in: temporaryRoot)
        let output = temporaryRoot.appendingPathComponent("loop.m4a")
        let duration = try await AudioImporter.extractAudio(from: source, to: output)
        let clip = AudioClip(title: "循环验证", fileName: output.lastPathComponent, duration: duration)
        let player = AudioPlayer()
        defer { player.stop() }
        player.setLoopEnabled(true)
        player.play(clip, url: output)
        try await waitUntil { player.currentTime > 0.1 }
        player.seek(to: max(0, duration - 0.15))
        try await waitUntil { player.currentTime > duration - 0.3 }
        try await waitUntil { player.currentTime < 0.8 && player.isPlaying }
        XCTAssertTrue(player.loopEnabled)
    }

    func testPlayerStopsAtEndWhenLoopIsDisabled() async throws {
        let source = try await MediaFixture.makeMovie(in: temporaryRoot)
        let output = temporaryRoot.appendingPathComponent("once.m4a")
        let duration = try await AudioImporter.extractAudio(from: source, to: output)
        let clip = AudioClip(title: "单次播放验证", fileName: output.lastPathComponent, duration: duration)
        let player = AudioPlayer()
        defer { player.stop() }
        player.setLoopEnabled(false)
        player.play(clip, url: output)
        try await waitUntil { player.currentTime > 0.1 }
        player.seek(to: max(0, duration - 0.15))
        try await waitUntil { !player.isPlaying }
        XCTAssertFalse(player.loopEnabled)
    }

    func testPlayerBoundsRatesAndRejectsNonFiniteValues() {
        let player = AudioPlayer()
        player.setRate(12)
        XCTAssertEqual(player.rate, 3)
        player.setRate(-4)
        XCTAssertEqual(player.rate, 0.25)
        player.setRate(1.65)
        player.setRate(.nan)
        XCTAssertEqual(player.rate, 1.65, accuracy: 0.001)
        player.setRate(.infinity)
        XCTAssertEqual(player.rate, 1.65, accuracy: 0.001)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Playback did not reach the expected state within \(timeout) seconds.")
                throw VerificationError.timeout
            }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private enum VerificationError: Error { case timeout }
}

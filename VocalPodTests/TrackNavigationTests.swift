import AVFoundation
import MediaPlayer
import XCTest
@testable import VocalPod

@MainActor
final class TrackNavigationTests: XCTestCase {
    private var directory: URL!
    private var source: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VocalPod-Tracks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("fixture.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050 * 4)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = frame >= 11_025 && frame < 77_175
                ? sin(Float(frame) * 2 * .pi * 330 / 22_050) * 0.1 : 0
        }
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        try file.write(from: buffer)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testNowPlayingUsesTrackCommandsAndReportsQueuePosition() async throws {
        let library = try await makeLibrary(count: 3)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.play(library.clips[1], url: library.fileURL(for: library.clips[1]))
        try await waitUntil { player.isPlaying }

        let commands = MPRemoteCommandCenter.shared()
        XCTAssertTrue(commands.previousTrackCommand.isEnabled)
        XCTAssertTrue(commands.nextTrackCommand.isEnabled)
        XCTAssertFalse(commands.skipBackwardCommand.isEnabled)
        XCTAssertFalse(commands.skipForwardCommand.isEnabled)
        let info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual((info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? NSNumber)?.intValue, 3)
    }

    func testNextAndPreviousSelectAudioInLibraryOrderAndKeepSettings() async throws {
        let library = try await makeLibrary(count: 3)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setRate(1.65)
        player.setLoopEnabled(false)
        player.play(library.clips[1], url: library.fileURL(for: library.clips[1]))
        try await waitUntil { player.isPlaying && player.currentTime > 0.1 }

        player.playNextTrack()
        try await waitUntil { player.currentClip?.id == library.clips[2].id && player.isPlaying && player.currentTime > 0.1 }
        XCTAssertEqual(player.rate, 1.65, accuracy: 0.001)
        XCTAssertFalse(player.loopEnabled)
        XCTAssertEqual(player.duration, library.clips[2].playbackDuration, accuracy: 0.01)
        XCTAssertFalse(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)

        player.playPreviousTrack()
        try await waitUntil { player.currentClip?.id == library.clips[1].id && player.isPlaying && player.currentTime > 0.1 }
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, library.clips[1].title)
    }

    func testQueueEdgesSingleTrackAndStoppedStateHaveNoInvalidNavigation() async throws {
        let library = try await makeLibrary(count: 1)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        let clip = library.clips[0]
        player.play(clip, url: library.fileURL(for: clip))
        try await waitUntil { player.isPlaying }
        XCTAssertFalse(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        XCTAssertFalse(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled)
        player.playNextTrack()
        player.playPreviousTrack()
        XCTAssertEqual(player.currentClip?.id, clip.id)
        player.stop()
        XCTAssertFalse(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        XCTAssertFalse(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled)
    }

    func testRapidNextCommandsAdvanceFromPendingTrackAndPauseCancelsChange() async throws {
        let library = try await makeLibrary(count: 3)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.play(library.clips[0], url: library.fileURL(for: library.clips[0]))
        try await waitUntil { player.isPlaying }
        player.playNextTrack()
        player.playNextTrack()
        try await waitUntil { player.currentClip?.id == library.clips[2].id && player.isPlaying }

        player.playPreviousTrack()
        player.pause()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(player.currentClip?.id, library.clips[2].id)
        XCTAssertFalse(player.isPlaying)
    }

    func testLibraryChangesRefreshQueueAndDeletedCurrentTrackStops() async throws {
        let library = try await makeLibrary(count: 3)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        let current = library.clips[1]
        player.play(current, url: library.fileURL(for: current))
        try await waitUntil { player.isPlaying }
        try library.rename(current, to: "新的声音名称")
        try library.delete(library.clips[0])
        player.refreshLibrary()
        XCTAssertEqual(player.currentClip?.title, "新的声音名称")
        XCTAssertFalse(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled)
        XCTAssertTrue(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        try library.delete(current)
        player.refreshLibrary()
        XCTAssertNil(player.currentClip)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertFalse(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
    }

    func testChangingToLegacyTrackAnalyzesItsSilenceBeforePlayback() async throws {
        let library = try await makeLibrary(count: 2)
        let root = directory.appendingPathComponent("Library")
        var oldClips = library.clips
        for index in oldClips.indices { oldClips[index].soundBounds = nil }
        try JSONEncoder().encode(oldClips).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        let legacy = LibraryStore(rootDirectory: root)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(legacy)
        player.play(legacy.clips[0], url: legacy.fileURL(for: legacy.clips[0]))
        try await waitUntil { player.isPlaying }
        player.playNextTrack()
        try await waitUntil { player.currentClip?.id == legacy.clips[1].id && player.isPlaying && player.currentTime > 0.1 }
        XCTAssertNotNil(player.currentClip?.soundBounds)
        XCTAssertLessThan(player.duration, 3.6)
        XCTAssertNotNil(legacy.clips[1].soundBounds)
    }

    func testSequentialPlaybackCyclesThroughCustomOrderAndBackToFirstTrack() async throws {
        let library = try await makeLibrary(count: 3)
        try library.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setLoopEnabled(false)
        player.setRate(1.65)
        player.play(library.clips[0], url: library.fileURL(for: library.clips[0]))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }

        for index in 1..<library.clips.count {
            player.seek(to: player.duration - 0.18)
            try await waitUntil { player.currentClip?.id == library.clips[index].id && player.isPlaying && player.currentTime > 0.05 }
            XCTAssertEqual(player.rate, 1.65, accuracy: 0.001)
            XCTAssertFalse(player.loopEnabled)
            XCTAssertEqual(player.duration, library.clips[index].playbackDuration, accuracy: 0.01)
            XCTAssertLessThan(player.duration, library.clips[index].duration)
            let info = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
            XCTAssertEqual((info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? NSNumber)?.intValue, index)
        }
        player.seek(to: player.duration - 0.18)
        try await waitUntil { player.currentClip?.id == library.clips[0].id && player.isPlaying && player.currentTime > 0.05 }
        XCTAssertLessThan(player.currentTime, 1)
        XCTAssertEqual(player.rate, 1.65, accuracy: 0.001)
        XCTAssertFalse(player.loopEnabled)
        XCTAssertEqual(player.duration, library.clips[0].playbackDuration, accuracy: 0.01)
        XCTAssertEqual((MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? NSNumber)?.intValue, 0)
        XCTAssertTrue(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        player.seek(to: player.duration - 0.18)
        try await waitUntil { player.currentClip?.id == library.clips[1].id && player.isPlaying }
    }

    func testSequentialSingleClipRestartsAtTrimmedBeginning() async throws {
        let library = try await makeLibrary(count: 1)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setLoopEnabled(false)
        player.setRate(1.65)
        let clip = library.clips[0]
        player.play(clip, url: library.fileURL(for: clip))
        try await waitUntil { player.isPlaying && player.currentTime > 0.1 }
        for _ in 0..<2 {
            player.seek(to: player.duration - 0.18)
            try await waitUntil { player.isPlaying && player.currentTime > 0.05 && player.currentTime < 0.8 }
            XCTAssertEqual(player.currentClip?.id, clip.id)
            XCTAssertFalse(player.loopEnabled)
            XCTAssertEqual(player.rate, 1.65, accuracy: 0.001)
            XCTAssertEqual(player.duration, clip.playbackDuration, accuracy: 0.01)
            XCTAssertNil(player.errorMessage)
        }
    }

    func testMissingFirstClipAtQueueWrapPausesWithOneTapRecovery() async throws {
        let library = try await makeLibrary(count: 2)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setLoopEnabled(false)
        let last = library.clips[1]
        player.play(last, url: library.fileURL(for: last))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        try FileManager.default.removeItem(at: library.fileURL(for: library.clips[0]))
        player.seek(to: player.duration - 0.18)
        try await waitUntil { player.errorMessage != nil && !player.isPlaying }
        XCTAssertEqual(player.currentClip?.id, last.id)
        player.togglePlayPause()
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 && player.currentTime < 1 }
        XCTAssertNil(player.errorMessage)
    }

    func testRepeatOneDoesNotAdvanceEvenWhenAnotherTrackExists() async throws {
        let library = try await makeLibrary(count: 2)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.play(library.clips[0], url: library.fileURL(for: library.clips[0]))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        player.seek(to: player.duration - 0.18)
        try await waitUntil { player.currentTime < 0.5 && player.isPlaying }
        XCTAssertEqual(player.currentClip?.id, library.clips[0].id)
        XCTAssertTrue(player.loopEnabled)
    }

    func testPausedSeekToEndDoesNotAutomaticallyStartNextTrack() async throws {
        let library = try await makeLibrary(count: 2)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setLoopEnabled(false)
        player.play(library.clips[0], url: library.fileURL(for: library.clips[0]))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        player.pause()
        player.seek(to: player.duration)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(player.currentClip?.id, library.clips[0].id)
        XCTAssertFalse(player.isPlaying)
        player.togglePlayPause()
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 && player.currentTime < 1 }
        XCTAssertEqual(player.currentClip?.id, library.clips[0].id)
    }

    func testSequentialPlaybackAnalyzesLegacyNextTrackBeforeStarting() async throws {
        let library = try await makeLibrary(count: 2)
        let root = directory.appendingPathComponent("Library")
        var oldClips = library.clips
        oldClips[1].soundBounds = nil
        try JSONEncoder().encode(oldClips).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        let legacy = LibraryStore(rootDirectory: root)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(legacy)
        player.setLoopEnabled(false)
        player.play(legacy.clips[0], url: legacy.fileURL(for: legacy.clips[0]))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        player.seek(to: player.duration - 0.18)
        try await waitUntil { player.currentClip?.id == legacy.clips[1].id && player.isPlaying && player.currentTime > 0.05 }
        XCTAssertNotNil(legacy.clips[1].soundBounds)
        XCTAssertEqual(player.duration, legacy.clips[1].playbackDuration, accuracy: 0.01)
        XCTAssertLessThan(player.duration, 3.6)
    }

    func testMissingSequentialNextTrackStopsAndSinglePlayTapRecovers() async throws {
        let library = try await makeLibrary(count: 2)
        try FileManager.default.removeItem(at: library.fileURL(for: library.clips[1]))
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setLoopEnabled(false)
        player.play(library.clips[0], url: library.fileURL(for: library.clips[0]))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        player.seek(to: player.duration - 0.18)
        try await waitUntil { player.errorMessage != nil && !player.isPlaying }
        XCTAssertEqual(player.currentClip?.id, library.clips[0].id)
        player.togglePlayPause()
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 && player.currentTime < 1 }
        XCTAssertNil(player.errorMessage)
    }

    func testReorderingUpdatesQueueWithoutRestartingCurrentAudio() async throws {
        let library = try await makeLibrary(count: 3)
        let original = library.clips
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setLoopEnabled(false)
        player.setRate(1.65)
        player.play(original[1], url: library.fileURL(for: original[1]))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        player.pause()
        player.seek(to: 0.5)
        try await waitUntil { abs(player.currentTime - 0.5) < 0.1 }
        try library.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        player.refreshLibrary()
        XCTAssertEqual(player.currentClip?.id, original[1].id)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 0.5, accuracy: 0.1)
        XCTAssertFalse(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        XCTAssertEqual((MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? NSNumber)?.intValue, 2)
        try library.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        player.refreshLibrary()
        XCTAssertFalse(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled)
        XCTAssertTrue(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        player.togglePlayPause()
        try await waitUntil { player.isPlaying }
        player.seek(to: player.duration - 0.18)
        try await waitUntil { player.currentClip?.id == original[2].id && player.isPlaying }
        XCTAssertEqual(player.rate, 1.65, accuracy: 0.001)
    }

    func testShufflePlaysEveryTrackOncePerRoundAndKeepsLooping() async throws {
        let library = try await makeLibrary(count: 4)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setPlaybackMode(.shuffle)
        player.setRate(1.65)
        player.play(library.clips[0], url: library.fileURL(for: library.clips[0]))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        let expected = Set(library.clips.map(\.id))
        var round = Set([library.clips[0].id])
        for step in 1..<12 {
            let previous = try XCTUnwrap(player.currentClip?.id)
            player.seek(to: player.duration - 0.18)
            try await waitUntil { player.currentClip?.id != previous && player.isPlaying && player.currentTime > 0.05 }
            let current = try XCTUnwrap(player.currentClip?.id)
            if step % 4 == 0 { round = [] }
            XCTAssertTrue(round.insert(current).inserted, "A shuffle round must not repeat a track.")
            if step % 4 == 3 { XCTAssertEqual(round, expected) }
            XCTAssertEqual(player.playbackMode, .shuffle)
            XCTAssertEqual(player.rate, 1.65, accuracy: 0.001)
            XCTAssertEqual(player.duration, player.currentClip!.playbackDuration, accuracy: 0.01)
            XCTAssertTrue(MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled)
        }
    }

    func testShuffleManualPreviousAndNextBothFollowUnplayedRandomQueue() async throws {
        let library = try await makeLibrary(count: 3)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setPlaybackMode(.shuffle)
        let first = library.clips[0]
        player.play(first, url: library.fileURL(for: first))
        try await waitUntil { player.isPlaying }
        XCTAssertTrue(player.canPlayPreviousTrack)
        player.playNextTrack()
        try await waitUntil { player.currentClip?.id != first.id && player.isPlaying }
        let secondID = try XCTUnwrap(player.currentClip?.id)
        XCTAssertTrue(MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled)
        player.playPreviousTrack()
        try await waitUntil { player.currentClip?.id != secondID && player.isPlaying }
        XCTAssertTrue(player.canPlayPreviousTrack)
        let thirdID = try XCTUnwrap(player.currentClip?.id)
        XCTAssertNotEqual(thirdID, first.id, "Previous in shuffle must select another unplayed random track, not undo Next.")
        XCTAssertEqual(Set([first.id, secondID, thirdID]).count, 3)
    }

    func testRapidShuffleNextRequestsAdvancePastPendingSelection() async throws {
        let library = try await makeLibrary(count: 2)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setPlaybackMode(.shuffle)
        let first = library.clips[0]
        player.play(first, url: library.fileURL(for: first))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        player.seek(to: 0.8)
        try await waitUntil { abs(player.currentTime - 0.8) < 0.1 }
        player.playNextTrack()
        player.playNextTrack()
        // Two requests in a two-track shuffle must reach the original track
        // at its beginning, rather than resolve both taps to the pending other track.
        try await waitUntil { player.currentClip?.id != first.id || player.currentTime < 0.5 }
        XCTAssertEqual(player.currentClip?.id, first.id)
        XCTAssertLessThan(player.currentTime, 0.5)
        player.seek(to: 0.8)
        try await waitUntil { abs(player.currentTime - 0.8) < 0.1 }
        player.playPreviousTrack()
        player.playNextTrack()
        try await waitUntil { player.currentClip?.id != first.id || player.currentTime < 0.5 }
        XCTAssertEqual(player.currentClip?.id, first.id, "Mixed rapid buttons must also reserve two random selections.")
        XCTAssertLessThan(player.currentTime, 0.5)
    }

    func testShuffleSingleTrackRestartsAndPausedEndStaysPaused() async throws {
        let library = try await makeLibrary(count: 1)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setPlaybackMode(.shuffle)
        let clip = library.clips[0]
        player.play(clip, url: library.fileURL(for: clip))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        for _ in 0..<2 {
            player.seek(to: player.duration - 0.18)
            try await waitUntil { player.isPlaying && player.currentTime > 0.05 && player.currentTime < 0.8 }
            XCTAssertEqual(player.currentClip?.id, clip.id)
        }
        XCTAssertTrue(player.canPlayPreviousTrack)
        player.seek(to: 0.8)
        try await waitUntil { abs(player.currentTime - 0.8) < 0.1 }
        player.playPreviousTrack()
        try await waitUntil { player.currentTime < 0.5 }
        player.pause()
        player.seek(to: player.duration)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playbackMode, .shuffle)
    }

    func testShuffleQueueHandlesDeletionAndNewImportWithoutImmediateRepeat() async throws {
        let library = try await makeLibrary(count: 2)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setPlaybackMode(.shuffle)
        let first = library.clips[0]
        player.play(first, url: library.fileURL(for: first))
        try await waitUntil { player.isPlaying }
        try library.delete(library.clips[1])
        player.refreshLibrary()
        let added = try await library.importVideo(at: source, suggestedName: "新导入")
        player.refreshLibrary()
        player.playNextTrack()
        try await waitUntil { player.currentClip?.id == added.id && player.isPlaying }
        try library.delete(first)
        player.refreshLibrary()
        XCTAssertTrue(player.canPlayPreviousTrack)
        XCTAssertTrue(player.canPlayNextTrack)
    }

    func testShuffleMissingNextAudioPausesAndManualPlayRecovers() async throws {
        let library = try await makeLibrary(count: 2)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setPlaybackMode(.shuffle)
        let first = library.clips[0]
        player.play(first, url: library.fileURL(for: first))
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        try FileManager.default.removeItem(at: library.fileURL(for: library.clips[1]))
        player.seek(to: player.duration - 0.18)
        try await waitUntil { player.errorMessage != nil && !player.isPlaying }
        XCTAssertEqual(player.currentClip?.id, first.id)
        player.togglePlayPause()
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 && player.currentTime < 1 }
        XCTAssertEqual(player.playbackMode, .shuffle)
        XCTAssertNil(player.errorMessage)
    }

    func testPauseCancelsShuffleNavigationWithoutConsumingNextTrack() async throws {
        let library = try await makeLibrary(count: 2)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.setPlaybackMode(.shuffle)
        player.play(library.clips[0], url: library.fileURL(for: library.clips[0]))
        try await waitUntil { player.isPlaying }
        player.playNextTrack()
        player.playPreviousTrack()
        player.pause()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(player.currentClip?.id, library.clips[0].id)
        XCTAssertFalse(player.isPlaying)
        player.playNextTrack()
        try await waitUntil { player.currentClip?.id == library.clips[1].id && player.isPlaying }
    }

    func testPlaybackModeCycleDoesNotRestartPausedAudioOrChangeSpeed() async throws {
        let library = try await makeLibrary(count: 2)
        let player = AudioPlayer()
        defer { player.stop() }
        player.connectLibrary(library)
        player.play(library.clips[0], url: library.fileURL(for: library.clips[0]))
        try await waitUntil { player.isPlaying }
        player.pause()
        player.seek(to: 0.5)
        player.setRate(1.65)
        for mode in [PlaybackMode.sequential, .shuffle, .repeatOne] {
            player.cyclePlaybackMode()
            XCTAssertEqual(player.playbackMode, mode)
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(player.currentTime, 0.5, accuracy: 0.1)
            XCTAssertEqual(player.rate, 1.65, accuracy: 0.001)
        }
    }

    private func makeLibrary(count: Int) async throws -> LibraryStore {
        let library = LibraryStore(rootDirectory: directory.appendingPathComponent("Library"))
        for index in 0..<count { try await library.importVideo(at: source, suggestedName: "声音 \(index + 1)") }
        return library
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Track selection or playback did not reach its expected state.", file: file, line: line)
                throw NavigationError.timeout
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum NavigationError: Error { case timeout }
}

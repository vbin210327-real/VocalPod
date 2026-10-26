import AVFoundation
import UIKit
import XCTest
@testable import VocalPod

@MainActor
final class InterruptionTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    private var clip: AudioClip!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("VocalPod-Interruption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("audio.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050 * 12)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = sin(Float(frame) * 2 * .pi * 330 / 22_050) * 0.1
        }
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        try file.write(from: buffer)
        clip = AudioClip(title: "中断恢复验证", fileName: source.lastPathComponent, duration: 12,
                         soundBounds: AudioBounds(start: 1, end: 11))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testPlayButtonRecoversWhenInterruptionEndNeverArrives() async throws {
        let player = try await playingPlayer()
        defer { player.stop() }
        player.seek(to: 2)
        try await beginInterruption(player)
        let interruptedPosition = player.currentTime

        player.togglePlayPause()

        try await waitUntil { player.isPlaying && player.currentTime > interruptedPosition + 0.1 }
        XCTAssertEqual(player.rate, 1.5)
        XCTAssertEqual(player.duration, 10, accuracy: 0.01)
        XCTAssertNil(player.errorMessage)
    }

    func testForegroundReturnWithMissingEndAllowsOnePlayTap() async throws {
        let player = try await playingPlayer()
        defer { player.stop() }
        try await beginInterruption(player)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(player.isPlaying, "Returning to the app alone must not steal other media's audio.")

        player.togglePlayPause()

        try await waitUntil { player.isPlaying && player.currentTime > 0.2 }
    }

    func testInterruptionCanAutomaticallyResumeWhenSystemAllowsIt() async throws {
        let player = try await playingPlayer()
        defer { player.stop() }
        try await beginInterruption(player)
        endInterruption(shouldResume: true)
        try await waitUntil { player.isPlaying && player.currentTime > 0.2 }
    }

    func testUserPauseDuringInterruptionPreventsAutomaticResume() async throws {
        let player = try await playingPlayer()
        defer { player.stop() }
        try await beginInterruption(player)
        player.pause()
        endInterruption(shouldResume: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(player.isPlaying)
        player.togglePlayPause()
        try await waitUntil { player.isPlaying }
    }

    func testEndedWithoutResumeStillAllowsManualPlayback() async throws {
        let player = try await playingPlayer()
        defer { player.stop() }
        try await beginInterruption(player)
        endInterruption(shouldResume: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(player.isPlaying)
        player.togglePlayPause()
        try await waitUntil { player.isPlaying && player.currentTime > 0.2 }
    }

    func testLateEndNotificationDoesNotCancelExplicitPlayback() async throws {
        let player = try await playingPlayer()
        defer { player.stop() }
        try await beginInterruption(player)
        player.togglePlayPause()
        try await waitUntil { player.isPlaying }
        let position = player.currentTime
        endInterruption(shouldResume: false)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(player.isPlaying)
        try await waitUntil { player.currentTime > position + 0.1 }
    }

    func testMediaResetPreservesSettingsAndPlayButtonRebuildsPlayer() async throws {
        let player = try await playingPlayer()
        defer { player.stop() }
        player.seek(to: 2.5)
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        try await waitUntil { !player.isPlaying }
        try await Task.sleep(for: .milliseconds(100))
        let position = player.currentTime
        XCTAssertEqual(player.currentClip?.id, clip.id)
        XCTAssertEqual(player.rate, 1.5)
        XCTAssertFalse(player.loopEnabled)
        XCTAssertEqual(player.duration, 10, accuracy: 0.01)

        player.togglePlayPause()

        try await waitUntil { player.isPlaying && player.currentTime > position + 0.1 }
        XCTAssertNil(player.errorMessage)
    }

    func testSelectingAnotherClipAfterMissingEndStartsItImmediately() async throws {
        let player = try await playingPlayer()
        defer { player.stop() }
        try await beginInterruption(player)
        let other = AudioClip(title: "另一段声音", fileName: source.lastPathComponent, duration: 12)
        player.play(other, url: source)
        try await waitUntil { player.isPlaying && player.currentTime > 0.1 }
        XCTAssertEqual(player.currentClip?.id, other.id)
    }

    private func playingPlayer() async throws -> AudioPlayer {
        let player = AudioPlayer()
        player.setRate(1.5)
        player.setLoopEnabled(false)
        player.play(clip, url: source)
        try await waitUntil { player.isPlaying && player.currentTime > 0.05 }
        return player
    }

    private func beginInterruption(_ player: AudioPlayer) async throws {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await waitUntil { !player.isPlaying }
    }

    private func endInterruption(shouldResume: Bool) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
            AVAudioSessionInterruptionOptionKey: shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0
        ])
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Audio playback did not recover and advance.", file: file, line: line)
                throw RecoveryError.timeout
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum RecoveryError: Error { case timeout }
}

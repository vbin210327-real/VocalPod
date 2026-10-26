import AVFoundation
import Foundation
import MediaPlayer
import Observation
import UIKit

enum PlaybackMode: CaseIterable {
    case repeatOne, sequential, shuffle

    var title: String {
        switch self {
        case .repeatOne: return "单曲循环"
        case .sequential: return "顺序播放"
        case .shuffle: return "随机循环"
        }
    }

    var symbol: String {
        switch self {
        case .repeatOne: return "repeat"
        case .sequential: return "arrow.right"
        case .shuffle: return "shuffle"
        }
    }
}

@MainActor
@Observable
final class AudioPlayer {
    private(set) var currentClip: AudioClip?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Float = 1
    private(set) var playbackMode: PlaybackMode = .repeatOne
    var loopEnabled: Bool { playbackMode == .repeatOne }
    var errorMessage: String?

    @ObservationIgnored private var player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var timeControlObserver: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObserver: NSKeyValueObservation?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var resumeAfterInterruption = false
    @ObservationIgnored private var isInterrupted = false
    @ObservationIgnored private var itemGeneration = UUID()
    @ObservationIgnored private var playbackStart: TimeInterval = 0
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private weak var library: LibraryStore?
    @ObservationIgnored private var trackChangeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingClipID: UUID?
    @ObservationIgnored private var trackChangeID = UUID()
    @ObservationIgnored private var shuffleRemaining: [UUID] = []
    @ObservationIgnored private var shuffleKnownIDs: Set<UUID> = []
    @ObservationIgnored private var pendingShufflePlan: [UUID]?
    @ObservationIgnored private var pendingShuffleSteps = 0

    var canPlayNextTrack: Bool {
        playbackMode == .shuffle ? currentClip != nil && !(library?.clips.isEmpty ?? true) : adjacentClip(by: 1) != nil
    }

    var canPlayPreviousTrack: Bool {
        playbackMode == .shuffle ? canPlayNextTrack : adjacentClip(by: -1) != nil
    }

    init() {
        configurePlayer()
        observeNotifications()
        configureRemoteCommands()
    }

    private func configurePlayer() {
        let observedPlayer = player
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self, weak observedPlayer] time in
            Task { @MainActor [weak self, weak observedPlayer] in
                guard let self, self.player === observedPlayer else { return }
                if time.seconds.isFinite { self.currentTime = max(0, min(time.seconds - self.playbackStart, self.duration)) }
                self.refreshNowPlaying()
            }
        }
        timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self, weak observedPlayer] _, _ in
            Task { @MainActor [weak self, weak observedPlayer] in
                guard let self, let observedPlayer, self.player === observedPlayer else { return }
                self.isPlaying = observedPlayer.timeControlStatus == .playing
                self.refreshNowPlaying()
            }
        }
    }

    deinit {
        trackChangeTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        for observer in notifications { NotificationCenter.default.removeObserver(observer) }
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    func play(_ clip: AudioClip, url: URL) {
        cancelTrackChange()
        startPlayback(clip, url: url)
    }

    private func startPlayback(_ clip: AudioClip, url: URL, continuingShuffle: Bool = false, restart: Bool = false) {
        errorMessage = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "找不到这段声音文件，请重新导入录屏。"
            return
        }
        sourceURL = url
        if currentClip?.id == clip.id, player.currentItem != nil {
            updateClip(clip)
            if restart { seek(to: 0) }
            resume()
            return
        }

        player.pause()
        itemGeneration = UUID()
        currentClip = clip
        if playbackMode == .shuffle && !continuingShuffle { resetShuffle(startingAt: clip.id) }
        playbackStart = clip.playbackStart
        duration = clip.playbackDuration
        currentTime = 0
        installItem(for: clip, url: url, position: 0)
        resume()
    }

    private func installItem(for clip: AudioClip, url: URL, position: TimeInterval) {
        itemStatusObserver = nil
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        item.forwardPlaybackEndTime = CMTime(seconds: clip.playbackEnd, preferredTimescale: 600)
        player.replaceCurrentItem(with: item)
        if playbackStart + position > 0 {
            player.seek(to: CMTime(seconds: playbackStart + position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.wantsPlayback = false
                    self.isPlaying = false
                    self.errorMessage = item.error?.localizedDescription ?? "这段声音暂时无法播放，请重试。"
                    self.refreshNowPlaying()
                }
            }
        }
    }

    func togglePlayPause() {
        if (isPlaying || wantsPlayback) && !isInterrupted { pause() } else { resume() }
    }

    func pause() {
        cancelTrackChange()
        pausePlayback()
    }

    private func pausePlayback() {
        wantsPlayback = false
        resumeAfterInterruption = false
        player.pause()
        isPlaying = false
        refreshNowPlaying()
    }

    func stop() {
        pause()
        itemGeneration = UUID()
        itemStatusObserver = nil
        player.replaceCurrentItem(with: nil)
        currentClip = nil
        duration = 0
        currentTime = 0
        playbackStart = 0
        sourceURL = nil
        shuffleRemaining = []
        shuffleKnownIDs = []
        isInterrupted = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        updateRemoteAvailability()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func seek(to time: TimeInterval) {
        guard time.isFinite, player.currentItem != nil else { return }
        let target = max(0, min(time, duration))
        currentTime = target
        player.seek(to: CMTime(seconds: playbackStart + target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        refreshNowPlaying()
    }

    func skip(by interval: TimeInterval) {
        guard interval.isFinite else { return }
        seek(to: currentTime + interval)
    }

    func connectLibrary(_ library: LibraryStore) {
        if self.library !== library { cancelTrackChange() }
        self.library = library
        refreshLibrary()
    }

    func refreshLibrary() {
        guard let library else { return }
        if let pendingClipID, !library.clips.contains(where: { $0.id == pendingClipID }) { cancelTrackChange() }
        if let currentClip {
            guard let updated = library.clips.first(where: { $0.id == currentClip.id }) else {
                stop()
                return
            }
            updateClip(updated)
        }
        if playbackMode == .shuffle {
            let ids = Set(library.clips.map(\.id))
            shuffleRemaining.removeAll { !ids.contains($0) }
            let added = ids.subtracting(shuffleKnownIDs).shuffled()
            shuffleRemaining.append(contentsOf: added)
            if let plan = pendingShufflePlan {
                pendingShufflePlan = Array(plan.prefix(pendingShuffleSteps))
                    + plan.dropFirst(pendingShuffleSteps).filter { ids.contains($0) } + added
            }
            shuffleKnownIDs = ids
            if shuffleRemaining.isEmpty { refillShuffle(avoiding: currentClip?.id) }
            if ids.count > 1, shuffleRemaining.first == currentClip?.id {
                if shuffleRemaining.count == 1 {
                    refillShuffle(avoiding: currentClip?.id)
                } else {
                    shuffleRemaining.swapAt(0, Int.random(in: 1..<shuffleRemaining.count))
                }
            }
        }
        refreshNowPlaying()
    }

    func playNextTrack() { changeTrack(by: 1) }

    func playPreviousTrack() { changeTrack(by: -1) }

    private func adjacentClip(by offset: Int) -> AudioClip? {
        guard let library, let id = pendingClipID ?? currentClip?.id,
              let index = library.clips.firstIndex(where: { $0.id == id }),
              library.clips.indices.contains(index + offset) else { return nil }
        return library.clips[index + offset]
    }

    private func changeTrack(by offset: Int, automatically: Bool = false) {
        guard let library else { return }
        let usesShuffle = playbackMode == .shuffle
        let next: AudioClip?
        if usesShuffle {
            // Both manual buttons and automatic advance consume the same random
            // queue. Reserve each tap immediately, even while analysis is pending.
            var plan = pendingShufflePlan ?? shuffleRemaining
            if pendingShuffleSteps >= plan.count {
                plan.append(contentsOf: shuffledRound(avoiding: plan.last ?? currentClip?.id))
            }
            guard plan.indices.contains(pendingShuffleSteps) else { return }
            let id = plan[pendingShuffleSteps]
            next = library.clips.first { $0.id == id }
            guard next != nil else { return }
            pendingShufflePlan = plan
            pendingShuffleSteps += 1
        } else {
            next = adjacentClip(by: offset)
        }
        guard let next else { return }
        trackChangeTask?.cancel()
        let requestID = UUID()
        trackChangeID = requestID
        pendingClipID = next.id
        updateRemoteAvailability()
        trackChangeTask = Task { @MainActor [weak self, weak library] in
            defer {
                if let self, self.trackChangeID == requestID {
                    self.clearPendingShuffle()
                    self.pendingClipID = nil
                    self.trackChangeTask = nil
                    self.updateRemoteAvailability()
                }
            }
            guard let library else { return }
            let backgroundID = UIApplication.shared.beginBackgroundTask(withName: "切换音频") { [weak self] in
                guard let self, self.trackChangeID == requestID else { return }
                self.trackChangeTask?.cancel()
            }
            defer { if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) } }
            do {
                let analyzed = try await library.analyzeSilence(for: next)
                try Task.checkCancellation()
                guard let self, self.trackChangeID == requestID else { return }
                self.startPlayback(analyzed, url: library.fileURL(for: analyzed),
                                   continuingShuffle: usesShuffle && self.pendingShufflePlan != nil,
                                   restart: true)
                if usesShuffle, self.playbackMode == .shuffle,
                   self.currentClip?.id == analyzed.id, let plan = self.pendingShufflePlan {
                    self.shuffleRemaining = Array(plan.dropFirst(self.pendingShuffleSteps))
                    if self.shuffleRemaining.isEmpty { self.refillShuffle(avoiding: analyzed.id) }
                }
                if automatically && self.currentClip?.id != analyzed.id {
                    self.pausePlayback()
                }
            } catch is CancellationError {
                // A background-time expiration can cancel an automatic change
                // without an explicit Pause. Leave one-tap playback usable.
                if automatically, let self, self.trackChangeID == requestID {
                    self.pausePlayback()
                }
            } catch {
                if let self, self.trackChangeID == requestID {
                    if automatically { self.pausePlayback() }
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelTrackChange() {
        trackChangeID = UUID()
        trackChangeTask?.cancel()
        trackChangeTask = nil
        pendingClipID = nil
        clearPendingShuffle()
    }

    func setRate(_ value: Float) {
        guard value.isFinite else { return }
        rate = min(3, max(0.25, value))
        if wantsPlayback && !isInterrupted { player.playImmediately(atRate: rate) }
        refreshNowPlaying()
    }

    func setLoopEnabled(_ enabled: Bool) {
        setPlaybackMode(enabled ? .repeatOne : .sequential)
    }

    func cyclePlaybackMode() {
        switch playbackMode {
        case .repeatOne: setPlaybackMode(.sequential)
        case .sequential: setPlaybackMode(.shuffle)
        case .shuffle: setPlaybackMode(.repeatOne)
        }
    }

    func setPlaybackMode(_ mode: PlaybackMode) {
        guard playbackMode != mode else { return }
        playbackMode = mode
        resetShuffle(startingAt: currentClip?.id)
        refreshNowPlaying()
    }

    private func resetShuffle(startingAt id: UUID?) {
        clearPendingShuffle()
        shuffleKnownIDs = Set(library?.clips.map(\.id) ?? [])
        shuffleRemaining = shuffleKnownIDs.filter { $0 != id }.shuffled()
        if shuffleRemaining.isEmpty { refillShuffle(avoiding: id) }
    }

    private func refillShuffle(avoiding id: UUID?) {
        shuffleRemaining = shuffledRound(avoiding: id)
    }

    private func shuffledRound(avoiding id: UUID?) -> [UUID] {
        var round = (library?.clips.map(\.id) ?? []).shuffled()
        if round.count > 1, round.first == id {
            round.swapAt(0, Int.random(in: 1..<round.count))
        }
        return round
    }

    private func clearPendingShuffle() {
        pendingShufflePlan = nil
        pendingShuffleSteps = 0
    }

    /// Applies saved boundaries without modifying the underlying audio file.
    func updateClip(_ clip: AudioClip) {
        guard currentClip?.id == clip.id else { return }
        let changedRange = abs(playbackStart - clip.playbackStart) > 0.001 || abs(duration - clip.playbackDuration) > 0.001
        let sourcePosition = playbackStart + currentTime
        currentClip = clip
        if changedRange {
            itemGeneration = UUID()
            playbackStart = clip.playbackStart
            duration = clip.playbackDuration
            player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: clip.playbackEnd, preferredTimescale: 600)
            // Preserve the current sound while changing ranges; jump to the
            // detected start only when the old position is outside the new range.
            let newPosition = sourcePosition >= playbackStart && sourcePosition < clip.playbackEnd
                ? sourcePosition - playbackStart : 0
            seek(to: newPosition)
            if wantsPlayback && !isInterrupted { player.playImmediately(atRate: rate) }
        }
        refreshNowPlaying()
    }

    private func resume() {
        guard currentClip != nil else { return }
        errorMessage = nil
        if player.currentItem == nil || player.currentItem?.status == .failed || player.status == .failed {
            guard rebuildPlayer() else { return }
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
            // An interruption-began notification is not guaranteed to have an
            // ended partner. A successful explicit activation is authoritative.
            isInterrupted = false
            resumeAfterInterruption = false
            wantsPlayback = true
            if duration > 0, currentTime >= duration - 0.05 {
                seek(to: 0)
            }
            player.playImmediately(atRate: rate)
            refreshNowPlaying()
        } catch {
            wantsPlayback = false
            isPlaying = false
            errorMessage = "无法开始播放：\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func rebuildPlayer() -> Bool {
        let position = currentTime
        itemGeneration = UUID()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        timeControlObserver = nil
        itemStatusObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        player = AVPlayer()
        configurePlayer()
        guard let clip = currentClip else { return true }
        guard let url = sourceURL, FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "找不到这段声音文件，请重新导入录屏。"
            return false
        }
        currentTime = position
        installItem(for: clip, url: url, position: position)
        return true
    }

    private func returnedToForeground() {
        // Returning alone must not take audio away from another app. Clear a
        // stale interruption so the next Play tap can acquire the session.
        if isInterrupted {
            isInterrupted = false
            pausePlayback()
        } else if player.timeControlStatus == .paused {
            wantsPlayback = false
            isPlaying = false
            refreshNowPlaying()
        }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.didReachEnd()
            }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.pause()
                self.errorMessage = "播放中断了，请再试一次。"
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self, let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
                if type == .began {
                    self.cancelTrackChange()
                    self.resumeAfterInterruption = self.resumeAfterInterruption || self.wantsPlayback || self.isPlaying
                    self.isInterrupted = true
                    self.wantsPlayback = false
                    self.player.pause()
                    self.isPlaying = false
                    self.refreshNowPlaying()
                } else {
                    // A user may already have resumed after a missing/late end.
                    guard self.isInterrupted else { return }
                    self.isInterrupted = false
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
                    if shouldResume && self.resumeAfterInterruption {
                        self.resumeAfterInterruption = false
                        self.resume()
                    } else {
                        self.pause()
                    }
                }
            }
        })
        notifications.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.returnedToForeground() }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pause()
                self.isInterrupted = false
                self.errorMessage = nil
                self.rebuildPlayer()
                self.refreshNowPlaying()
            }
        })
    }

    private func didReachEnd() {
        // Duplicate end notifications must not skip over a pending next track.
        guard pendingClipID == nil else { return }
        // Ignore a queued end notification if the user has just expanded the
        // range or sought away from the previous end on the same player item.
        let absoluteTime = player.currentTime().seconds
        guard absoluteTime.isFinite, absoluteTime >= playbackStart + duration - 0.08 else { return }
        if loopEnabled && wantsPlayback && !isInterrupted {
            let generation = itemGeneration
            currentTime = 0
            player.seek(to: CMTime(seconds: playbackStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor [weak self] in
                    guard let self, finished, self.itemGeneration == generation,
                          self.wantsPlayback, !self.isInterrupted else { return }
                    guard self.loopEnabled else {
                        self.seek(to: self.duration)
                        self.advanceAfterEnd()
                        return
                    }
                    self.player.playImmediately(atRate: self.rate)
                    self.refreshNowPlaying()
                }
            }
        } else if wantsPlayback && !isInterrupted {
            advanceAfterEnd()
        } else {
            currentTime = duration
            pausePlayback()
        }
    }

    private func advanceAfterEnd() {
        currentTime = duration
        if playbackMode == .shuffle || adjacentClip(by: 1) != nil {
            changeTrack(by: 1, automatically: true)
        } else if let library, let index = library.clips.firstIndex(where: { $0.id == currentClip?.id }) {
            // Sequential mode cycles through the saved queue, including a one-clip library.
            changeTrack(by: -index, automatically: true)
        } else {
            pausePlayback()
        }
    }

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.changePlaybackRateCommand.supportedPlaybackRates = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
        register(commands.playCommand) { [weak self] _ in self?.resume() }
        register(commands.pauseCommand) { [weak self] _ in self?.pause() }
        register(commands.togglePlayPauseCommand) { [weak self] _ in self?.togglePlayPause() }
        register(commands.stopCommand) { [weak self] _ in self?.pause() }
        register(commands.nextTrackCommand) { [weak self] _ in self?.playNextTrack() }
        register(commands.previousTrackCommand) { [weak self] _ in self?.playPreviousTrack() }
        register(commands.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            self?.seek(to: event.positionTime)
        }
        register(commands.changePlaybackRateCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return }
            self?.setRate(event.playbackRate)
        }
        updateRemoteAvailability()
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
        let target = command.addTarget { [weak self] event in
            Task { @MainActor [weak self] in
                guard self?.currentClip != nil else { return }
                action(event)
            }
            return .success
        }
        remoteTargets.append((command, target))
    }

    private func updateRemoteAvailability() {
        for (command, _) in remoteTargets { command.isEnabled = currentClip != nil }
        let commands = MPRemoteCommandCenter.shared()
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.isEnabled = false
        commands.nextTrackCommand.isEnabled = canPlayNextTrack
        commands.previousTrackCommand.isEnabled = canPlayPreviousTrack
    }

    private func refreshNowPlaying() {
        updateRemoteAvailability()
        guard let clip = currentClip else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: clip.title,
            MPMediaItemPropertyArtist: "VocalPod",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if let library, let index = library.clips.firstIndex(where: { $0.id == clip.id }) {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = library.clips.count
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

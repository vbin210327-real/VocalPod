import Foundation

struct AudioBounds: Codable, Hashable, Sendable {
    var start: TimeInterval
    var end: TimeInterval

    func clamped(to duration: TimeInterval) -> AudioBounds {
        let total = duration.isFinite ? max(0, duration) : 0
        let full = AudioBounds(start: 0, end: total)
        guard start.isFinite, end.isFinite, end > start else { return full }
        let lower = min(total, max(0, start))
        let upper = min(total, max(0, end))
        guard upper > lower else { return full }
        return AudioBounds(start: lower, end: upper)
    }
}

struct AudioClip: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var fileName: String
    var duration: TimeInterval
    var createdAt: Date
    var soundBounds: AudioBounds?
    var autoTrimEnabled: Bool?

    var isAutoTrimEnabled: Bool { autoTrimEnabled ?? true }

    var playbackStart: TimeInterval {
        isAutoTrimEnabled ? validatedSoundBounds.start : 0
    }

    var playbackEnd: TimeInterval {
        isAutoTrimEnabled ? validatedSoundBounds.end : safeDuration
    }

    var playbackDuration: TimeInterval { max(0, playbackEnd - playbackStart) }

    var trimmedSilenceDuration: TimeInterval { max(0, safeDuration - playbackDuration) }

    private var safeDuration: TimeInterval { duration.isFinite ? max(0, duration) : 0 }

    private var validatedSoundBounds: AudioBounds {
        (soundBounds ?? AudioBounds(start: 0, end: safeDuration)).clamped(to: safeDuration)
    }

    init(
        id: UUID = UUID(),
        title: String,
        fileName: String,
        duration: TimeInterval,
        createdAt: Date = Date(),
        soundBounds: AudioBounds? = nil,
        autoTrimEnabled: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.duration = duration
        self.createdAt = createdAt
        self.soundBounds = soundBounds
        self.autoTrimEnabled = autoTrimEnabled
    }
}

import Foundation
import Observation

enum LibraryError: LocalizedError {
    case unavailable(String)
    case alreadyImporting
    case invalidName
    case missingClip
    case invalidOrder

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "声音库暂时无法读取，已有文件会保留。\(detail)"
        case .alreadyImporting:
            return "正在提取上一段录屏，请稍等。"
        case .invalidName:
            return "请输入声音名称。"
        case .missingClip:
            return "这段声音已不在声音库中。"
        case .invalidOrder:
            return "无法调整声音顺序，请重试。"
        }
    }
}

@MainActor
@Observable
final class LibraryStore {
    private(set) var clips: [AudioClip] = []
    private(set) var isImporting = false
    private(set) var loadError: String?

    @ObservationIgnored private let rootDirectory: URL
    @ObservationIgnored private let audioDirectory: URL
    @ObservationIgnored private let importingDirectory: URL
    @ObservationIgnored private let indexURL: URL
    @ObservationIgnored private let fileManager = FileManager.default

    init(rootDirectory: URL? = nil) {
        let root = rootDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VocalPod", isDirectory: true)
        self.rootDirectory = root
        audioDirectory = root.appendingPathComponent("Audio", isDirectory: true)
        importingDirectory = root.appendingPathComponent("Importing", isDirectory: true)
        indexURL = root.appendingPathComponent("library.json")

        do {
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true, attributes: attributes)
            try fileManager.createDirectory(at: importingDirectory, withIntermediateDirectories: true, attributes: attributes)
            if fileManager.fileExists(atPath: indexURL.path) {
                clips = try JSONDecoder().decode([AudioClip].self, from: Data(contentsOf: indexURL))
                guard clips.allSatisfy({ $0.fileName == URL(fileURLWithPath: $0.fileName).lastPathComponent && $0.duration.isFinite && $0.duration > 0 }),
                      Set(clips.map(\.id)).count == clips.count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            // Only disposable exports are placed here; originals are never copied here.
            for url in try fileManager.contentsOfDirectory(at: importingDirectory, includingPropertiesForKeys: nil) {
                try? fileManager.removeItem(at: url)
            }
            // Recover space if the app was stopped between moving an export and
            // committing its index, or between committing deletion and removal.
            let savedNames = Set(clips.map(\.fileName))
            for url in try fileManager.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil) {
                if url.pathExtension == "m4a",
                   UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                   !savedNames.contains(url.lastPathComponent) {
                    try? fileManager.removeItem(at: url)
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func fileURL(for clip: AudioClip) -> URL {
        audioDirectory.appendingPathComponent(URL(fileURLWithPath: clip.fileName).lastPathComponent)
    }

    @discardableResult
    func importVideo(at sourceURL: URL, suggestedName: String? = nil) async throws -> AudioClip {
        try ensureReady()
        guard !isImporting else { throw LibraryError.alreadyImporting }
        isImporting = true
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        let id = UUID()
        let fileName = "\(id.uuidString).m4a"
        let stagingURL = importingDirectory.appendingPathComponent(fileName)
        let finalURL = audioDirectory.appendingPathComponent(fileName)
        var committed = false
        defer {
            isImporting = false
            if scoped { sourceURL.stopAccessingSecurityScopedResource() }
            try? fileManager.removeItem(at: stagingURL)
            if !committed { try? fileManager.removeItem(at: finalURL) }
        }

        let duration = try await AudioImporter.extractAudio(from: sourceURL, to: stagingURL)
        try Task.checkCancellation()
        let bounds = try await detectedBounds(at: stagingURL, duration: duration)
        try Task.checkCancellation()
        let rawName = suggestedName ?? sourceURL.deletingPathExtension().lastPathComponent
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let clip = AudioClip(
            id: id,
            title: name.isEmpty ? "新的声音" : String(name.prefix(100)),
            fileName: fileName,
            duration: duration,
            soundBounds: bounds
        )
        try fileManager.moveItem(at: stagingURL, to: finalURL)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: finalURL.path)
        let updated = [clip] + clips
        try persist(updated)
        clips = updated
        committed = true
        return clip
    }

    func rename(_ clip: AudioClip, to title: String) throws {
        try ensureReady()
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.invalidName }
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { throw LibraryError.missingClip }
        var updated = clips
        updated[index].title = String(name.prefix(100))
        try persist(updated)
        clips = updated
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        try ensureReady()
        guard !source.isEmpty else { return }
        guard (0...clips.count).contains(destination),
              source.allSatisfy({ clips.indices.contains($0) }) else { throw LibraryError.invalidOrder }
        var updated = clips
        let moving = source.map { clips[$0] }
        for index in source.reversed() { updated.remove(at: index) }
        let insertion = destination - source.filter { $0 < destination }.count
        updated.insert(contentsOf: moving, at: insertion)
        guard updated != clips else { return }
        // The index array is the saved queue order; audio files stay in place.
        try persist(updated)
        clips = updated
    }

    @discardableResult
    func analyzeSilence(for clip: AudioClip) async throws -> AudioClip {
        try Task.checkCancellation()
        try ensureReady()
        guard let current = clips.first(where: { $0.id == clip.id }) else { throw LibraryError.missingClip }
        if current.soundBounds != nil { return current }
        let bounds = try await detectedBounds(at: fileURL(for: current), duration: current.duration)
        try Task.checkCancellation()
        // Renaming, deleting, or toggling automatic trimming can happen during
        // analysis. Apply just the new bounds to the latest persisted record.
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { throw LibraryError.missingClip }
        if clips[index].soundBounds != nil { return clips[index] }
        var updated = clips
        updated[index].soundBounds = bounds.clamped(to: updated[index].duration)
        try persist(updated)
        clips = updated
        return updated[index]
    }

    @discardableResult
    func setAutoTrim(_ clip: AudioClip, enabled: Bool) throws -> AudioClip {
        try ensureReady()
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { throw LibraryError.missingClip }
        var updated = clips
        updated[index].autoTrimEnabled = enabled
        try persist(updated)
        clips = updated
        return updated[index]
    }

    func enableAutomaticTrimming() throws {
        try ensureReady()
        guard clips.contains(where: { $0.autoTrimEnabled == false }) else { return }
        let updated = clips.map { clip in
            var updatedClip = clip
            if updatedClip.autoTrimEnabled == false { updatedClip.autoTrimEnabled = true }
            return updatedClip
        }
        try persist(updated)
        clips = updated
    }

    func delete(_ clip: AudioClip) throws {
        try ensureReady()
        guard clips.contains(where: { $0.id == clip.id }) else { throw LibraryError.missingClip }
        let updated = clips.filter { $0.id != clip.id }
        let sourceURL = fileURL(for: clip)
        // Commit metadata first, and restore it if file removal fails.
        try persist(updated)
        do {
            if fileManager.fileExists(atPath: sourceURL.path) {
                try fileManager.removeItem(at: sourceURL)
            }
        } catch {
            try? persist(clips)
            throw error
        }
        clips = updated
    }

    private func ensureReady() throws {
        if let loadError { throw LibraryError.unavailable(loadError) }
    }

    private func detectedBounds(at url: URL, duration: TimeInterval) async throws -> AudioBounds {
        do {
            return try await SilenceAnalyzer.analyze(url: url, duration: duration)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            // Analysis is an optional improvement. The exported recording is
            // still usable if its decoded samples cannot be analyzed safely.
            return AudioBounds(start: 0, end: duration)
        }
    }

    private func persist(_ updated: [AudioClip]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(updated)
        try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

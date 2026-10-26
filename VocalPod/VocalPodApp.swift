import SwiftUI

@main
struct VocalPodApp: App {
    @State private var library: LibraryStore
    @State private var player = AudioPlayer()

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VocalPod-UITesting", isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("--reset-library") {
                try? FileManager.default.removeItem(at: root)
            }
            _library = State(initialValue: LibraryStore(rootDirectory: root))
            return
        }
        #endif
        _library = State(initialValue: LibraryStore())
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library, player: player)
                .preferredColorScheme(.light)
                .tint(PodStyle.accent)
                #if DEBUG
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                       ProcessInfo.processInfo.arguments.contains("--seed-audio"), library.clips.isEmpty {
                        await seedTestingAudio()
                    }
                }
                #endif
        }
    }

    #if DEBUG
    private func seedTestingAudio() async {
        do {
            let fixture = try TestAudioFactory.makeAudio()
            defer { try? FileManager.default.removeItem(at: fixture) }
            let count = ProcessInfo.processInfo.arguments.contains("--seed-playlist") ? 3 : 1
            for index in 0..<count {
                _ = try await library.importVideo(at: fixture, suggestedName: count == 1 ? "测试声音" : "测试声音 \(index + 1)")
            }
        } catch { print("UI fixture failed: \(error)") }
    }
    #endif
}

#if DEBUG
import AVFoundation

private enum TestAudioFactory {
    static func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 12)!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            let audible = index >= 44_100 && index < 44_100 * 11
            buffer.floatChannelData![0][index] = audible ? Float(sin(Double(index) * 440 * 2 * .pi / 44_100) * 0.12) : 0
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
#endif

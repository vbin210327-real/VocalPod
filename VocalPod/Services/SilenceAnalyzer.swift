import Accelerate
import AVFoundation
import Foundation

enum SilenceAnalyzer {
    /// Finds only the outer sound boundaries. It never writes to the audio file
    /// or removes pauses inside the detected span.
    static func analyze(url: URL, duration: TimeInterval? = nil) async throws -> AudioBounds {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate.isFinite, sampleRate > 0, file.length > 0 else {
            return AudioBounds(start: 0, end: duration.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 0)
        }
        let decodedDuration = Double(file.length) / sampleRate
        let fullDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? decodedDuration
        let full = AudioBounds(start: 0, end: fullDuration)

        // If container and PCM timelines disagree substantially, leave the
        // recording intact rather than guess where its audible content lies.
        guard abs(decodedDuration - fullDuration) <= max(0.25, fullDuration * 0.01),
              format.channelCount > 0, format.channelCount <= 64,
              sampleRate <= 384_000 else { return full }

        let windowFrames = max(1, Int((sampleRate * 0.01).rounded()))
        let capacity = AVAudioFrameCount(windowFrames * 100)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return full }
        var histogram = [Int](repeating: 0, count: 161)
        var windowCount = 0
        var strongestDB = -160.0

        // First pass learns a fixed-size loudness histogram. No PCM or list of
        // per-window measurements grows with the length of the recording.
        try scan(file: file, buffer: buffer, windowFrames: windowFrames) { _, _, rms, _ in
            let db = 20 * log10(max(Double(rms), 1e-12))
            strongestDB = max(strongestDB, db)
            let bin = max(0, min(160, Int(floor(db)) + 160))
            histogram[bin] += 1
            windowCount += 1
        }
        try Task.checkCancellation()
        guard windowCount > 0 else { return full }

        let noiseDB = percentile(0.10, histogram: histogram, count: windowCount)
        let referenceDB = percentile(0.95, histogram: histogram, count: windowCount)
        // A deliberately low threshold protects soft words and fading tails.
        // Noise-floor adaptation only applies when it is safer than the caps.
        let thresholdDB = max(-100, min(-66, noiseDB + 3, referenceDB - 48))
        guard strongestDB > thresholdDB + 6 else { return full }
        let rmsThreshold = Float(pow(10, thresholdDB / 20))
        let peakThreshold = rmsThreshold * 2.8
        var firstSound: TimeInterval?
        var lastSound: TimeInterval = 0
        var activeDuration: TimeInterval = 0

        file.framePosition = 0
        try scan(file: file, buffer: buffer, windowFrames: windowFrames) { start, length, rms, peak in
            guard rms > rmsThreshold || peak > peakThreshold else { return }
            if firstSound == nil { firstSound = start }
            lastSound = start + length
            activeDuration += length
        }
        try Task.checkCancellation()
        // Silence, a few ambiguous samples, or an unreadable boundary should
        // never collapse a recording into a tiny, misleading playback span.
        guard let firstSound, activeDuration >= 0.03, lastSound > firstSound else { return full }
        var start = max(0, firstSound - 0.16)
        var end = min(fullDuration, lastSound + 0.20)
        if start < 0.12 { start = 0 }
        if fullDuration - end < 0.12 { end = fullDuration }
        guard end - start >= 0.05 else { return full }
        return AudioBounds(start: start, end: end).clamped(to: fullDuration)
    }

    private static func scan(
        file: AVAudioFile,
        buffer: AVAudioPCMBuffer,
        windowFrames: Int,
        observe: (TimeInterval, TimeInterval, Float, Float) -> Void
    ) throws {
        let sampleRate = file.processingFormat.sampleRate
        let channelCount = Int(file.processingFormat.channelCount)
        var offset: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            let count = Int(buffer.frameLength)
            guard count > 0, let channels = buffer.floatChannelData else { throw AnalysisError.invalidSamples }
            var windowOffset = 0
            while windowOffset < count {
                let length = min(windowFrames, count - windowOffset)
                var maximumRMS: Float = 0
                var maximumPeak: Float = 0
                for channel in 0..<channelCount {
                    let samples = channels[channel].advanced(by: windowOffset * buffer.stride)
                    var rms: Float = 0
                    var peak: Float = 0
                    vDSP_rmsqv(samples, vDSP_Stride(buffer.stride), &rms, vDSP_Length(length))
                    vDSP_maxmgv(samples, vDSP_Stride(buffer.stride), &peak, vDSP_Length(length))
                    guard rms.isFinite, peak.isFinite else { throw AnalysisError.invalidSamples }
                    maximumRMS = max(maximumRMS, rms)
                    maximumPeak = max(maximumPeak, peak)
                }
                observe(Double(offset + AVAudioFramePosition(windowOffset)) / sampleRate,
                        Double(length) / sampleRate, maximumRMS, maximumPeak)
                windowOffset += length
            }
            offset += AVAudioFramePosition(count)
        }
    }

    private static func percentile(_ fraction: Double, histogram: [Int], count: Int) -> Double {
        let target = max(1, Int(ceil(Double(count) * fraction)))
        var accumulated = 0
        for (index, amount) in histogram.enumerated() {
            accumulated += amount
            if accumulated >= target { return Double(index) - 160 + 0.5 }
        }
        return 0
    }

    private enum AnalysisError: Error {
        case invalidSamples
    }
}

import AVFoundation
import CryptoKit

/// Loudness envelope and timing facts used to plan transitions between songs.
struct TrackAnalysis: Codable, Sendable {
    static let windowSeconds = 0.05

    var duration: Double
    /// Seconds of silence before the music starts.
    var leadIn: Double
    /// Time at which the music ends (trailing silence trimmed).
    var musicEnd: Double
    /// Mean loudness of the audible part, in dBFS.
    var loudness: Double
    var bpm: Double?
    /// First strong beat after the lead-in, in seconds.
    var firstBeat: Double?
    /// RMS level per 50 ms window in dBFS (clamped to -60...0), for waveforms.
    var envelope: [Float]

    /// Where the outro starts fading: the last point the level is still near
    /// the song's average before the end.
    var outroStart: Double {
        let threshold = Float(loudness - 7)
        let endIndex = min(envelope.count - 1, Int(musicEnd / Self.windowSeconds))
        let earliest = max(0, endIndex - Int(20 / Self.windowSeconds))
        guard endIndex > earliest else { return musicEnd }
        var index = endIndex
        while index > earliest, envelope[index] < threshold { index -= 1 }
        return Double(index) * Self.windowSeconds
    }
}

/// Decodes a file once in the background to measure silence, loudness and
/// tempo. Results are cached on disk by file path and size.
actor TrackAnalyzer {
    static let shared = TrackAnalyzer()

    private var memory: [String: TrackAnalysis] = [:]
    private var running: [String: Task<TrackAnalysis?, Never>] = [:]
    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Analysis-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cached(_ url: URL) -> TrackAnalysis? { memory[Self.key(url)] }

    func analysis(for url: URL) async -> TrackAnalysis? {
        let key = Self.key(url)
        if let value = memory[key] { return value }
        let file = directory.appendingPathComponent(key + ".json")
        if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(TrackAnalysis.self, from: data) {
            memory[key] = value
            return value
        }
        if let task = running[key] { return await task.value }
        let task = Task.detached(priority: .utility) { Self.analyze(url) }
        running[key] = task
        let value = await task.value
        running[key] = nil
        if let value {
            memory[key] = value
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: file) }
        }
        return value
    }

    private static func key(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let digest = SHA256.hash(data: Data("\(url.lastPathComponent)|\(size)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func analyze(_ url: URL) -> TrackAnalysis? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }
        let window = AVAudioFrameCount(sampleRate * TrackAnalysis.windowSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window * 40) else { return nil }

        var envelope: [Float] = []
        envelope.reserveCapacity(Int(Double(file.length) / Double(window)) + 1)
        var sum: Float = 0
        var count: AVAudioFrameCount = 0
        // A finer 10 ms envelope used only for tempo and beat detection.
        let fineWindow = max(1, window / 5)
        var fine: [Float] = []
        fine.reserveCapacity(envelope.capacity * 5)
        var fineSum: Float = 0
        var fineCount: AVAudioFrameCount = 0
        let channels = Int(format.channelCount)

        while file.framePosition < file.length {
            do { try file.read(into: buffer) } catch { break }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                var sample: Float = 0
                for channel in 0..<channels { sample += data[channel][frame] }
                sample /= Float(channels)
                sum += sample * sample
                count += 1
                fineSum += sample * sample
                fineCount += 1
                if fineCount == fineWindow {
                    fine.append(level(fineSum / Float(fineCount)))
                    fineSum = 0
                    fineCount = 0
                }
                if count == window {
                    envelope.append(level(sum / Float(count)))
                    sum = 0
                    count = 0
                }
            }
        }
        if count > 0 { envelope.append(level(sum / Float(count))) }
        guard !envelope.isEmpty else { return nil }

        let step = TrackAnalysis.windowSeconds
        let duration = Double(file.length) / sampleRate
        let silence: Float = -45
        let first = envelope.firstIndex { $0 > silence } ?? 0
        let last = envelope.lastIndex { $0 > silence } ?? (envelope.count - 1)
        let audible = envelope[first...max(first, last)].filter { $0 > -60 }
        let loudness = audible.isEmpty ? -20 : Double(audible.reduce(0, +) / Float(audible.count))
        let (bpm, beat) = tempo(fine, from: first * 5, step: TrackAnalysis.windowSeconds / 5)

        return TrackAnalysis(
            duration: duration,
            leadIn: Double(first) * step,
            musicEnd: min(duration, Double(last + 1) * step),
            loudness: loudness,
            bpm: bpm,
            firstBeat: beat,
            envelope: envelope
        )
    }

    private static func level(_ meanSquare: Float) -> Float {
        max(-60, min(0, 10 * log10(max(meanSquare, 1e-12))))
    }

    /// Estimates tempo by autocorrelating an onset (energy rise) curve over
    /// up to 40 s of music, then finds the first beat on that grid.
    private static func tempo(_ envelope: [Float], from start: Int, step: Double) -> (Double?, Double?) {
        let skip = Int(10 / step) // past intros, where the beat is often absent
        let begin = min(envelope.count, start + skip)
        let end = min(envelope.count, begin + Int(40 / step))
        guard end - begin > Int(8 / step) else { return (nil, nil) }
        var onset = [Float](repeating: 0, count: end - begin)
        for index in (begin + 1)..<end {
            onset[index - begin] = max(0, envelope[index] - envelope[index - 1])
        }
        let mean = onset.reduce(0, +) / Float(onset.count)
        for index in onset.indices { onset[index] = max(0, onset[index] - mean) }

        // 70–180 BPM.
        let minLag = Int((60.0 / 180.0) / step)
        let maxLag = Int((60.0 / 70.0) / step)
        var scores = [Float](repeating: 0, count: maxLag + 1)
        for lag in minLag...maxLag {
            var score: Float = 0
            var index = lag
            while index < onset.count {
                score += onset[index] * onset[index - lag]
                index += 1
            }
            // Count evidence at 2× and 4× the lag too (bars, not just beats).
            scores[lag] = score / Float(onset.count - lag)
        }
        guard let best = (minLag...maxLag).max(by: { scores[$0] < scores[$1] }), scores[best] > 0 else {
            return (nil, nil)
        }
        // Parabolic refinement for sub-step precision.
        var lag = Double(best)
        if best > minLag, best < maxLag {
            let a = Double(scores[best - 1]), b = Double(scores[best]), c = Double(scores[best + 1])
            let denominator = a - 2 * b + c
            if denominator != 0 { lag += 0.5 * (a - c) / denominator }
        }
        var bpm = 60.0 / (lag * step)
        while bpm < 85 { bpm *= 2 }
        while bpm > 170 { bpm /= 2 }

        // Beat phase: the offset within one period with the strongest onsets.
        let period = Int((60.0 / bpm) / step)
        guard period > 0 else { return (bpm, nil) }
        var phaseScores = [Float](repeating: 0, count: period)
        for (index, value) in onset.enumerated() { phaseScores[index % period] += value }
        let phase = phaseScores.indices.max { phaseScores[$0] < phaseScores[$1] } ?? 0
        // Project the grid back to the first beat after the music starts.
        var beatIndex = begin + phase
        while beatIndex - period >= start { beatIndex -= period }
        return (bpm, Double(beatIndex) * step)
    }
}

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
        directory = caches.appendingPathComponent("Analysis", isDirectory: true)
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
        let (bpm, beat) = tempo(envelope, from: first)

        return TrackAnalysis(
            duration: duration,
            leadIn: Double(first) * step,
            musicEnd: min(duration, Double(last + 1) * step),
            loudness: loudness,
            bpm: bpm,
            firstBeat: beat.map { Double($0) * step },
            envelope: envelope
        )
    }

    private static func level(_ meanSquare: Float) -> Float {
        max(-60, min(0, 10 * log10(max(meanSquare, 1e-12))))
    }

    /// Estimates tempo from the onset envelope by autocorrelation. At 50 ms
    /// resolution this is approximate; it is only used when two songs' tempos
    /// are already close.
    private static func tempo(_ envelope: [Float], from start: Int) -> (Double?, Int?) {
        let begin = min(envelope.count, start + 200)
        let end = min(envelope.count, begin + 1200)
        guard end - begin > 400 else { return (nil, nil) }
        var onset = [Float](repeating: 0, count: end - begin)
        for index in (begin + 1)..<end {
            onset[index - begin] = max(0, envelope[index] - envelope[index - 1])
        }
        // Lags for 70–180 BPM at 20 windows per second.
        let minLag = Int((60.0 / 180.0) / TrackAnalysis.windowSeconds)
        let maxLag = Int((60.0 / 70.0) / TrackAnalysis.windowSeconds)
        var bestLag = 0
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            var score: Float = 0
            for index in lag..<onset.count { score += onset[index] * onset[index - lag] }
            score /= Float(onset.count - lag)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestLag > 0, bestScore > 0.05 else { return (nil, nil) }
        let bpm = 60.0 / (Double(bestLag) * TrackAnalysis.windowSeconds)
        let firstOnset = (start..<min(envelope.count - 1, start + 100)).max { lhs, rhs in
            (envelope[lhs + 1] - envelope[lhs]) < (envelope[rhs + 1] - envelope[rhs])
        }
        return (bpm, firstOnset)
    }
}

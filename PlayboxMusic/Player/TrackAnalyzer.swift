import Accelerate
import AVFoundation
import CryptoKit

/// A detected musical key, shown in Camelot notation (8A, 5B…) like DJ apps.
struct MusicalKey: Codable, Hashable, Sendable {
    /// Pitch class of the tonic, C = 0 … B = 11.
    var tonic: Int
    var minor: Bool

    /// Camelot wheel number, 1–12.
    var camelotNumber: Int {
        // C major is 8B; each fifth up is one step round the wheel. A minor
        // shares 8 with its relative major three semitones up.
        let major = minor ? (tonic + 3) % 12 : tonic
        let number = (8 + 7 * major) % 12
        return number == 0 ? 12 : number
    }

    var camelot: String { "\(camelotNumber)\(minor ? "A" : "B")" }

    var name: String {
        let names = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        return names[tonic] + (minor ? "m" : "")
    }

    /// Keys that mix harmonically: same key, one step round the wheel, or
    /// the relative major/minor.
    func isCompatible(with other: MusicalKey) -> Bool {
        let a = camelotNumber, b = other.camelotNumber
        if minor == other.minor {
            let distance = abs(a - b)
            return distance <= 1 || distance == 11
        }
        return a == b
    }
}

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
    var key: MusicalKey?
    /// Peak level per 10 ms (0…255), for detailed waveforms in the mix editor.
    var peaks: Data

    static let peakSeconds = 0.01

    var beatLength: Double? { bpm.map { 60 / $0 } }

    /// Moves a time onto the nearest beat of the song's grid.
    func snapToBeat(_ time: Double) -> Double {
        guard let beat = beatLength, let first = firstBeat else { return time }
        return first + ((time - first) / beat).rounded() * beat
    }

    /// Moves a time onto the nearest bar (4 beats) of the song's grid.
    func snapToBar(_ time: Double) -> Double {
        guard let beat = beatLength, let first = firstBeat else { return time }
        let bar = beat * 4
        return first + ((time - first) / bar).rounded() * bar
    }

    /// Peak level 0…1 at a time, for drawing.
    func peak(at time: Double) -> Float {
        let index = Int(time / Self.peakSeconds)
        guard index >= 0, index < peaks.count else { return 0 }
        return Float(peaks[peaks.startIndex + index]) / 255
    }

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
    /// Decoding a whole song is heavy; a long queue analyses two at a time.
    private var freeSlots = 2
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Analysis-v3", isDirectory: true)
        // Older analyses have no key or detailed waveform.
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("Analysis-v2", isDirectory: true))
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
        let task = Task { () -> TrackAnalysis? in
            await self.acquire()
            let value = await Task.detached(priority: .utility) { Self.analyze(url) }.value
            self.release()
            return value
        }
        running[key] = task
        let value = await task.value
        running[key] = nil
        if let value {
            memory[key] = value
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: file) }
        }
        return value
    }

    private func acquire() async {
        if freeSlots > 0 {
            freeSlots -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { freeSlots += 1 } else { waiting.removeFirst().resume() }
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
        var peaks = Data()
        peaks.reserveCapacity(Int(Double(file.length) / sampleRate / TrackAnalysis.peakSeconds) + 1)
        var finePeak: Float = 0
        let chroma = ChromaAccumulator(sampleRate: sampleRate)
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
                finePeak = max(finePeak, abs(sample))
                chroma.add(sample)
                if fineCount == fineWindow {
                    fine.append(level(fineSum / Float(fineCount)))
                    peaks.append(UInt8(min(255, finePeak * 255)))
                    fineSum = 0
                    fineCount = 0
                    finePeak = 0
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
            envelope: envelope,
            key: chroma.key(),
            peaks: peaks
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

/// Builds a 12-bin pitch-class profile from the whole song and matches it
/// against Krumhansl's major and minor key profiles.
private final class ChromaAccumulator {
    private static let size = 4096
    private let decimation: Int
    private let rate: Double
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private var window = [Float](repeating: 0, count: ChromaAccumulator.size)
    private var frame: [Float] = []
    private var pending: Float = 0
    private var pendingCount = 0
    private var bins: [(index: Int, pitchClass: Int)] = []
    private var chroma = [Float](repeating: 0, count: 12)

    init(sampleRate: Double) {
        // Roughly 11 kHz is plenty for pitches up to 2 kHz.
        decimation = max(1, Int((sampleRate / 11025).rounded()))
        rate = sampleRate / Double(decimation)
        fft = vDSP.FFT(log2n: 12, radix: .radix2, ofType: DSPSplitComplex.self)
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM))
        frame.reserveCapacity(Self.size)
        for index in 1..<(Self.size / 2) {
            let frequency = Double(index) * rate / Double(Self.size)
            guard frequency >= 100, frequency <= 2000 else { continue }
            let midi = 69 + 12 * log2(frequency / 440)
            bins.append((index, ((Int(midi.rounded()) % 12) + 12) % 12))
        }
    }

    func add(_ sample: Float) {
        pending += sample
        pendingCount += 1
        guard pendingCount == decimation else { return }
        frame.append(pending / Float(decimation))
        pending = 0
        pendingCount = 0
        if frame.count == Self.size {
            process()
            frame.removeAll(keepingCapacity: true)
        }
    }

    private func process() {
        guard let fft else { return }
        let half = Self.size / 2
        var input = [Float](repeating: 0, count: Self.size)
        vDSP_vmul(frame, 1, window, 1, &input, 1, vDSP_Length(Self.size))
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                input.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                var output = split
                fft.forward(input: split, output: &output)
                vDSP_zvabs(&output, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        var frameChroma = [Float](repeating: 0, count: 12)
        for bin in bins { frameChroma[bin.pitchClass] += magnitudes[bin.index] }
        // Each frame counts equally, so loud passages do not dominate.
        guard let peak = frameChroma.max(), peak > 0 else { return }
        for pitch in 0..<12 { chroma[pitch] += frameChroma[pitch] / peak }
    }

    func key() -> MusicalKey? {
        guard chroma.contains(where: { $0 > 0 }) else { return nil }
        let major: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        var best: (score: Float, key: MusicalKey)?
        for tonic in 0..<12 {
            let rotated = (0..<12).map { chroma[($0 + tonic) % 12] }
            for (profile, isMinor) in [(major, false), (minor, true)] {
                let score = Self.correlation(rotated, profile)
                if best == nil || score > best!.score { best = (score, MusicalKey(tonic: tonic, minor: isMinor)) }
            }
        }
        return best?.key
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let meanA = a.reduce(0, +) / Float(a.count)
        let meanB = b.reduce(0, +) / Float(b.count)
        var numerator: Float = 0, sumA: Float = 0, sumB: Float = 0
        for index in a.indices {
            let x = a[index] - meanA, y = b[index] - meanB
            numerator += x * y
            sumA += x * x
            sumB += y * y
        }
        let denominator = (sumA * sumB).squareRoot()
        return denominator > 0 ? numerator / denominator : 0
    }
}

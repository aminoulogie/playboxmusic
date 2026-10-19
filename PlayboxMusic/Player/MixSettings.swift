import Combine
import Foundation

enum MixMode: String, Codable, CaseIterable, Identifiable {
    case off = "Off"
    case auto = "Auto"
    case manual = "Manual"
    var id: String { rawValue }
}

enum FadeCurve: String, Codable, CaseIterable, Identifiable {
    case linear = "Linear"
    case smooth = "Smooth"
    case quickCut = "Quick cut"
    var id: String { rawValue }

    /// Gains for the outgoing and incoming song at progress 0...1.
    func gains(_ t: Double) -> (out: Float, in: Float) {
        let p = min(max(t, 0), 1)
        switch self {
        case .linear:
            return (Float(1 - p), Float(p))
        case .smooth: // Equal power keeps loudness steady through the blend.
            return (Float(cos(p * .pi / 2)), Float(sin(p * .pi / 2)))
        case .quickCut:
            let incoming = min(1, p * 4)
            let outgoing = p < 0.75 ? 1 : max(0, 1 - (p - 0.75) * 4)
            return (Float(outgoing), Float(incoming))
        }
    }
}

/// A saved override for one specific song pair (Spotify-style transition editor).
struct TransitionOverride: Codable, Equatable {
    /// Seconds into the outgoing song where the blend starts.
    var mixStart: Double
    /// Seconds into the incoming song where it enters.
    var entry: Double
    var length: Double
    var curve: FadeCurve
}

/// The concrete plan for one transition.
struct TransitionPlan: Equatable {
    var mixStart: Double
    var entry: Double
    var length: Double
    var curve: FadeCurve
    /// Gain trims in dB to even out loudness.
    var outGain: Float
    var inGain: Float
    /// Playback rate for the incoming song during the blend (beat matching).
    var inRate: Float
}

@MainActor
final class MixSettings: ObservableObject {
    @Published var mode: MixMode { didSet { save() } }
    @Published var manualLength: Double { didSet { save() } }
    @Published var curve: FadeCurve { didSet { save() } }
    /// Manual: seconds before the end of the song where the blend starts.
    @Published var startBeforeEnd: Double { didSet { save() } }
    @Published var skipSilence: Bool { didSet { save() } }
    @Published var matchVolume: Bool { didSet { save() } }
    @Published var matchBeats: Bool { didSet { save() } }
    @Published private(set) var overrides: [String: TransitionOverride]

    private let defaults = UserDefaults.standard

    init() {
        mode = MixMode(rawValue: defaults.string(forKey: "mix.mode") ?? "") ?? .auto
        manualLength = defaults.object(forKey: "mix.length") as? Double ?? 6
        curve = FadeCurve(rawValue: defaults.string(forKey: "mix.curve") ?? "") ?? .smooth
        startBeforeEnd = defaults.object(forKey: "mix.startBeforeEnd") as? Double ?? 6
        skipSilence = defaults.object(forKey: "mix.skipSilence") as? Bool ?? true
        matchVolume = defaults.object(forKey: "mix.matchVolume") as? Bool ?? true
        matchBeats = defaults.object(forKey: "mix.matchBeats") as? Bool ?? true
        if let data = defaults.data(forKey: "mix.overrides"),
           let saved = try? JSONDecoder().decode([String: TransitionOverride].self, from: data) {
            overrides = saved
        } else {
            overrides = [:]
        }
    }

    nonisolated static func pairKey(_ from: Track, _ to: Track) -> String {
        from.url.lastPathComponent + "→" + to.url.lastPathComponent
    }

    func setOverride(_ value: TransitionOverride?, from: Track, to: Track) {
        overrides[Self.pairKey(from, to)] = value
        save()
    }

    func plan(from: Track, _ out: TrackAnalysis?, to: Track, _ incoming: TrackAnalysis?, outDuration: Double) -> TransitionPlan? {
        let end = (skipSilence ? out?.musicEnd : nil) ?? outDuration
        let entry = (skipSilence ? incoming?.leadIn : nil) ?? 0
        let gains = loudnessTrims(out, incoming)

        if let custom = overrides[Self.pairKey(from, to)] {
            return TransitionPlan(mixStart: custom.mixStart, entry: custom.entry, length: custom.length,
                                  curve: custom.curve, outGain: gains.0, inGain: gains.1, inRate: 1)
        }

        switch mode {
        case .off:
            return nil
        case .manual:
            let length = manualLength
            let start = max(0, end - max(startBeforeEnd, length))
            return TransitionPlan(mixStart: start, entry: entry, length: length, curve: curve,
                                  outGain: gains.0, inGain: gains.1, inRate: 1)
        case .auto:
            // Blend over the natural outro, like Spotify's automix: 4–12 s.
            var length = 6.0
            if let out { length = min(12, max(4, end - out.outroStart)) }
            var start = max(0, end - length)
            var entryPoint = entry
            var rate: Float = 1
            if matchBeats, let outBPM = out?.bpm, let inBPM = incoming?.bpm {
                let ratio = outBPM / inBPM
                if ratio > 0.94 && ratio < 1.06 {
                    rate = Float(ratio)
                    let period = 60 / outBPM
                    if let beat = out?.firstBeat {
                        start = beat + (((start - beat) / period).rounded()) * period
                    }
                    if let inBeat = incoming?.firstBeat, inBeat >= entry { entryPoint = inBeat }
                }
            }
            return TransitionPlan(mixStart: max(0, start), entry: entryPoint, length: length, curve: .smooth,
                                  outGain: gains.0, inGain: gains.1, inRate: rate)
        }
    }

    /// Gain trims (dB) that bring both songs toward a common loudness.
    func loudnessTrims(_ out: TrackAnalysis?, _ incoming: TrackAnalysis?) -> (Float, Float) {
        guard matchVolume else { return (0, 0) }
        let target = -16.0
        let trim: (TrackAnalysis?) -> Float = { analysis in
            guard let analysis else { return 0 }
            return Float(min(6, max(-9, target - analysis.loudness)))
        }
        return (trim(out), trim(incoming))
    }

    private func save() {
        defaults.set(mode.rawValue, forKey: "mix.mode")
        defaults.set(manualLength, forKey: "mix.length")
        defaults.set(curve.rawValue, forKey: "mix.curve")
        defaults.set(startBeforeEnd, forKey: "mix.startBeforeEnd")
        defaults.set(skipSilence, forKey: "mix.skipSilence")
        defaults.set(matchVolume, forKey: "mix.matchVolume")
        defaults.set(matchBeats, forKey: "mix.matchBeats")
        if let data = try? JSONEncoder().encode(overrides) { defaults.set(data, forKey: "mix.overrides") }
    }
}

/// Ten-band equalizer state (32 Hz – 16 kHz) with presets.
@MainActor
final class EqualizerSettings: ObservableObject {
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let presets: [(String, [Float])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Treble Boost", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("Vocal", [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        ("Rock", [5, 4, 2, -1, -2, -1, 2, 3, 4, 4]),
        ("Pop", [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
        ("Hip-Hop", [5, 5, 3, 1, -1, -1, 1, 0, 2, 3]),
        ("Electronic", [4, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        ("Jazz", [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
        ("Classical", [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
        ("Loudness", [6, 4, 0, 0, -2, 0, -1, -2, 5, 2])
    ]

    @Published var enabled: Bool { didSet { save() } }
    @Published var gains: [Float] { didSet { save() } }
    @Published var presetName: String { didSet { save() } }

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "eq.enabled") as? Bool ?? false
        gains = (defaults.array(forKey: "eq.gains") as? [Float]).flatMap { $0.count == 10 ? $0 : nil }
            ?? Array(repeating: 0, count: 10)
        presetName = defaults.string(forKey: "eq.preset") ?? "Flat"
    }

    func apply(preset name: String) {
        guard let preset = Self.presets.first(where: { $0.0 == name }) else { return }
        presetName = name
        gains = preset.1
        enabled = true
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: "eq.enabled")
        defaults.set(gains, forKey: "eq.gains")
        defaults.set(presetName, forKey: "eq.preset")
    }
}

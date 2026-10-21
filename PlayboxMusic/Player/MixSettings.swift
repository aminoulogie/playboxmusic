import Combine
import Foundation

enum MixMode: String, Codable, CaseIterable, Identifiable {
    case off = "Off"
    case auto = "Mix"
    var id: String { rawValue }
}

/// How loud each song is through the transition (Spotify's "Volume").
enum MixVolume: String, Codable, CaseIterable, Identifiable {
    case overlap = "Overlap"
    case crossfade = "Crossfade"
    case fadeIn = "Fade in"
    case fadeOut = "Fade out"
    case cut = "Cut"
    var id: String { rawValue }

    /// Gains for the outgoing and incoming song at progress 0...1.
    func gains(_ t: Double) -> (out: Float, in: Float) {
        let p = min(max(t, 0), 1)
        switch self {
        case .overlap: // Both at full volume; quick ramps at the edges.
            return (Float(1 - smoothstep(0.85, 1, p)), Float(smoothstep(0, 0.12, p)))
        case .crossfade: // Equal power keeps loudness steady through the blend.
            return (Float(cos(p * .pi / 2)), Float(sin(p * .pi / 2)))
        case .fadeIn:
            return (Float(1 - smoothstep(0.9, 1, p)), Float(sin(p * .pi / 2)))
        case .fadeOut:
            return (Float(cos(p * .pi / 2)), Float(smoothstep(0, 0.08, p)))
        case .cut:
            return (Float(1 - smoothstep(0.49, 0.51, p)), Float(smoothstep(0.49, 0.51, p)))
        }
    }
}

/// When the basslines swap (Spotify's "EQ"). Two basslines at once clash,
/// so the incoming song plays without bass until the swap.
enum MixEQ: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    case startBassSwap = "Start bass swap"
    case midBassSwap = "Mid bass swap"
    case endBassSwap = "End bass swap"
    var id: String { rawValue }

    var swapPoint: Double? {
        switch self {
        case .none: return nil
        case .startBassSwap: return 0.15
        case .midBassSwap: return 0.5
        case .endBassSwap: return 0.85
        }
    }

    /// Bass level 0 (killed) … 1 (full) for each song at progress 0...1.
    func bass(_ t: Double, beatFraction: Double) -> (out: Double, in: Double) {
        guard let point = swapPoint else { return (1, 1) }
        let half = max(0.01, beatFraction / 2)
        let swap = smoothstep(point - half, point + half, t)
        return (1 - swap, swap)
    }
}

/// Filters and echoes on top of the blend (Spotify's "Effects").
enum MixEffect: String, Codable, CaseIterable, Identifiable {
    case none = "None"
    /// The incoming song starts muffled and opens up: a rise.
    case lowPass = "Low pass"
    /// The outgoing song thins out from the bottom up.
    case highPass = "High pass"
    /// The outgoing song echoes away on the beat.
    case echo = "Echo out"
    var id: String { rawValue }

    /// Effect amount 0…1 at progress 0...1, for drawing and automation.
    func amount(_ t: Double) -> Double {
        let p = min(max(t, 0), 1)
        switch self {
        case .none: return 0
        case .lowPass: return 1 - pow(p, 2.2)
        case .highPass: return pow(p, 1.6)
        case .echo: return smoothstep(0.1, 0.5, p)
        }
    }

    /// Which song the effect is applied to.
    var onIncoming: Bool { self == .lowPass }
}

/// One-tap transition recipes, as in Spotify's mix editor.
enum MixPreset: String, Codable, CaseIterable, Identifiable {
    case auto = "Auto"
    case fade = "Fade"
    case rise = "Rise"
    case blend = "Blend"
    case echo = "Echo"
    case cut = "Cut"
    var id: String { rawValue }

    var symbol: String? { self == .auto ? "sparkles" : nil }

    /// Volume, EQ and effect for a fixed preset (Auto is planned per pair).
    var recipe: (volume: MixVolume, eq: MixEQ, effect: MixEffect)? {
        switch self {
        case .auto: return nil
        case .fade: return (MixVolume.crossfade, MixEQ.none, MixEffect.none)
        case .rise: return (MixVolume.overlap, MixEQ.endBassSwap, MixEffect.lowPass)
        case .blend: return (MixVolume.crossfade, MixEQ.midBassSwap, MixEffect.none)
        case .echo: return (MixVolume.cut, MixEQ.none, MixEffect.echo)
        case .cut: return (MixVolume.cut, MixEQ.none, MixEffect.none)
        }
    }

    static func matching(_ volume: MixVolume, _ eq: MixEQ, _ effect: MixEffect) -> MixPreset? {
        allCases.first { preset in
            guard let recipe = preset.recipe else { return false }
            return recipe.volume == volume && recipe.eq == eq && recipe.effect == effect
        }
    }
}

/// A saved transition for one specific song pair (Spotify-style editor).
/// Unset fields fall back to the automatic plan.
struct TransitionOverride: Codable, Equatable {
    var preset: MixPreset?
    var bars: Int?
    var volume: MixVolume?
    var eq: MixEQ?
    var effect: MixEffect?
    /// Seconds into the outgoing song where the blend starts.
    var mixStart: Double?
    /// Seconds into the incoming song where it enters.
    var entry: Double?

    var isEmpty: Bool { self == TransitionOverride() }
}

/// The concrete plan for one transition.
struct TransitionPlan: Equatable {
    var mixStart: Double
    var entry: Double
    var length: Double
    var bars: Int
    var volume: MixVolume
    var eq: MixEQ
    var effect: MixEffect
    /// The preset this plan matches, if any (Auto when nothing was edited).
    var preset: MixPreset?
    /// Gain trims in dB to even out loudness.
    var outGain: Float
    var inGain: Float
    /// Playback rate for the incoming song during the blend (beat matching).
    var inRate: Float
    /// Length of one beat of the outgoing song, in seconds.
    var beat: Double

    var mixEnd: Double { mixStart + length }
}

func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

@MainActor
final class MixSettings: ObservableObject {
    @Published var mode: MixMode { didSet { save() } }
    /// Preset used for transitions you have not edited.
    @Published var defaultPreset: MixPreset { didSet { save() } }
    @Published var skipSilence: Bool { didSet { save() } }
    @Published var matchVolume: Bool { didSet { save() } }
    @Published var matchBeats: Bool { didSet { save() } }
    @Published private(set) var overrides: [String: TransitionOverride]

    static let barChoices = [1, 2, 4, 8, 16, 32]

    private let defaults = UserDefaults.standard

    init() {
        mode = MixMode(rawValue: defaults.string(forKey: "mix.v2.mode") ?? "") ?? .auto
        defaultPreset = MixPreset(rawValue: defaults.string(forKey: "mix.v2.preset") ?? "") ?? .auto
        skipSilence = defaults.object(forKey: "mix.skipSilence") as? Bool ?? true
        matchVolume = defaults.object(forKey: "mix.matchVolume") as? Bool ?? true
        matchBeats = defaults.object(forKey: "mix.matchBeats") as? Bool ?? true
        if let data = defaults.data(forKey: "mix.v2.overrides"),
           let saved = try? JSONDecoder().decode([String: TransitionOverride].self, from: data) {
            overrides = saved
        } else {
            overrides = [:]
        }
    }

    var isOn: Bool { mode != .off }

    nonisolated static func pairKey(_ from: Track, _ to: Track) -> String {
        from.url.lastPathComponent + "→" + to.url.lastPathComponent
    }

    func transitionOverride(from: Track, to: Track) -> TransitionOverride {
        overrides[Self.pairKey(from, to)] ?? TransitionOverride()
    }

    func setOverride(_ value: TransitionOverride?, from: Track, to: Track) {
        overrides[Self.pairKey(from, to)] = (value?.isEmpty ?? true) ? nil : value
        save()
    }

    /// Plans a transition. `force` plans even when mixing is off (editor).
    func plan(from: Track, _ out: TrackAnalysis?, to: Track, _ incoming: TrackAnalysis?,
              outDuration: Double, force: Bool = false) -> TransitionPlan? {
        guard isOn || force else { return nil }
        let custom = transitionOverride(from: from, to: to)
        let end = (skipSilence ? out?.musicEnd : nil) ?? outDuration
        let gains = loudnessTrims(out, incoming)
        let ratio = tempoRatio(out, incoming)
        let beat = out?.beatLength ?? 0.5
        let bar = beat * 4
        let keysMatch = keysCompatible(out, incoming)

        // Spotify's Auto: a long overlapping blend with a bass swap when the
        // beats can be matched, a shorter filtered one when the keys clash,
        // and a plain crossfade when the tempos are too far apart.
        var volume = MixVolume.crossfade
        var eq = MixEQ.none
        var effect = MixEffect.none
        var bars = 4
        let preset = custom.preset ?? defaultPreset
        if ratio != nil, out?.firstBeat != nil {
            let outro = out.map { max(0, end - $0.outroStart) } ?? 8 * bar
            bars = Self.powerOfTwoBars(outro / bar, within: 8...16)
            volume = .overlap
            eq = .midBassSwap
            if !keysMatch {
                bars = min(bars, 8)
                eq = .endBassSwap
                effect = .lowPass
            }
        } else {
            bars = 4
            volume = .crossfade
        }
        if let recipe = preset.recipe {
            volume = recipe.volume
            eq = recipe.eq
            effect = recipe.effect
        }
        if let value = custom.bars { bars = value }
        if let value = custom.volume { volume = value }
        if let value = custom.eq { eq = value }
        if let value = custom.effect { effect = value }

        let length = Double(bars) * bar
        // End the blend on a bar line just before the music ends.
        var start = max(0, end - length)
        if ratio != nil, let first = out?.firstBeat {
            start = first + ((start - first) / bar).rounded(.down) * bar
        }
        var entry = (skipSilence ? incoming?.leadIn : nil) ?? 0
        if ratio != nil, let inBeat = incoming?.firstBeat, inBeat >= entry - 0.05 { entry = inBeat }
        if let value = custom.mixStart { start = value }
        if let value = custom.entry { entry = value }

        let edited = custom.volume != nil || custom.eq != nil || custom.effect != nil
        let shownPreset: MixPreset? = edited ? MixPreset.matching(volume, eq, effect) : preset
        return TransitionPlan(
            mixStart: max(0, min(start, max(0, outDuration - 0.5))), entry: max(0, entry),
            length: length, bars: bars, volume: volume, eq: eq, effect: effect, preset: shownPreset,
            outGain: gains.0, inGain: gains.1, inRate: ratio ?? 1, beat: beat
        )
    }

    private static func powerOfTwoBars(_ value: Double, within range: ClosedRange<Int>) -> Int {
        var bars = range.lowerBound
        while bars * 2 <= range.upperBound, Double(bars * 2) <= value { bars *= 2 }
        return bars
    }

    func keysCompatible(_ out: TrackAnalysis?, _ incoming: TrackAnalysis?) -> Bool {
        guard let a = out?.key, let b = incoming?.key else { return true }
        return a.isCompatible(with: b)
    }

    /// Playback rate that brings the incoming song to the outgoing tempo,
    /// when the two are within ±8% (also tries half/double time).
    func tempoRatio(_ out: TrackAnalysis?, _ incoming: TrackAnalysis?) -> Float? {
        guard matchBeats, let a = out?.bpm, let b = incoming?.bpm else { return nil }
        for candidate in [a / b, a / (b * 2), (a * 2) / b] where candidate > 0.92 && candidate < 1.08 {
            return Float(candidate)
        }
        return nil
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
        defaults.set(mode.rawValue, forKey: "mix.v2.mode")
        defaults.set(defaultPreset.rawValue, forKey: "mix.v2.preset")
        defaults.set(skipSilence, forKey: "mix.skipSilence")
        defaults.set(matchVolume, forKey: "mix.matchVolume")
        defaults.set(matchBeats, forKey: "mix.matchBeats")
        if let data = try? JSONEncoder().encode(overrides) { defaults.set(data, forKey: "mix.v2.overrides") }
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

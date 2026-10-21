import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit
import VLCKit

/// One playback lane: player → time-pitch (beat matching) → gain trim
/// (volume matching) → DJ filters → echo → fader (crossfades).
@MainActor
private final class AudioDeck {
    let player = AVAudioPlayerNode()
    let timePitch = AVAudioUnitTimePitch()
    let trim = AVAudioUnitEQ(numberOfBands: 0)
    /// High-pass, low-pass and a bass-kill shelf for Spotify-style mixes.
    let filter = AVAudioUnitEQ(numberOfBands: 3)
    let delay = AVAudioUnitDelay()
    let fader = AVAudioMixerNode()
    private(set) var file: AVAudioFile?
    private(set) var url: URL?
    private var segmentStart: Double = 0
    private var pausedAt: Double?
    private var generation = 0

    var duration: Double {
        guard let file else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var isActive: Bool { file != nil && player.isPlaying }

    var currentTime: Double {
        guard file != nil else { return 0 }
        if let pausedAt { return pausedAt }
        guard let nodeTime = player.lastRenderTime, let time = player.playerTime(forNodeTime: nodeTime) else {
            return segmentStart
        }
        return min(duration, segmentStart + Double(time.sampleTime) / time.sampleRate)
    }

    func attach(to engine: AVAudioEngine, output: AVAudioNode) {
        [player, timePitch, trim, filter, delay, fader].forEach(engine.attach)
        let highPass = filter.bands[0]
        highPass.filterType = .highPass
        highPass.frequency = 20
        highPass.bandwidth = 0.5
        let lowPass = filter.bands[1]
        lowPass.filterType = .lowPass
        lowPass.frequency = 20000
        lowPass.bandwidth = 0.5
        let bass = filter.bands[2]
        bass.filterType = .lowShelf
        bass.frequency = 220
        bass.gain = 0
        delay.feedback = 50
        delay.lowPassCutoff = 6000
        delay.wetDryMix = 0
        resetEffects()
        engine.connect(timePitch, to: trim, format: nil)
        engine.connect(trim, to: filter, format: nil)
        engine.connect(filter, to: delay, format: nil)
        engine.connect(delay, to: fader, format: nil)
        engine.connect(fader, to: output, format: nil)
    }

    func load(_ url: URL, engine: AVAudioEngine) throws {
        stop()
        let file = try AVAudioFile(forReading: url)
        engine.connect(player, to: timePitch, format: file.processingFormat)
        self.file = file
        self.url = url
    }

    /// Plays from `seconds`. `onEnd` fires only if this segment reaches its end.
    func play(from seconds: Double, onEnd: @escaping @MainActor () -> Void) {
        guard let file else { return }
        player.stop()
        generation += 1
        let token = generation
        let rate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, min(seconds, duration - 0.05)) * rate)
        let frames = AVAudioFrameCount(max(1, file.length - startFrame))
        segmentStart = Double(startFrame) / rate
        pausedAt = nil
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frames, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                onEnd()
            }
        }
        player.play()
    }

    /// Sets the high-pass cutoff; below ~25 Hz the filter is bypassed.
    func setHighPass(_ frequency: Float) {
        filter.bands[0].bypass = frequency < 25
        filter.bands[0].frequency = min(20000, max(20, frequency))
    }

    /// Sets the low-pass cutoff; from ~19 kHz up the filter is bypassed.
    func setLowPass(_ frequency: Float) {
        filter.bands[1].bypass = frequency >= 19000
        filter.bands[1].frequency = min(20000, max(40, frequency))
    }

    /// Bass level from 0 (killed, like a DJ mixer's low EQ) to 1 (full).
    func setBass(_ level: Double) {
        filter.bands[2].bypass = level >= 0.999
        filter.bands[2].gain = Float(-30 * (1 - min(max(level, 0), 1)))
    }

    /// Echo amount 0…1 with repeats on a dotted eighth of the beat.
    func setEcho(_ amount: Double, beat: Double = 0.5) {
        delay.bypass = amount <= 0.005
        delay.delayTime = TimeInterval(min(2, max(0.05, beat * 0.75)))
        delay.wetDryMix = Float(50 * min(max(amount, 0), 1))
    }

    func resetEffects() {
        fader.outputVolume = 1
        player.volume = 1
        setHighPass(0)
        setLowPass(20000)
        setBass(1)
        setEcho(0)
    }

    // An idle deck has no connected input; pausing or playing it would
    // raise an exception, so every transport call checks for a file.
    func pause() {
        guard file != nil, pausedAt == nil else { return }
        pausedAt = currentTime
        player.pause()
    }

    func resume() {
        guard file != nil, pausedAt != nil else { return }
        pausedAt = nil
        player.play()
    }

    func stop() {
        generation += 1
        player.stop()
        pausedAt = nil
        segmentStart = 0
        timePitch.rate = 1
        trim.globalGain = 0
        resetEffects()
    }

    func unload() {
        stop()
        file = nil
        url = nil
    }
}

/// Playback time lives in its own object so only the views that show it
/// (scrubber, times, lyrics) redraw as it advances.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published fileprivate(set) var elapsed: Double = 0
    @Published fileprivate(set) var duration: Double = 0
    /// Progress 0…1 through the transition while two songs are mixing.
    @Published fileprivate(set) var mixProgress: Double?
    fileprivate(set) var updatedAt = Date()
    fileprivate(set) var running = false

    var progress: Double { duration > 0 ? min(max(elapsed / duration, 0), 1) : 0 }

    /// Smooth position between 50 ms updates, for 120 Hz drawing.
    func elapsed(at date: Date) -> Double {
        guard running else { return elapsed }
        return min(duration, elapsed + date.timeIntervalSince(updatedAt))
    }

    fileprivate func set(elapsed: Double, duration: Double, running: Bool) {
        if abs(self.elapsed - elapsed) > 0.001 { self.elapsed = elapsed }
        if self.duration != duration { self.duration = duration }
        self.running = running
        updatedAt = Date()
    }
}

enum RepeatMode: String, CaseIterable {
    case off, all, one
}

/// Plays local audio with AVAudioEngine (MP3, AAC, ALAC, FLAC, WAV, AIFF):
/// two decks for Spotify-style mixing, 10-band EQ, loudness matching and
/// beat-matched blends. Formats AVFoundation cannot read (Ogg, Opus, APE,
/// WMA) fall back to VLCKit without mixing or EQ.
@MainActor
final class MusicPlayer: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var isPlaying = false
    let clock = PlaybackClock()
    var elapsed: Double { clock.elapsed }
    var duration: Double { clock.duration }
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var artwork: UIImage?
    /// A deep colour taken from the artwork, for backgrounds.
    @Published private(set) var artworkColor: Color?
    /// +1 when moving forward through the queue, -1 when going back, so
    /// covers and titles slide the right way.
    @Published private(set) var skipDirection = 1
    @Published private(set) var currentMeta: TrackMeta?
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: RepeatMode = .off
    @Published private(set) var isMixing = false
    @Published private(set) var nextPlan: TransitionPlan?
    @Published var notice: String?

    /// Supplies saved catalog details (title, artist, cover) for a track.
    var metaProvider: ((Track) -> TrackMeta?)?
    /// Supplies songs to continue with when the queue runs out.
    var similarProvider: ((Track, [Track]) -> [Track])?

    let mix = MixSettings()
    let equalizer = EqualizerSettings()

    private let engine = AVAudioEngine()
    private let bus = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let decks = [AudioDeck(), AudioDeck()]
    private var active = 0
    private var vlc: VLCMediaPlayer?
    private var vlcStarted = false
    private var userPaused = false
    private var originalOrder: [Track]?
    private var tickTask: Task<Void, Never>?
    private var mixStartedAt: Date?
    private var mixPlan: TransitionPlan?
    private var rateRestore: (from: Float, startedAt: Date)?
    private var planTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private var deck: AudioDeck { decks[active] }
    private var otherDeck: AudioDeck { decks[1 - active] }

    var progress: Double { clock.progress }
    var hasNext: Bool { index + 1 < queue.count || repeatMode == .all }
    var upcoming: Track? { index + 1 < queue.count ? queue[index + 1] : nil }
    var isLossless: Bool {
        ["flac", "alac", "wav", "aif", "aiff", "ape", "wv"].contains(current?.url.pathExtension.lowercased() ?? "")
    }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        engine.attach(bus)
        engine.attach(eq)
        decks.forEach { $0.attach(to: engine, output: bus) }
        engine.connect(bus, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        for (band, frequency) in zip(eq.bands, EqualizerSettings.frequencies) {
            band.filterType = .parametric
            band.frequency = frequency
            band.bandwidth = 1
            band.bypass = false
        }
        applyEqualizer()
        equalizer.objectWillChange
            .sink { [weak self] in Task { @MainActor in self?.applyEqualizer() } }
            .store(in: &cancellables)
        mix.objectWillChange
            .sink { [weak self] in Task { @MainActor in self?.preparePlan() } }
            .store(in: &cancellables)
        configureRemoteCommands()
        observeSession()
    }

    // MARK: Queue

    func play(_ tracks: [Track], startAt start: Int) {
        guard tracks.indices.contains(start) else { return }
        originalOrder = nil
        skipDirection = 1
        queue = tracks
        index = start
        if shuffle { shuffleUpcoming() }
        startCurrent(from: 0)
    }

    func playNext(_ track: Track) {
        guard current != nil else { return play([track], startAt: 0) }
        queue.insert(track, at: min(index + 1, queue.count))
        preparePlan()
    }

    func addToQueue(_ track: Track) {
        guard current != nil else { return play([track], startAt: 0) }
        queue.append(track)
        preparePlan()
    }

    func moveQueue(from source: IndexSet, to destination: Int) {
        let playing = current
        queue.move(fromOffsets: source, toOffset: destination)
        if let playing, let newIndex = queue.firstIndex(of: playing) { index = newIndex }
        preparePlan()
    }

    func removeFromQueue(at offsets: IndexSet) {
        let playing = current
        let removingCurrent = offsets.contains(index)
        queue.remove(atOffsets: offsets)
        guard !queue.isEmpty else { return stop() }
        if removingCurrent {
            index = min(index, queue.count - 1)
            startCurrent(from: 0)
        } else if let playing, let newIndex = queue.firstIndex(of: playing) {
            index = newIndex
            preparePlan()
        }
    }

    func toggleShuffle() {
        shuffle.toggle()
        if shuffle {
            originalOrder = queue
            shuffleUpcoming()
        } else if let original = originalOrder, let playing = current {
            queue = original
            index = original.firstIndex(of: playing) ?? 0
            originalOrder = nil
        }
        preparePlan()
    }

    func cycleRepeat() {
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
        preparePlan()
    }

    private func shuffleUpcoming() {
        guard index + 1 < queue.count else { return }
        let rest = queue[(index + 1)...].shuffled()
        queue.replaceSubrange((index + 1)..., with: rest)
    }

    // MARK: Transport

    func togglePlayback() {
        guard current != nil else { return }
        if isPlaying {
            userPaused = true
            // Keep the engine running: scheduling on a paused engine throws.
            if let vlc { vlc.pause() } else { decks.forEach { $0.pause() } }
        } else {
            userPaused = false
            if let vlc {
                vlc.play()
            } else if deck.file != nil {
                try? AVAudioSession.sharedInstance().setActive(true)
                if !engine.isRunning { try? engine.start() }
                if deck.isActive || deck.currentTime > 0 {
                    decks.forEach { $0.resume() }
                } else {
                    startCurrent(from: 0)
                }
            } else {
                startCurrent(from: 0)
            }
        }
        refresh()
    }

    func next() {
        cancelMix()
        skipDirection = 1
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all, !queue.isEmpty {
            index = 0
        } else if !appendSimilar() {
            return
        } else {
            index += 1
        }
        startCurrent(from: 0)
    }

    func previous() {
        cancelMix()
        if elapsed > 3 || index == 0 {
            seek(to: 0)
        } else {
            skipDirection = -1
            index -= 1
            startCurrent(from: 0)
        }
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        cancelMix()
        let target = min(max(fraction, 0), 0.999) * duration
        if let vlc {
            vlc.position = target / duration
        } else {
            if !engine.isRunning { try? engine.start() }
            guard engine.isRunning else { return }
            deck.play(from: target) { [weak self] in self?.trackEnded() }
            if userPaused { deck.pause() }
        }
        clock.set(elapsed: target, duration: duration, running: isPlaying)
        updateNowPlaying()
        // A started (or cancelled) mix used up the plan; plan it again.
        if nextPlan == nil { preparePlan() }
    }

    /// Plays a transition from two bars before it starts, so it can be heard.
    func previewTransition(from: Track, to: Track, at seconds: Double) {
        let start = max(0, seconds)
        if current == from, upcoming == to, vlc == nil, deck.file != nil, deck.duration > 0 {
            userPaused = false
            if !engine.isRunning { try? engine.start() }
            seek(to: start / deck.duration)
            if !deck.isActive { decks.forEach { $0.resume() } }
            refresh()
            return
        }
        if let position = queue.firstIndex(of: from), queue[safe: position + 1] == to {
            index = position
        } else {
            originalOrder = nil
            queue = [from, to]
            index = 0
        }
        startCurrent(from: start)
    }

    enum QueueOrder: String, CaseIterable, Identifiable {
        case tempo = "Tempo (BPM)"
        case key = "Key"
        case harmonic = "Smart mix order"
        var id: String { rawValue }
    }

    /// Reorders the songs after the current one, like a DJ planning a set.
    func sortUpcoming(_ order: QueueOrder) async {
        guard index + 1 < queue.count else { return }
        let before = queue
        let start = queue[index]
        let rest = Array(queue[(index + 1)...])
        var facts: [Track: TrackAnalysis] = [:]
        for track in [start] + rest {
            if let analysis = await TrackAnalyzer.shared.analysis(for: track.url) { facts[track] = analysis }
        }
        guard queue == before else { return }
        let sorted: [Track]
        switch order {
        case .tempo:
            sorted = rest.sorted { (facts[$0]?.bpm ?? .infinity) < (facts[$1]?.bpm ?? .infinity) }
        case .key:
            sorted = rest.sorted { a, b in
                let x = facts[a]?.key, y = facts[b]?.key
                return (x?.camelotNumber ?? 99, x?.minor == false ? 1 : 0)
                    < (y?.camelotNumber ?? 99, y?.minor == false ? 1 : 0)
            }
        case .harmonic:
            // Greedy chain: each next song has a compatible key and the
            // closest tempo to the one before it.
            var remaining = rest
            var chain: [Track] = []
            var last = facts[start]
            while !remaining.isEmpty {
                let pick = remaining.indices.min { lhs, rhs in
                    Self.mixCost(last, facts[remaining[lhs]]) < Self.mixCost(last, facts[remaining[rhs]])
                }!
                let track = remaining.remove(at: pick)
                chain.append(track)
                last = facts[track] ?? last
            }
            sorted = chain
        }
        originalOrder = nil
        shuffle = false
        queue.replaceSubrange((index + 1)..., with: sorted)
        preparePlan()
    }

    private static func mixCost(_ a: TrackAnalysis?, _ b: TrackAnalysis?) -> Double {
        guard let b else { return 1000 }
        var cost = 0.0
        if let x = a?.key, let y = b.key, !x.isCompatible(with: y) { cost += 12 }
        if let x = a?.bpm, let y = b.bpm {
            let ratio = max(x, y) / min(x, y)
            cost += min(abs(ratio - 1), abs(ratio - 2)) * 100
        }
        return cost
    }

    private func stop() {
        cancelMix()
        tickTask?.cancel()
        decks.forEach { $0.unload() }
        vlc?.stop()
        vlc = nil
        current = nil
        currentMeta = nil
        artwork = nil
        artworkColor = nil
        isPlaying = false
        clock.set(elapsed: 0, duration: 0, running: false)
        nextPlan = nil
        updateNowPlaying()
    }

    // MARK: Starting tracks

    private func startCurrent(from seconds: Double, attempts: Int = 0) {
        guard queue.indices.contains(index) else { return stop() }
        let track = queue[index]
        cancelMix()
        vlc?.stop()
        vlc = nil
        decks.forEach { $0.unload() }
        userPaused = false
        try? AVAudioSession.sharedInstance().setActive(true)

        do {
            try deck.load(track.url, engine: engine)
            if !engine.isRunning { try engine.start() }
            Task { [weak self] in
                guard let analysis = await TrackAnalyzer.shared.analysis(for: track.url),
                      let self, self.current == track, !self.isMixing else { return }
                if self.mix.matchVolume { self.deck.trim.globalGain = self.mix.loudnessTrims(analysis, nil).0 }
            }
            deck.play(from: seconds) { [weak self] in self?.trackEnded() }
        } catch {
            // AVFoundation cannot read this format; let VLC try.
            guard startVLC(track.url) else {
                return skipBroken(track, attempts: attempts)
            }
        }

        setCurrent(track)
        startTicking()
        preparePlan()
    }

    private func setCurrent(_ track: Track) {
        current = track
        currentMeta = metaProvider?(track)
        clock.set(elapsed: vlc == nil ? deck.currentTime : 0, duration: vlc == nil ? deck.duration : 0, running: true)
        isPlaying = true
        artwork = nil
        loadArtwork(for: track)
        updateNowPlaying()
    }

    private func startVLC(_ url: URL) -> Bool {
        guard let media = VLCMedia(url: url) else { return false }
        let player = VLCMediaPlayer()
        player.media = media
        player.play()
        vlc = player
        vlcStarted = false
        return true
    }

    private func skipBroken(_ track: Track, attempts: Int) {
        notice = "Skipped \u{201C}\(metaProvider?(track)?.title ?? track.title)\u{201D}: the file can't be played."
        guard attempts < queue.count, index + 1 < queue.count else { return stop() }
        index += 1
        startCurrent(from: 0, attempts: attempts + 1)
    }

    private func trackEnded() {
        guard !isMixing else { return }
        skipDirection = 1
        if repeatMode == .one {
            startCurrent(from: 0)
        } else if index + 1 < queue.count {
            index += 1
            startCurrent(from: 0)
        } else if repeatMode == .all, !queue.isEmpty {
            index = 0
            startCurrent(from: 0)
        } else if appendSimilar() {
            index += 1
            startCurrent(from: 0)
        } else {
            // Unload so Play starts the last song again from the top.
            decks.forEach { $0.unload() }
            isPlaying = false
            userPaused = true
            clock.set(elapsed: 0, duration: duration, running: false)
            updateNowPlaying()
        }
    }

    /// Autoplay: continue with similar downloaded songs when the queue ends.
    @discardableResult
    private func appendSimilar() -> Bool {
        guard let current, let more = similarProvider?(current, queue), !more.isEmpty else { return false }
        queue.append(contentsOf: more)
        return true
    }

    // MARK: Mixing

    /// Plans the transition into the upcoming song once both are analysed.
    private func preparePlan() {
        planTask?.cancel()
        nextPlan = nil
        guard vlc == nil, repeatMode != .one, let from = current, let to = upcoming,
              Self.engineReadable(to.url) else { return }
        let outDuration = deck.duration
        guard mix.isOn else { return }
        planTask = Task { [weak self] in
            async let outAnalysis = TrackAnalyzer.shared.analysis(for: from.url)
            async let inAnalysis = TrackAnalyzer.shared.analysis(for: to.url)
            let (out, incoming) = await (outAnalysis, inAnalysis)
            guard let self, !Task.isCancelled, self.current == from, self.upcoming == to else { return }
            self.nextPlan = self.mix.plan(from: from, out, to: to, incoming, outDuration: outDuration)
        }
    }

    private static func engineReadable(_ url: URL) -> Bool {
        !["ogg", "oga", "opus", "ape", "wma", "wv"].contains(url.pathExtension.lowercased())
    }

    private func beginMix(_ plan: TransitionPlan) {
        guard let next = upcoming else { return }
        let incoming = otherDeck
        do { try incoming.load(next.url, engine: engine) } catch { return }
        incoming.trim.globalGain = plan.inGain
        deck.trim.globalGain = plan.outGain
        incoming.timePitch.rate = plan.inRate
        deck.setEcho(0, beat: plan.beat)
        mixPlan = plan
        isMixing = true
        applyAutomation(plan, at: 0)
        incoming.play(from: plan.entry) { [weak self] in self?.trackEnded() }
        // Start the clock from where the outgoing song really is, so the
        // blend stays on the beat grid even if this tick ran late.
        mixStartedAt = Date().addingTimeInterval(-max(0, deck.currentTime - plan.mixStart))
    }

    /// Sets volume, bass EQ and effects for both decks at progress t.
    private func applyAutomation(_ plan: TransitionPlan, at t: Double) {
        let outgoing = deck, incoming = otherDeck
        let gains = plan.volume.gains(t)
        let amount = plan.effect.amount(t)
        if plan.effect == .echo {
            // Cut the dry signal but keep the echoes ringing, then fade them.
            outgoing.player.volume = gains.out
            outgoing.fader.outputVolume = Float(1 - smoothstep(0.75, 1, t))
            outgoing.setEcho(amount, beat: plan.beat)
        } else {
            outgoing.fader.outputVolume = gains.out
        }
        incoming.fader.outputVolume = gains.in
        let bass = plan.eq.bass(t, beatFraction: plan.length > 0 ? plan.beat / plan.length : 0.1)
        outgoing.setBass(bass.out)
        incoming.setBass(bass.in)
        switch plan.effect {
        case .lowPass:
            // Opens from 250 Hz to the full range: the incoming song rises in.
            incoming.setLowPass(Float(250 * pow(80, 1 - amount)))
        case .highPass:
            outgoing.setHighPass(Float(20 * pow(100, amount)))
        case .echo, .none:
            break
        }
    }

    private func advanceMix(now: Date) {
        guard let plan = mixPlan, let started = mixStartedAt else { return }
        let t = plan.length > 0 ? now.timeIntervalSince(started) / plan.length : 1
        applyAutomation(plan, at: t)
        let shown = (min(max(t, 0), 1) * 100).rounded() / 100
        if clock.mixProgress != shown { clock.mixProgress = shown }
        guard t >= 1 else { return }

        // Hand over to the incoming deck.
        deck.unload()
        active = 1 - active
        deck.resetEffects()
        clock.mixProgress = nil
        skipDirection = 1
        index += 1
        isMixing = false
        mixPlan = nil
        mixStartedAt = nil
        if plan.inRate != 1 { rateRestore = (plan.inRate, now) }
        if let track = queue[safe: index] { setCurrent(track) }
        preparePlan()
    }

    private func cancelMix() {
        guard isMixing else { return }
        otherDeck.unload()
        deck.resetEffects()
        clock.mixProgress = nil
        isMixing = false
        mixPlan = nil
        mixStartedAt = nil
    }

    // MARK: Clock

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                // Automation runs finer while two songs are blending.
                let interval = self?.isMixing == true ? 20 : 50
                do { try await Task.sleep(for: .milliseconds(interval)) } catch { return }
            }
        }
    }

    private func tick() {
        let now = Date()
        if isMixing { advanceMix(now: now) }
        if let restore = rateRestore {
            // Ease a beat-matched song back to its natural speed over 8 s.
            let t = min(1, now.timeIntervalSince(restore.startedAt) / 8)
            deck.timePitch.rate = restore.from + (1 - restore.from) * Float(t)
            if t >= 1 { rateRestore = nil }
        }
        if !isMixing, !userPaused, let plan = nextPlan, vlc == nil, deck.isActive,
           deck.currentTime >= plan.mixStart, plan.length > 0 {
            nextPlan = nil
            beginMix(plan)
        }
        refresh()
    }

    private func refresh() {
        // Assign only on change: every @Published write redraws its observers.
        if let vlc {
            let playing = vlc.isPlaying
            if isPlaying != playing { isPlaying = playing }
            clock.set(elapsed: Double(max(0, vlc.time.intValue)) / 1000,
                      duration: Double(max(0, vlc.media?.length.intValue ?? 0)) / 1000,
                      running: playing)
            if isPlaying { vlcStarted = true }
            if vlc.state == .error, let track = current {
                self.vlc = nil
                vlc.stop()
                return skipBroken(track, attempts: 0)
            }
            if vlcStarted, !userPaused, vlc.state == .stopped {
                vlcStarted = false
                trackEnded()
            }
        } else {
            let playing = !userPaused && deck.file != nil && deck.isActive
            if isPlaying != playing { isPlaying = playing }
            clock.set(elapsed: deck.currentTime, duration: deck.duration, running: playing)
        }
    }

    // MARK: Equalizer

    private func applyEqualizer() {
        eq.bypass = !equalizer.enabled
        for (band, gain) in zip(eq.bands, equalizer.gains) { band.gain = gain }
    }

    // MARK: Now Playing

    /// Picks up details read after the song started (tags, catalog).
    func refreshMeta() {
        guard let current else { return }
        let meta = metaProvider?(current)
        if meta != currentMeta {
            currentMeta = meta
            updateNowPlaying()
        }
    }

    var title: String { currentMeta?.title ?? current?.title ?? "Not Playing" }

    var subtitle: String {
        if let meta = currentMeta, meta.artist != nil || meta.album != nil {
            return [meta.artist, meta.album].compactMap { $0 }.joined(separator: " — ")
        }
        return current?.folder ?? ""
    }

    private func loadArtwork(for track: Track) {
        let meta = currentMeta
        Task { [weak self] in
            let image = await ArtworkResolver.shared.image(for: track, meta: meta)
            let color = await Task.detached(priority: .userInitiated) { image.flatMap(ArtworkPalette.color) }.value
            guard let self, self.current == track else { return }
            self.artwork = image
            self.artworkColor = color
            self.updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard current != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artist = currentMeta?.artist { info[MPMediaItemPropertyArtist] = artist }
        info[MPMediaItemPropertyAlbumTitle] = currentMeta?.album ?? current?.folder
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func observeSession() {
        let center = NotificationCenter.default
        center.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
                Task { @MainActor in
                    guard let self else { return }
                    if type == .began, self.isPlaying { self.togglePlayback() }
                    if type == .ended, options.contains(.shouldResume), !self.isPlaying { self.togglePlayback() }
                }
            }
            .store(in: &cancellables)
        center.publisher(for: .AVAudioEngineConfigurationChange, object: engine)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.userPaused, self.current != nil, self.vlc == nil else { return }
                    try? self.engine.start()
                    self.decks.forEach { $0.player.play() }
                }
            }
            .store(in: &cancellables)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == false { self?.togglePlayback() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPlaying == true { self?.togglePlayback() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                guard let self, self.duration > 0 else { return }
                self.seek(to: event.positionTime / self.duration)
            }
            return .success
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

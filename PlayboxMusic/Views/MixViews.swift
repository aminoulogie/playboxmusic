import SwiftUI

struct TransitionPair: Identifiable {
    let from: Track
    let to: Track
    var id: String { MixSettings.pairKey(from, to) }
}

/// Up Next as a Spotify-style mixed playlist: cover collage, glowing play
/// button, Mix / Edit / Sort chips, tempo and key per song, and a
/// transition chip between songs that opens the editor.
struct QueueView: View {
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        MixQueueList(mix: player.mix)
    }
}

private struct MixQueueList: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var mix: MixSettings
    @State private var editing: TransitionPair?
    @State private var editMode: EditMode = .inactive
    @State private var sorting = false
    @State private var totalDuration: Double?

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        NavigationStack {
            List {
                header
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                ForEach(Array(player.queue.enumerated()), id: \.offset) { offset, track in
                    row(track, offset: offset)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 12))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .onMove { player.moveQueue(from: $0, to: $1) }
                .onDelete { player.removeFromQueue(at: $0) }

                Text("When the queue ends, similar songs from your library keep playing.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .padding(.vertical, 12)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(backdrop)
            .environment(\.editMode, $editMode)
            .animation(.snappy, value: isEditing)
            .animation(.snappy, value: mix.isOn)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.headline)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { pair in
                TransitionEditorView(pair: pair)
                    .environmentObject(player)
                    .environmentObject(library)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
        .task(id: player.queue) { await loadTotalDuration() }
    }

    // MARK: Header

    private var backdrop: some View {
        LinearGradient(colors: [(player.artworkColor ?? Color(white: 0.2)).opacity(0.9), .black],
                       startPoint: .top, endPoint: .center)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.8), value: player.artworkColor)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Collage(tracks: Array(player.queue.dropFirst(player.index).prefix(4)))
                .frame(width: 230, height: 230)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)

            Text("Up Next")
                .font(.title.weight(.bold))
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 24, height: 24)
                    .background(Color.brand, in: Circle())
                Text(mix.isOn ? "Mixed by Playbox" : "Playing back to back")
                    .font(.subheadline.weight(.semibold))
            }
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 22) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(player.shuffle ? Color.brand : .white.opacity(0.8))
                }
                .accessibilityLabel(player.shuffle ? "Shuffle on" : "Shuffle off")
                Spacer()
                GlowPlayButton(isPlaying: player.isPlaying) { player.togglePlayback() }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.snappy) { mix.mode = mix.isOn ? .off : .auto }
                    } label: {
                        ChipLabel(title: "Mix", symbol: "slider.horizontal.3", ring: mix.isOn)
                    }
                    Button {
                        withAnimation(.snappy) { editMode = isEditing ? .inactive : .active }
                    } label: {
                        ChipLabel(title: isEditing ? "Done" : "Edit", symbol: "line.3.horizontal", selected: isEditing)
                    }
                    Menu {
                        ForEach(MusicPlayer.QueueOrder.allCases) { order in
                            Button(order.rawValue) {
                                sorting = true
                                Task {
                                    await player.sortUpcoming(order)
                                    sorting = false
                                }
                            }
                        }
                    } label: {
                        ChipLabel(title: sorting ? "Sorting…" : "Sort", symbol: "arrow.up.arrow.down")
                    }
                    if mix.isOn {
                        Menu {
                            Picker("Default transition", selection: $mix.defaultPreset) {
                                ForEach(MixPreset.allCases) { Text($0.rawValue).tag($0) }
                            }
                        } label: {
                            ChipLabel(title: mix.defaultPreset.rawValue, symbol: "sparkles")
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            .sensoryFeedback(.selection, trigger: mix.isOn)
        }
    }

    private var summary: String {
        let count = player.queue.count - player.index
        var parts = ["\(count) song\(count == 1 ? "" : "s")"]
        if let totalDuration, totalDuration > 0 {
            let minutes = Int(totalDuration / 60)
            parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m")
        }
        return parts.joined(separator: " • ")
    }

    private func loadTotalDuration() async {
        var total = 0.0
        for track in player.queue.dropFirst(player.index) {
            guard let analysis = await TrackAnalyzer.shared.analysis(for: track.url) else { continue }
            total += analysis.duration
        }
        totalDuration = total
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ track: Track, offset: Int) -> some View {
        let isCurrent = offset == player.index
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ArtworkThumbnail(track: track, size: 54)
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                            PlayingBars(active: player.isPlaying)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.title(of: track))
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? Color.brand : .white)
                        .lineLimit(1)
                    Text(library.meta(for: track)?.artist ?? library.subtitle(of: track))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                TrackFacts(track: track)
                if !isEditing {
                    Menu {
                        Button { player.play(player.queue, startAt: offset) } label: {
                            Label("Play Now", systemImage: "play")
                        }
                        if let next = player.queue[safe: offset + 1] {
                            Button { editing = TransitionPair(from: track, to: next) } label: {
                                Label("Edit Transition", systemImage: "slider.horizontal.3")
                            }
                        }
                        Button(role: .destructive) { player.removeFromQueue(at: IndexSet(integer: offset)) } label: {
                            Label("Remove from Queue", systemImage: "minus.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 30, height: 44)
                    }
                    .accessibilityLabel("More for \(library.title(of: track))")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { player.play(player.queue, startAt: offset) }
            .opacity(offset < player.index ? 0.45 : 1)

            if mix.isOn, !isEditing, offset >= player.index, let next = player.queue[safe: offset + 1] {
                TransitionChip(
                    label: transitionLabel(from: track, to: next, offset: offset),
                    progress: isCurrent && player.isMixing ? player.clock : nil
                ) {
                    editing = TransitionPair(from: track, to: next)
                }
                .padding(.leading, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func transitionLabel(from: Track, to: Track, offset: Int) -> String {
        if offset == player.index, let plan = player.nextPlan {
            return plan.preset?.rawValue ?? "Custom"
        }
        let custom = mix.transitionOverride(from: from, to: to)
        if custom.volume != nil || custom.eq != nil || custom.effect != nil {
            if let volume = custom.volume, let eq = custom.eq, let effect = custom.effect,
               let preset = MixPreset.matching(volume, eq, effect) {
                return preset.rawValue
            }
            return "Custom"
        }
        return (custom.preset ?? mix.defaultPreset).rawValue
    }
}

/// 2×2 artwork collage for the queue header, with a soft glow.
private struct Collage: View {
    let tracks: [Track]

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width / 2
            Group {
                if tracks.count >= 4 {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ArtworkThumbnail(track: tracks[0], size: side, cornerRadius: 0)
                            ArtworkThumbnail(track: tracks[1], size: side, cornerRadius: 0)
                        }
                        HStack(spacing: 0) {
                            ArtworkThumbnail(track: tracks[2], size: side, cornerRadius: 0)
                            ArtworkThumbnail(track: tracks[3], size: side, cornerRadius: 0)
                        }
                    }
                } else if let first = tracks.first {
                    ArtworkThumbnail(track: first, size: proxy.size.width, cornerRadius: 0)
                } else {
                    Color(white: 0.15)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
            .overlay(alignment: .top) {
                // A light catching the top edge, as on the Spotify cover.
                Capsule()
                    .fill(.white)
                    .frame(width: 60, height: 3)
                    .blur(radius: 3)
                    .opacity(0.7)
                    .offset(y: -1)
            }
        }
    }
}

/// The small "✦ Auto ›" chip between two songs.
private struct TransitionChip: View {
    let label: String
    let progress: PlaybackClock?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(width: 1.5, height: 34)
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "square.split.diagonal.fill")
                        .font(.caption)
                        .foregroundStyle(Color.brand)
                    Text(label).font(.subheadline.weight(.medium))
                    if let progress {
                        MixProgressLabel(clock: progress)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Transition: \(label). Edit")
        }
    }
}

private struct MixProgressLabel: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        if let progress = clock.mixProgress {
            Text("Mixing \(Int(progress * 100))%")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.brand)
        }
    }
}

// MARK: - Transition editor

/// Spotify's transition editor: the two songs' waveforms overlap where they
/// blend, with Volume, EQ and Effects curves drawn on top. Drag a waveform
/// to move it on the beat grid, pick the length in bars, choose each
/// automation lane or a preset, and preview the result.
struct TransitionEditorView: View {
    @EnvironmentObject private var player: MusicPlayer
    let pair: TransitionPair

    var body: some View {
        TransitionEditor(pair: pair, mix: player.mix)
    }
}

private struct TransitionEditor: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @Environment(\.dismiss) private var dismiss
    let pair: TransitionPair
    @ObservedObject var mix: MixSettings

    @State private var outgoing: TrackAnalysis?
    @State private var incoming: TrackAnalysis?
    @State private var loaded = false
    @State private var showSettings = false

    private var custom: TransitionOverride { mix.transitionOverride(from: pair.from, to: pair.to) }

    private var plan: TransitionPlan? {
        guard let outgoing else { return nil }
        return mix.plan(from: pair.from, outgoing, to: pair.to, incoming,
                        outDuration: outgoing.duration, force: true)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !loaded {
                Spacer()
                ProgressView("Analysing songs…").tint(.white)
                Spacer()
            } else if let outgoing, let incoming, let plan {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        if !mix.isOn { mixOffBanner }
                        MixTimeline(outgoing: outgoing, incoming: incoming, plan: plan, pair: pair,
                                    onMoveStart: { setStart($0) }, onMoveEntry: { setEntry($0) })
                            .frame(height: 300)
                            .overlay { previewButton(plan) }
                            .overlay(alignment: .bottom) { barsMenu(plan).offset(y: 18) }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 14)

                        VStack(spacing: 12) {
                            MixTrackRow(track: pair.from, analysis: outgoing, lane: "Out")
                            MixTrackRow(track: pair.to, analysis: incoming, lane: "In")
                        }
                        .padding(.horizontal, 16)

                        controls(plan)
                            .padding(.horizontal, 16)
                        presets(plan)
                    }
                    .padding(.vertical, 12)
                }
            } else {
                Spacer()
                ContentUnavailableView("Can't Edit This Transition", systemImage: "waveform.slash",
                                       description: Text("One of these files can't be analysed."))
                Spacer()
            }
        }
        .background(Color(white: 0.09).ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .presentationBackground(Color(white: 0.09))
        .sensoryFeedback(.selection, trigger: plan?.preset)
        .sensoryFeedback(.selection, trigger: plan?.bars)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form { MixSettingsForm(mix: mix) }
                    .navigationTitle("Mix Settings")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .task { await load() }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            Spacer()
            Text("Transition").font(.headline)
            Spacer()
            Menu {
                Button { showSettings = true } label: { Label("Mix Settings", systemImage: "gearshape") }
                Button(role: .destructive) {
                    withAnimation(.snappy) { mix.setOverride(nil, from: pair.from, to: pair.to) }
                } label: {
                    Label("Reset to Auto", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 8)
    }

    private var mixOffBanner: some View {
        HStack {
            Text("Mixing is off, so songs play back to back.")
                .font(.footnote)
            Spacer()
            Button("Turn On") { withAnimation { mix.mode = .auto } }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.brand)
        }
        .padding(12)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }

    private func previewButton(_ plan: TransitionPlan) -> some View {
        let previewing = player.isPlaying && (player.current == pair.from || player.current == pair.to)
        return Button {
            if previewing {
                player.togglePlayback()
            } else {
                player.previewTransition(from: pair.from, to: pair.to, at: plan.mixStart - plan.beat * 8)
            }
        } label: {
            Image(systemName: previewing ? "pause.fill" : "play.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 40)
                .background(.black.opacity(0.75), in: Capsule())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(previewing ? "Pause preview" : "Preview transition")
    }

    private func barsMenu(_ plan: TransitionPlan) -> some View {
        Menu {
            Picker("Length", selection: Binding(get: { plan.bars }, set: { setBars($0) })) {
                ForEach(MixSettings.barChoices, id: \.self) { bars in
                    Text("\(bars) bar\(bars == 1 ? "" : "s")").tag(bars)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(plan.bars) bar\(plan.bars == 1 ? "" : "s")")
                    .contentTransition(.numericText())
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12)))
        }
    }

    private func controls(_ plan: TransitionPlan) -> some View {
        HStack(spacing: 0) {
            lane("Volume", color: MixColor.volume, value: plan.volume, all: MixVolume.allCases) { value in
                edit(plan) { $0.volume = value }
            }
            lane("EQ", color: MixColor.eq, value: plan.eq, all: MixEQ.allCases) { value in
                edit(plan) { $0.eq = value }
            }
            lane("Effects", color: MixColor.effects, value: plan.effect, all: MixEffect.allCases) { value in
                edit(plan) { $0.effect = value }
            }
        }
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25)))
    }

    private func lane<Value: Hashable & Identifiable & RawRepresentable>(
        _ title: String, color: Color, value: Value, all: [Value], set: @escaping (Value) -> Void
    ) -> some View where Value.RawValue == String {
        Menu {
            Picker(title, selection: Binding(get: { value }, set: set)) {
                ForEach(all) { Text($0.rawValue).tag($0) }
            }
        } label: {
            VStack(spacing: 4) {
                Text(title).font(.footnote).foregroundStyle(color)
                HStack(spacing: 3) {
                    Text(value.rawValue).lineLimit(1).minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.subheadline)
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
        }
    }

    private func presets(_ plan: TransitionPlan) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MixPreset.allCases) { preset in
                    let selected = plan.preset == preset
                    Button { choose(preset) } label: {
                        HStack(spacing: 6) {
                            if let symbol = preset.symbol { Image(systemName: symbol) }
                            Text(preset.rawValue)
                        }
                        .font(.body.weight(.medium))
                        .foregroundStyle(selected ? .black : .white)
                        .frame(minWidth: 84)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 10)
                        .background(selected ? Color.white : Color(white: 0.2),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(PressScaleStyle())
                    .animation(.snappy(duration: 0.2), value: selected)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Editing

    /// Changing one lane pins all three, so the others stay as shown.
    private func edit(_ plan: TransitionPlan, _ change: (inout TransitionOverride) -> Void) {
        var value = custom
        value.volume = plan.volume
        value.eq = plan.eq
        value.effect = plan.effect
        change(&value)
        commit(value)
    }

    private func choose(_ preset: MixPreset) {
        var value = custom
        if preset == .auto {
            value = TransitionOverride()
            value.preset = .auto
        } else {
            value.preset = preset
            value.volume = nil
            value.eq = nil
            value.effect = nil
        }
        commit(value)
    }

    private func setBars(_ bars: Int) {
        var value = custom
        value.bars = bars
        commit(value)
    }

    private func setStart(_ seconds: Double) {
        var value = custom
        value.mixStart = seconds
        commit(value)
    }

    private func setEntry(_ seconds: Double) {
        var value = custom
        value.entry = seconds
        commit(value)
    }

    private func commit(_ value: TransitionOverride) {
        withAnimation(.snappy(duration: 0.3)) {
            mix.setOverride(value, from: pair.from, to: pair.to)
        }
    }

    private func load() async {
        async let out = TrackAnalyzer.shared.analysis(for: pair.from.url)
        async let into = TrackAnalyzer.shared.analysis(for: pair.to.url)
        let (outValue, inValue) = await (out, into)
        outgoing = outValue
        incoming = inValue
        withAnimation(.easeOut(duration: 0.3)) { loaded = true }
    }
}

/// One song in the editor: cover, title, artist, tempo, key and length.
private struct MixTrackRow: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: Track
    let analysis: TrackAnalysis
    let lane: String

    var body: some View {
        HStack(spacing: 14) {
            ArtworkThumbnail(track: track, size: 56)
                .overlay(alignment: .bottomLeading) {
                    Text(lane)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.white, in: Capsule())
                        .padding(3)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(library.title(of: track)).font(.title3).lineLimit(1)
                Text(library.meta(for: track)?.artist ?? library.subtitle(of: track))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(analysis.bpm.map { "\(Int($0.rounded())) bpm" } ?? "– bpm")
                    .font(.subheadline)
                    .monospacedDigit()
                HStack(spacing: 6) {
                    if let key = analysis.key { KeyBadge(key: key) }
                    Text(TrackFacts.format(analysis.duration))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}

/// The overlapping waveforms with automation curves. The top lane is the
/// outgoing song, the bottom lane the incoming one, aligned as they will
/// play. Drag the top lane to move where the blend starts, the bottom
/// lane to change where the next song comes in; both snap to beats.
private struct MixTimeline: View {
    @EnvironmentObject private var player: MusicPlayer
    let outgoing: TrackAnalysis
    let incoming: TrackAnalysis
    let plan: TransitionPlan
    let pair: TransitionPair
    let onMoveStart: (Double) -> Void
    let onMoveEntry: (Double) -> Void

    @State private var drag: DragState?

    private struct DragState {
        var lane: Lane
        var window: ClosedRange<Double>
        var origin: Double
    }

    private enum Lane { case outgoing, incoming }

    private var window: ClosedRange<Double> {
        if let drag { return drag.window }
        let pad = max(plan.length * 0.3, plan.beat * 4)
        return (plan.mixStart - pad)...(plan.mixEnd + pad)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            TimelineView(.animation(paused: !player.isPlaying)) { context in
                Canvas { canvas, _ in
                    draw(in: &canvas, size: size, playhead: playhead(at: context.date))
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Transition waveform, \(plan.bars) bars")
        .accessibilityHint("Drag the top song to move the blend, the bottom song to change where it comes in.")
    }

    /// Where playback is, in the outgoing song's time, if this pair is playing.
    private func playhead(at date: Date) -> Double? {
        let elapsed = player.clock.elapsed(at: date)
        if player.current == pair.from { return elapsed }
        if player.current == pair.to, plan.inRate > 0 {
            return plan.mixStart + (elapsed - plan.entry) / Double(plan.inRate)
        }
        return nil
    }

    private func incomingTime(_ outTime: Double) -> Double {
        plan.entry + (outTime - plan.mixStart) * Double(plan.inRate)
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, playhead: Double?) {
        let span = window.upperBound - window.lowerBound
        guard span > 0 else { return }
        let start = window.lowerBound
        let x: (Double) -> CGFloat = { CGFloat(($0 - start) / span) * size.width }
        let laneHeight = size.height * 0.42
        let topLane = CGRect(x: 0, y: size.height * 0.05, width: size.width, height: laneHeight)
        let bottomLane = CGRect(x: 0, y: size.height * 0.53, width: size.width, height: laneHeight)
        let regionStart = x(plan.mixStart), regionEnd = x(plan.mixEnd)

        canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.13)))
        let region = CGRect(x: regionStart, y: 0, width: max(2, regionEnd - regionStart), height: size.height)
        canvas.fill(Path(roundedRect: region, cornerRadius: 10), with: .color(Color(white: 0.24)))

        // Bar lines on the outgoing grid.
        if let first = outgoing.firstBeat, let beat = outgoing.beatLength {
            let bar = beat * 4
            var line = first + ((window.lowerBound - first) / bar).rounded(.up) * bar
            while line < window.upperBound {
                canvas.fill(Path(CGRect(x: x(line), y: 0, width: 1, height: size.height)),
                            with: .color(.white.opacity(0.06)))
                line += bar
            }
        }

        // Waveforms, brighter inside the blend.
        let columns = Int(size.width / 3)
        for column in 0..<columns {
            let px = CGFloat(column) * 3
            let time = start + Double(px / size.width) * span
            let inside = time >= plan.mixStart && time <= plan.mixEnd
            let outPeak = time <= outgoing.duration ? outgoing.peak(at: time) : 0
            let inTime = incomingTime(time)
            let inPeak = inTime >= 0 && inTime <= incoming.duration ? incoming.peak(at: inTime) : 0
            for (peak, lane, playing) in [(outPeak, topLane, time <= plan.mixEnd),
                                          (inPeak, bottomLane, time >= plan.mixStart)] where peak > 0 {
                let height: CGFloat = max(1.5, CGFloat(peak.squareRoot()) * lane.height)
                let bar = CGRect(x: px, y: lane.midY - height / 2, width: 2, height: height)
                let opacity: Double = inside ? 0.85 : (playing ? 0.55 : 0.18)
                canvas.fill(Path(bar), with: .color(.white.opacity(opacity)))
            }
        }

        // Automation curves across the blend: volume, bass EQ and effect.
        let steps = 80
        func curve(_ lane: CGRect, inset: CGFloat, _ value: (Double) -> Double) -> Path {
            let usable = lane.height - inset * 2
            func y(_ level: Double) -> CGFloat {
                lane.minY + inset + CGFloat(1 - min(max(level, 0), 1)) * usable
            }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y(value(0))))
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let px: CGFloat = regionStart + CGFloat(t) * (regionEnd - regionStart)
                path.addLine(to: CGPoint(x: px, y: y(value(t))))
            }
            path.addLine(to: CGPoint(x: size.width, y: y(value(1))))
            return path
        }
        let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        let beatFraction = plan.length > 0 ? plan.beat / plan.length : 0.1
        if plan.eq != MixEQ.none {
            canvas.stroke(curve(topLane, inset: 3) { plan.eq.bass($0, beatFraction: beatFraction).out },
                          with: .color(MixColor.eq), style: style)
            canvas.stroke(curve(bottomLane, inset: 3) { plan.eq.bass($0, beatFraction: beatFraction).in },
                          with: .color(MixColor.eq), style: style)
        }
        if plan.effect != MixEffect.none {
            let lane = plan.effect.onIncoming ? bottomLane : topLane
            let effect = plan.effect
            canvas.stroke(curve(lane, inset: 6) { effect == .echo ? effect.amount($0) : 1 - effect.amount($0) },
                          with: .color(MixColor.effects), style: style)
        }
        canvas.stroke(curve(topLane, inset: 0) { Double(plan.volume.gains($0).out) },
                      with: .color(MixColor.volume), style: style)
        canvas.stroke(curve(bottomLane, inset: 0) { Double(plan.volume.gains($0).in) },
                      with: .color(MixColor.volume), style: style)

        if let playhead, window.contains(playhead) {
            let px = x(playhead)
            canvas.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
            canvas.fill(Path(ellipseIn: CGRect(x: px - 5, y: -5, width: 10, height: 10)), with: .color(.white))
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if drag == nil {
                    let lane: Lane = value.startLocation.y < size.height / 2 ? .outgoing : .incoming
                    drag = DragState(lane: lane, window: window,
                                     origin: lane == .outgoing ? plan.mixStart : plan.entry)
                }
                guard let drag else { return }
                let span = drag.window.upperBound - drag.window.lowerBound
                let seconds = Double(value.translation.width / size.width) * span
                switch drag.lane {
                case .outgoing:
                    // Moving the outgoing song left starts the blend later in it.
                    let target = outgoing.snapToBeat(drag.origin - seconds)
                    let clamped = min(max(0, target), max(0, outgoing.duration - plan.length))
                    if abs(clamped - plan.mixStart) > 0.001 { onMoveStart(clamped) }
                case .incoming:
                    let target = incoming.snapToBeat(drag.origin - seconds * Double(plan.inRate))
                    let clamped = min(max(0, target), max(0, incoming.duration - plan.length))
                    if abs(clamped - plan.entry) > 0.001 { onMoveEntry(clamped) }
                }
            }
            .onEnded { _ in drag = nil }
    }
}

// MARK: - Settings

/// Mix options, in Account and behind the editor's menu.
struct MixSettingsForm: View {
    @ObservedObject var mix: MixSettings

    var body: some View {
        Section {
            Toggle("Mix between songs", isOn: Binding(get: { mix.isOn }, set: { mix.mode = $0 ? .auto : .off }))
                .tint(.brand)
            Picker("Default transition", selection: $mix.defaultPreset) {
                ForEach(MixPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(!mix.isOn)
        } footer: {
            Text("Like Spotify's mixed playlists: Auto plans every transition from the songs' tempo, key and outro. Tap a transition in Up Next to change its length, volume, EQ and effects.")
        }

        if mix.isOn {
            Section {
                Toggle("Match tempo and beats", isOn: $mix.matchBeats).tint(.brand)
                Toggle("Match volume", isOn: $mix.matchVolume).tint(.brand)
                Toggle("Skip silence", isOn: $mix.skipSilence).tint(.brand)
            } header: {
                Text("Matching")
            } footer: {
                Text("Songs within 8% of each other's tempo are beat-matched and blended on the bar. Keys are detected so clashing songs get a shorter, filtered blend.")
            }
        }
    }
}

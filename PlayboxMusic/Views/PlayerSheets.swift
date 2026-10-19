import SwiftUI

/// Up Next: reorder, swipe to remove, and see where mixes happen.
struct QueueView: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @State private var editing: TransitionPair?

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { offset, track in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { player.play(player.queue, startAt: offset) } label: {
                            HStack(spacing: 12) {
                                ArtworkThumbnail(track: track, size: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(library.title(of: track)).lineLimit(1)
                                    Text(library.subtitle(of: track)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if offset == player.index {
                                    Image(systemName: "waveform").foregroundStyle(.tint)
                                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        if let next = player.queue[safe: offset + 1], offset >= player.index {
                            Button { editing = TransitionPair(from: track, to: next) } label: {
                                Label(mixLabel(offset: offset), systemImage: "point.3.filled.connected.trianglepath.dotted")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Edit this transition")
                        }
                    }
                }
                .onMove { player.moveQueue(from: $0, to: $1) }
                .onDelete { player.removeFromQueue(at: $0) }

                Section {
                    Text("When the queue ends, similar songs from your library keep playing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
            .sheet(item: $editing) { pair in
                TransitionEditorView(pair: pair)
                    .environmentObject(player)
                    .environmentObject(library)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func mixLabel(offset: Int) -> String {
        if offset == player.index, let plan = player.nextPlan {
            return String(format: "Mix %.0f s at %@", plan.length, format(plan.mixStart))
        }
        switch player.mix.mode {
        case .off: return "No mix · gapless"
        case .auto: return "Auto mix"
        case .manual: return String(format: "Mix %.0f s", player.mix.manualLength)
        }
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct TransitionPair: Identifiable {
    let from: Track
    let to: Track
    var id: String { MixSettings.pairKey(from, to) }
}

/// Quick mix controls on the player; the same options live in Account.
struct MixSheet: View {
    @EnvironmentObject private var player: MusicPlayer
    @State private var editing: TransitionPair?

    var body: some View {
        NavigationStack {
            Form {
                MixSettingsForm(mix: player.mix)
                if let from = player.current, let to = player.upcoming {
                    Section {
                        Button("Edit This Transition") { editing = TransitionPair(from: from, to: to) }
                    } footer: {
                        Text("Fine-tune exactly how this song blends into the next one.")
                    }
                }
            }
            .navigationTitle("Mix")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { pair in
                TransitionEditorView(pair: pair).environmentObject(player)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MixSettingsForm: View {
    @ObservedObject var mix: MixSettings

    var body: some View {
        Section {
            Picker("Mix", selection: $mix.mode) {
                ForEach(MixMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        } footer: {
            switch mix.mode {
            case .off: Text("Songs play back to back without blending.")
            case .auto: Text("Like Spotify's automix: each blend is planned from the song's outro.")
            case .manual: Text("Use your own blend length, curve and start point.")
            }
        }

        if mix.mode == .auto {
            Section {
                Picker("Blend style", selection: $mix.style) {
                    ForEach(TransitionStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Skip silence", isOn: $mix.skipSilence)
                Toggle("Match volume", isOn: $mix.matchVolume)
                Toggle("Match tempo and beats", isOn: $mix.matchBeats)
            } header: {
                Text("Automatic")
            } footer: {
                Text("Bass swap plays the next song without bass, then swaps basslines halfway, like a DJ. Filter sweep fades the old song out from the bottom up.")
            }
        }

        if mix.mode == .manual {
            Section("Manual") {
                VStack(alignment: .leading) {
                    Text("Mix length: \(Int(mix.manualLength)) s")
                    Slider(value: $mix.manualLength, in: 0...12, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Start blending \(Int(mix.startBeforeEnd)) s before the end")
                    Slider(value: $mix.startBeforeEnd, in: 0...30, step: 1)
                }
                Picker("Fade curve", selection: $mix.curve) {
                    ForEach(FadeCurve.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Blend style", selection: $mix.style) {
                    ForEach(TransitionStyle.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Skip silence", isOn: $mix.skipSilence)
                Toggle("Match volume", isOn: $mix.matchVolume)
            }
        }
    }
}

/// Spotify-style editor for one song pair: pick where the blend starts in
/// the outgoing song, where the next song enters, the length and curve.
struct TransitionEditorView: View {
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    let pair: TransitionPair

    @State private var outgoing: TrackAnalysis?
    @State private var incoming: TrackAnalysis?
    @State private var mixStart: Double = 0
    @State private var entry: Double = 0
    @State private var length: Double = 6
    @State private var curve: FadeCurve = .smooth
    @State private var style: TransitionStyle = .bassSwap
    @State private var loaded = false

    private let windowLength = 40.0

    var body: some View {
        NavigationStack {
            Form {
                if !loaded {
                    ProgressView("Analysing songs…").frame(maxWidth: .infinity)
                } else if let outgoing, let incoming {
                    Section("Outgoing · \(pair.from.title)") {
                        let tailStart = max(0, outgoing.duration - windowLength)
                        Waveform(analysis: outgoing, from: tailStart, to: outgoing.duration,
                                 marker: mixStart, highlight: mixStart...(mixStart + length))
                        VStack(alignment: .leading) {
                            Text("Blend starts at \(format(mixStart))")
                            Slider(value: $mixStart, in: tailStart...max(tailStart + 1, outgoing.duration - 0.5))
                        }
                    }
                    Section("Incoming · \(pair.to.title)") {
                        Waveform(analysis: incoming, from: 0, to: min(windowLength, incoming.duration),
                                 marker: entry, highlight: entry...(entry + length))
                        VStack(alignment: .leading) {
                            Text("Enters at \(format(entry))")
                            Slider(value: $entry, in: 0...min(windowLength, max(1, incoming.duration)))
                        }
                    }
                    Section("Blend") {
                        VStack(alignment: .leading) {
                            Text("Length: \(Int(length)) s")
                            Slider(value: $length, in: 0...16, step: 0.5)
                        }
                        Picker("Fade curve", selection: $curve) {
                            ForEach(FadeCurve.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Blend style", selection: $style) {
                            ForEach(TransitionStyle.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Section {
                        Button("Save and Preview") {
                            save()
                            if player.current == pair.from, player.duration > 0 {
                                player.seek(to: max(0, mixStart - 5) / player.duration)
                            }
                        }
                        Button("Reset to Automatic", role: .destructive) {
                            player.mix.setOverride(nil, from: pair.from, to: pair.to)
                            dismiss()
                        }
                    }
                } else {
                    Text("These files can't be analysed, so the transition can't be edited.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Transition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                    .disabled(outgoing == nil || incoming == nil)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        async let out = TrackAnalyzer.shared.analysis(for: pair.from.url)
        async let into = TrackAnalyzer.shared.analysis(for: pair.to.url)
        let (outValue, inValue) = await (out, into)
        outgoing = outValue
        incoming = inValue
        if let custom = player.mix.overrides[pair.id] {
            mixStart = custom.mixStart
            entry = custom.entry
            length = custom.length
            curve = custom.curve
            style = custom.style ?? player.mix.style
        } else if let plan = player.mix.plan(from: pair.from, outValue, to: pair.to, inValue,
                                             outDuration: outValue?.duration ?? 0) {
            mixStart = plan.mixStart
            entry = plan.entry
            length = plan.length
            curve = plan.curve
            style = plan.style
        } else if let outValue {
            mixStart = max(0, outValue.musicEnd - 6)
            entry = inValue?.leadIn ?? 0
        }
        loaded = true
    }

    private func save() {
        guard outgoing != nil, incoming != nil else { return }
        player.mix.setOverride(
            TransitionOverride(mixStart: mixStart, entry: entry, length: length, curve: curve, style: style),
            from: pair.from, to: pair.to
        )
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}

/// Loudness bars for part of a song, with the blend region highlighted.
private struct Waveform: View {
    let analysis: TrackAnalysis
    let from: Double
    let to: Double
    let marker: Double
    let highlight: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            let step = TrackAnalysis.windowSeconds
            let first = Int(from / step)
            let last = min(analysis.envelope.count, Int(to / step))
            guard last > first else { return }
            let bars = 90
            let perBar = max(1, (last - first) / bars)
            let width = size.width / CGFloat(bars)
            for bar in 0..<bars {
                let start = first + bar * perBar
                guard start < last else { break }
                let slice = analysis.envelope[start..<min(last, start + perBar)]
                let level = Double(slice.max() ?? -60)
                let height = max(2, CGFloat((level + 60) / 60) * size.height)
                let time = Double(start) * step
                let inBlend = highlight.contains(time)
                let rect = CGRect(x: CGFloat(bar) * width, y: (size.height - height) / 2,
                                  width: max(1, width - 1.5), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1),
                             with: .color(inBlend ? .accentColor : .white.opacity(0.35)))
            }
            let x = CGFloat((marker - from) / (to - from)) * size.width
            context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.white))
        }
        .frame(height: 64)
        .accessibilityHidden(true)
    }
}

/// Ten-band equalizer with presets.
struct EqualizerView: View {
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        EqualizerForm(equalizer: player.equalizer)
            .presentationDetents([.medium, .large])
    }
}

private struct EqualizerForm: View {
    @ObservedObject var equalizer: EqualizerSettings

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Toggle("Equalizer", isOn: $equalizer.enabled)
                Menu {
                    ForEach(EqualizerSettings.presets.map { $0.0 }, id: \.self) { name in
                        Button(name) { equalizer.apply(preset: name) }
                    }
                } label: {
                    HStack {
                        Text("Preset")
                        Spacer()
                        Text(equalizer.presetName).foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<10, id: \.self) { band in
                        VStack(spacing: 6) {
                            Text(String(format: "%+.0f", equalizer.gains[band]))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { Double(equalizer.gains[band]) },
                                set: {
                                    equalizer.gains[band] = Float($0)
                                    equalizer.presetName = "Custom"
                                    equalizer.enabled = true
                                }
                            ), in: -12...12)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 170, height: 28)
                            .frame(width: 30, height: 170)
                            .accessibilityLabel("\(label(EqualizerSettings.frequencies[band])) band")
                            Text(label(EqualizerSettings.frequencies[band]))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!equalizer.enabled)
                .opacity(equalizer.enabled ? 1 : 0.4)
                Spacer()
            }
            .padding()
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func label(_ frequency: Float) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}

/// Finds the catalog album for the playing song and shows its page.
struct AlbumLookupView: View {
    let meta: TrackMeta?
    let fallbackTitle: String
    @State private var album: ITunesItem?
    @State private var searched = false

    var body: some View {
        NavigationStack {
            Group {
                if let album {
                    AlbumDetailView(album: album)
                } else if searched {
                    ContentUnavailableView("Album Not Found", systemImage: "square.stack",
                                           description: Text("No catalog album matched this song."))
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(for: ITunesItem.self) { item in
                if item.wrapperType == "artist" { ArtistView(artist: item) } else { AlbumDetailView(album: item) }
            }
        }
        .task {
            let term = [meta?.artist, meta?.album ?? meta?.title ?? MusicText.clean(fallbackTitle)]
                .compactMap { $0 }.joined(separator: " ")
            album = try? await ITunesCatalog.search(term, entity: "album", limit: 1).first
            searched = true
        }
    }
}

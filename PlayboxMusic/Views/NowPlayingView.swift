import AVKit
import MediaPlayer
import SwiftUI

/// Full-screen player: artwork-tinted background, a large cover that
/// slides in the direction you skip and settles back when paused, title
/// with tempo and key, transport, volume and quick access to lyrics, the
/// transition editor, EQ and Up Next. Fast-changing parts (time, lyrics,
/// mix progress, cover drag) are separate views so only they redraw.
struct NowPlayingView: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var client: SoulseekClient
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: Sheet?
    @State private var showLyrics = false
    @State private var lyrics: [LyricLine] = []
    @State private var lyricsLoading = false

    enum Sheet: String, Identifiable {
        case queue, mix, equalizer, album
        var id: String { rawValue }
    }

    private var isFavourite: Bool { player.current.map(library.isFavourite) ?? false }

    private var slide: AnyTransition {
        let distance: CGFloat = player.skipDirection >= 0 ? 360 : -360
        return .asymmetric(
            insertion: .offset(x: distance).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
            removal: .offset(x: -distance).combined(with: .opacity).combined(with: .scale(scale: 0.92))
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width - 48, proxy.size.height * 0.42)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 20)
                ZStack {
                    if showLyrics {
                        LyricsPanel(lyrics: lyrics, loading: lyricsLoading, clock: player.clock) { time in
                            if player.duration > 0 { player.seek(to: time / player.duration) }
                        }
                        .frame(width: proxy.size.width - 48, height: side)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        CoverView(side: side, coverMenu: { coverMenu }, onLike: like)
                            .id(player.current)
                            .transition(slide)
                    }
                }
                .frame(height: side)
                .animation(.spring(response: 0.5, dampingFraction: 0.86), value: player.current)
                Spacer(minLength: 20)
                titleRow
                TimeBar(clock: player.clock) { player.seek(to: $0) }
                    .padding(.top, 12)
                transport
                    .padding(.top, 10)
                volume
                    .padding(.top, 16)
                bottomBar
                    .padding(.top, 14)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 24)
            .frame(width: proxy.size.width)
        }
        .background { backdrop }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
        .overlay(alignment: .top) { noticeBanner }
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
        .sensoryFeedback(.selection, trigger: player.current)
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .queue: QueueView()
                case .mix:
                    if let from = player.current, let to = player.upcoming {
                        TransitionEditorView(pair: TransitionPair(from: from, to: to))
                    } else {
                        NavigationStack {
                            Form { MixSettingsForm(mix: player.mix) }
                                .navigationTitle("Mix")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                        .presentationDetents([.medium, .large])
                    }
                case .equalizer: EqualizerView()
                case .album: AlbumLookupView(meta: player.currentMeta, fallbackTitle: player.title)
                }
            }
            .environmentObject(player)
            .environmentObject(library)
            .environmentObject(client)
        }
        .task(id: player.current) { await loadLyrics() }
    }

    // MARK: Sections

    private var backdrop: some View {
        let tint = player.artworkColor ?? Color(white: 0.22)
        return ZStack {
            Color.black
            LinearGradient(stops: [
                .init(color: tint, location: 0),
                .init(color: tint.opacity(0.55), location: 0.45),
                .init(color: .black, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.9), value: player.artworkColor)
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close Now Playing")
            Spacer()
            MixStatusPill(clock: player.clock) { sheet = .mix }
            Spacer()
            Menu {
                coverMenu
            } label: {
                Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
    }

    @ViewBuilder
    private var coverMenu: some View {
        Button { sheet = .album } label: { Label("Go to Album", systemImage: "square.stack") }
        if let track = player.current {
            Button { player.playNext(track) } label: { Label("Play Again Next", systemImage: "text.insert") }
            Button { player.addToQueue(track) } label: { Label("Add to Queue", systemImage: "text.append") }
        }
        Button { sheet = .queue } label: { Label("Up Next", systemImage: "list.bullet") }
        if player.upcoming != nil {
            Button { sheet = .mix } label: { Label("Edit Transition", systemImage: "slider.horizontal.3") }
        }
        Button { toggleFavourite() } label: {
            Label(isFavourite ? "Remove from Favourites" : "Add to Favourites",
                  systemImage: isFavourite ? "heart.slash" : "heart")
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(player.subtitle)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                if let track = player.current {
                    NowPlayingFacts(track: track, lossless: player.isLossless)
                        .padding(.top, 2)
                }
            }
            .id(player.current)
            .transition(.blurReplace)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { toggleFavourite() } label: {
                Image(systemName: isFavourite ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(isFavourite ? Color.brand : .white.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .symbolEffect(.bounce, value: isFavourite)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(isFavourite ? "Remove from Favourites" : "Add to Favourites")
        }
        .animation(.snappy(duration: 0.35), value: player.current)
    }

    private var transport: some View {
        HStack {
            toggleButton("shuffle", on: player.shuffle) { player.toggleShuffle() }
                .accessibilityLabel(player.shuffle ? "Shuffle on" : "Shuffle off")
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.system(size: 30)) }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Previous track")
            Spacer()
            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 72, height: 72)
                    .background(.white, in: Circle())
                    .shadow(color: (player.artworkColor ?? .black).opacity(0.6), radius: 16, y: 6)
                    .contentTransition(.symbolEffect(.replace.downUp))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.system(size: 30)) }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Next track")
            Spacer()
            toggleButton(player.repeatMode == .one ? "repeat.1" : "repeat", on: player.repeatMode != .off) {
                player.cycleRepeat()
            }
            .accessibilityLabel("Repeat \(player.repeatMode.rawValue)")
        }
        .sensoryFeedback(.selection, trigger: player.shuffle)
        .sensoryFeedback(.selection, trigger: player.repeatMode)
    }

    /// Shuffle and repeat: green with a dot underneath when on, like Spotify.
    private func toggleButton(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                Circle().frame(width: 4, height: 4).opacity(on ? 1 : 0)
            }
            .foregroundStyle(on ? Color.brand : .white.opacity(0.75))
            .frame(width: 44, height: 50)
            .animation(.snappy(duration: 0.2), value: on)
        }
        .buttonStyle(PressScaleStyle())
    }

    private var volume: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.white.opacity(0.5))
            SystemVolumeSlider().frame(height: 34)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { showLyrics.toggle() }
            } label: {
                Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .foregroundStyle(showLyrics ? Color.brand : .white.opacity(0.75))
                    .frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(showLyrics ? "Hide lyrics" : "Show lyrics")
            Spacer()
            RoutePicker().frame(width: 44, height: 44)
            Spacer()
            Button { sheet = .equalizer } label: {
                Image(systemName: "slider.vertical.3")
                    .foregroundStyle(player.equalizer.enabled ? Color.brand : .white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Equalizer")
            Spacer()
            Button { sheet = .mix } label: {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(player.mix.isOn ? Color.brand : .white.opacity(0.75))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Edit transition")
            Spacer()
            Button { sheet = .queue } label: {
                Image(systemName: "list.bullet").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Up next")
        }
        .font(.title3)
        .buttonStyle(PressScaleStyle())
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = player.notice {
            Text(notice)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(white: 0.15), in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { player.notice = nil }
                }
        }
    }

    // MARK: Actions

    private func like() {
        guard let track = player.current else { return }
        library.setFavourite(track, true)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func toggleFavourite() {
        guard let track = player.current else { return }
        library.setFavourite(track, !library.isFavourite(track))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func loadLyrics() async {
        lyrics = []
        guard player.current != nil else { return }
        lyricsLoading = true
        defer { lyricsLoading = false }
        let meta = player.currentMeta
        let title = meta?.title ?? MusicText.clean(player.title)
        lyrics = await LyricsService.shared.lyrics(
            title: title, artist: meta?.artist, album: meta?.album,
            duration: player.duration > 0 ? player.duration : nil
        )
    }
}

/// Top-of-player status: what's mixing in (with live progress), the next
/// transition, or just "Now Playing". Tap to open the transition editor.
private struct MixStatusPill: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @ObservedObject var clock: PlaybackClock
    let onTap: () -> Void

    var body: some View {
        Group {
            if player.isMixing, let next = player.upcoming {
                pill(progress: clock.mixProgress) {
                    PlayingBars(active: true, color: .black)
                    Text("Mixing into \(library.title(of: next))").lineLimit(1)
                }
                .foregroundStyle(.black)
                .background(Color.brand, in: Capsule())
            } else if player.mix.isOn, let plan = player.nextPlan {
                pill(progress: nil) {
                    Image(systemName: "sparkles")
                    Text("Next: \(plan.preset?.rawValue ?? "Custom") · \(plan.bars) bars")
                }
                .foregroundStyle(.white)
                .background(.white.opacity(0.14), in: Capsule())
            } else {
                Text("NOW PLAYING")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .animation(.snappy, value: player.isMixing)
        .onTapGesture { if player.upcoming != nil { onTap() } }
    }

    private func pill<Content: View>(progress: Double?, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: 230)
            .overlay(alignment: .bottomLeading) {
                if let progress {
                    GeometryReader { proxy in
                        Capsule().fill(.black.opacity(0.35))
                            .frame(width: proxy.size.width * progress, height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 3)
                }
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// Tempo and key under the title, plus a lossless mark.
private struct NowPlayingFacts: View {
    let track: Track
    let lossless: Bool
    @State private var analysis: TrackAnalysis?

    var body: some View {
        HStack(spacing: 8) {
            if let bpm = analysis?.bpm {
                Text("\(Int(bpm.rounded())) BPM")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let key = analysis?.key { KeyBadge(key: key) }
            if lossless {
                Label("Lossless", systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.3), value: analysis?.bpm)
        .task(id: track.id) { analysis = await TrackAnalyzer.shared.analysis(for: track.url) }
    }
}

/// The cover keeps a fixed size; it slides with your finger to change
/// tracks, double-tap likes, long-press opens the menu.
private struct CoverView<MenuContent: View>: View {
    @EnvironmentObject private var player: MusicPlayer
    let side: CGFloat
    @ViewBuilder let coverMenu: () -> MenuContent
    let onLike: () -> Void
    @State private var dragOffset: CGFloat = 0
    @State private var heartBurst = false

    var body: some View {
        ZStack {
            Group {
                if let artwork = player.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    Color(white: 0.12).overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.3, weight: .light))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(player.isPlaying ? 0.55 : 0.3),
                    radius: player.isPlaying ? 26 : 12, y: player.isPlaying ? 14 : 6)
            .animation(.easeInOut(duration: 0.3), value: player.artwork != nil)

            Image(systemName: "heart.fill")
                .font(.system(size: 90))
                .foregroundStyle(.white)
                .shadow(radius: 10)
                .scaleEffect(heartBurst ? 1 : 0.4)
                .opacity(heartBurst ? 0.95 : 0)
                .allowsHitTesting(false)
        }
        // Settles back slightly while paused, like Apple Music.
        .scaleEffect(player.isPlaying ? 1 : 0.86)
        .animation(.spring(response: 0.45, dampingFraction: 0.68), value: player.isPlaying)
        .offset(x: dragOffset)
        .rotationEffect(.degrees(Double(dragOffset) / 40))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onLike()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { heartBurst = true }
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                withAnimation(.easeOut(duration: 0.25)) { heartBurst = false }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 15)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    let width = value.translation.width
                    let velocity = value.predictedEndTranslation.width
                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.85)) { dragOffset = 0 }
                    if width < -80 || velocity < -300 { player.next() }
                    else if width > 80 || velocity > 300 { player.previous() }
                }
        )
        .contextMenu { coverMenu() }
        .accessibilityElement()
        .accessibilityLabel("Album artwork")
        .accessibilityHint("Swipe left or right to change track. Double-tap to like.")
        .accessibilityAction(named: "Next track") { player.next() }
        .accessibilityAction(named: "Previous track") { player.previous() }
    }
}

/// Synced lyrics in place of the cover, following the song.
private struct LyricsPanel: View {
    let lyrics: [LyricLine]
    let loading: Bool
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void

    private var currentIndex: Int? {
        lyrics.lastIndex { ($0.time ?? .infinity) <= clock.elapsed + 0.25 }
    }

    var body: some View {
        if lyrics.isEmpty {
            VStack(spacing: 10) {
                if loading { ProgressView() } else {
                    Image(systemName: "quote.bubble").font(.largeTitle).foregroundStyle(.white.opacity(0.3))
                    Text("No lyrics found for this song").foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { reader in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(lyrics) { line in
                            Text(line.text)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white.opacity(line.id == currentIndex ? 1 : 0.3))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                                .onTapGesture { if let time = line.time { onSeek(time) } }
                        }
                    }
                    .padding(.vertical, 40)
                }
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88), .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom))
                .onChange(of: currentIndex) { _, index in
                    guard let index else { return }
                    withAnimation(.easeInOut(duration: 0.35)) { reader.scrollTo(index, anchor: .center) }
                }
            }
        }
    }
}

/// Scrubber and times. Draws every frame (120 Hz on ProMotion) from the
/// playback clock without redrawing the rest of the page.
private struct TimeBar: View {
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void
    @State private var scrub: Double?

    var body: some View {
        TimelineView(.animation(paused: !clock.running || scrub != nil)) { context in
            let elapsed = clock.elapsed(at: context.date)
            let progress = scrub ?? (clock.duration > 0 ? elapsed / clock.duration : 0)
            let position = progress * clock.duration
            VStack(spacing: 6) {
                Scrubber(
                    progress: progress,
                    enabled: clock.duration > 0,
                    onChange: { scrub = $0 },
                    onCommit: {
                        if let scrub { onSeek(scrub) }
                        scrub = nil
                    }
                )
                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text("-" + Self.format(max(0, clock.duration - position)))
                }
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Buttons shrink slightly while pressed.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A thin capsule progress bar that thickens while dragging.
struct Scrubber: View {
    let progress: Double
    let enabled: Bool
    let onChange: (Double) -> Void
    let onCommit: () -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white.opacity(dragging ? 1 : 0.85))
                    .frame(width: max(0, min(1, progress)) * proxy.size.width)
            }
            .frame(height: dragging ? 9 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled else { return }
                        dragging = true
                        onChange(min(max(value.location.x / proxy.size.width, 0), 1))
                    }
                    .onEnded { _ in
                        guard enabled else { return }
                        dragging = false
                        onCommit()
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 24)
        .sensoryFeedback(.selection, trigger: dragging)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(progress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            onChange(min(max(progress + (direction == .increment ? 0.05 : -0.05), 0), 1))
            onCommit()
        }
    }
}

/// The iPhone's own volume, same as the side buttons.
private struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// AirPlay and Bluetooth output picker.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Square cover for a downloaded track, resolved lazily.
struct ArtworkThumbnail: View {
    @EnvironmentObject private var library: MusicLibrary
    let track: Track
    var size: CGFloat = 48
    var cornerRadius: CGFloat?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.14))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.12, style: .continuous))
        .task(id: track.id) {
            image = await ArtworkResolver.shared.image(for: track, meta: library.meta(for: track))
        }
    }
}

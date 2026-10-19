import AVKit
import MediaPlayer
import SwiftUI

/// Black page with a large rounded cover, title centered below, synced
/// lyrics, transport, volume and quick access to mix, EQ and the queue.
struct NowPlayingView: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var client: SoulseekClient
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?
    @State private var sheet: Sheet?
    @State private var dragOffset: CGFloat = 0
    @State private var heartBurst = false
    @State private var lyrics: [LyricLine] = []

    enum Sheet: String, Identifiable {
        case queue, mix, equalizer, album
        var id: String { rawValue }
    }

    private var isFavourite: Bool { player.current.map(library.isFavourite) ?? false }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width - 48, proxy.size.height * 0.42)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 24)
                cover(side: side)
                Spacer(minLength: 20)
                titleRow
                lyricsLines
                    .frame(height: lyrics.isEmpty ? 8 : 66)
                scrubber
                    .padding(.top, 10)
                transport
                    .padding(.top, 14)
                volume
                    .padding(.top, 18)
                bottomBar
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 24)
            .frame(width: proxy.size.width)
        }
        .background(Color.black.ignoresSafeArea())
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
                case .mix: MixSheet()
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

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close Now Playing")
            Spacer()
            if player.isMixing {
                Label("Mixing", systemImage: "waveform.path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Menu {
                coverMenu
            } label: {
                Image(systemName: "ellipsis").font(.headline).frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
    }

    private func cover(side: CGFloat) -> some View {
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
            .shadow(color: .black.opacity(0.6), radius: 20, y: 10)

            Image(systemName: "heart.fill")
                .font(.system(size: 90))
                .foregroundStyle(.white)
                .shadow(radius: 10)
                .scaleEffect(heartBurst ? 1 : 0.4)
                .opacity(heartBurst ? 0.95 : 0)
                .allowsHitTesting(false)
        }
        // Shrinks slightly while paused, like Apple Music.
        .scaleEffect(player.isPlaying ? 1 : 0.86)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
        .offset(x: dragOffset)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { like() }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    let width = value.translation.width
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragOffset = 0 }
                    if width < -80 { player.next() } else if width > 80 { player.previous() }
                }
        )
        .contextMenu { coverMenu }
        .accessibilityElement()
        .accessibilityLabel("Album artwork")
        .accessibilityHint("Swipe left or right to change track. Double-tap to like.")
        .accessibilityAction(named: "Next track") { player.next() }
        .accessibilityAction(named: "Previous track") { player.previous() }
        .accessibilityAction(named: isFavourite ? "Remove from Favourites" : "Add to Favourites") { toggleFavourite() }
    }

    @ViewBuilder
    private var coverMenu: some View {
        Button { sheet = .album } label: { Label("Go to Album", systemImage: "square.stack") }
        if let track = player.current {
            Button { player.playNext(track) } label: { Label("Play Again Next", systemImage: "text.insert") }
            Button { player.addToQueue(track) } label: { Label("Add to Queue", systemImage: "text.append") }
        }
        Button { sheet = .queue } label: { Label("Up Next", systemImage: "list.bullet") }
        Button { toggleFavourite() } label: {
            Label(isFavourite ? "Remove from Favourites" : "Add to Favourites",
                  systemImage: isFavourite ? "heart.slash" : "heart")
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Button { toggleFavourite() } label: {
                Image(systemName: isFavourite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(isFavourite ? .pink : .white.opacity(0.7))
                    .frame(width: 44, height: 44)
                    .symbolEffect(.bounce, value: isFavourite)
            }
            .accessibilityLabel(isFavourite ? "Remove from Favourites" : "Add to Favourites")

            VStack(spacing: 3) {
                Text(player.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(player.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)

            Group {
                if player.isLossless {
                    Image(systemName: "waveform")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .accessibilityLabel("Lossless")
                } else {
                    Color.clear
                }
            }
            .frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    private var lyricsLines: some View {
        if !lyrics.isEmpty {
            let currentIndex = lyrics.lastIndex { ($0.time ?? .infinity) <= player.elapsed + 0.25 }
            let window: [LyricLine] = {
                guard lyrics.first?.time != nil else { return Array(lyrics.prefix(3)) }
                let center = currentIndex ?? -1
                return (center - 1...center + 1).compactMap { lyrics[safe: $0] }
            }()
            VStack(spacing: 4) {
                ForEach(window) { line in
                    Text(line.text)
                        .font(line.id == currentIndex ? .callout.weight(.semibold) : .footnote)
                        .foregroundStyle(.white.opacity(line.id == currentIndex ? 1 : 0.35))
                        .lineLimit(1)
                        .onTapGesture {
                            if let time = line.time, player.duration > 0 { player.seek(to: time / player.duration) }
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: currentIndex)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Lyrics")
        }
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Scrubber(
                progress: scrub ?? player.progress,
                enabled: player.duration > 0,
                onChange: { scrub = $0 },
                onCommit: {
                    if let scrub { player.seek(to: scrub) }
                    scrub = nil
                }
            )
            HStack {
                Text(format(position))
                Spacer()
                Text("-" + format(max(0, player.duration - position)))
            }
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var transport: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(player.shuffle ? Color.accentColor : .white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.shuffle ? "Shuffle on" : "Shuffle off")
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
                .accessibilityLabel("Previous track")
            Spacer()
            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 50))
                    .frame(width: 70, height: 70)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
                .accessibilityLabel("Next track")
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.6) : Color.accentColor)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Repeat \(player.repeatMode.rawValue)")
        }
        .sensoryFeedback(.selection, trigger: player.shuffle)
        .sensoryFeedback(.selection, trigger: player.repeatMode)
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
            RoutePicker().frame(width: 44, height: 44)
            Spacer()
            Button { sheet = .equalizer } label: {
                Image(systemName: "slider.vertical.3")
                    .foregroundStyle(player.equalizer.enabled ? Color.accentColor : .white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Equalizer")
            Spacer()
            Button { sheet = .mix } label: {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .foregroundStyle(player.mix.mode == .off ? .white.opacity(0.7) : Color.accentColor)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Mix settings")
            Spacer()
            Button { sheet = .queue } label: {
                Image(systemName: "list.bullet").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Up next")
        }
        .font(.title3)
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

    private var position: Double { (scrub ?? player.progress) * player.duration }

    private func like() {
        guard let track = player.current else { return }
        library.setFavourite(track, true)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { heartBurst = true }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.25)) { heartBurst = false }
        }
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
        let meta = player.currentMeta
        let title = meta?.title ?? MusicText.clean(player.title)
        let artist = meta?.artist ?? MusicText.clean(player.current?.folder ?? "")
        lyrics = await LyricsService.shared.lyrics(
            title: title, artist: artist.isEmpty ? nil : artist, album: meta?.album,
            duration: player.duration > 0 ? player.duration : nil
        )
    }

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
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
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
        .task(id: track.id) {
            image = await ArtworkResolver.shared.image(for: track, meta: library.meta(for: track))
        }
    }
}

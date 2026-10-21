import SwiftUI

struct MusicContentView: View {
    @EnvironmentObject private var client: SoulseekClient
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("playbox.music.username") private var username = ""

    var body: some View {
        TabView {
            NavigationStack { MusicSearchView() }
                .withMiniPlayer()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack { DownloadsView() }
                .withMiniPlayer()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .badge(client.transfers.filter(\.state.isActive).count)

            NavigationStack { MusicLibraryView() }
                .withMiniPlayer()
                .tabItem { Label("Library", systemImage: "music.note.list") }

            NavigationStack { MusicAccountView() }
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .preferredColorScheme(.dark)
        .tint(.brand)
        .task {
            player.metaProvider = { [library] track in library.meta(for: track) }
            player.similarProvider = { [library] track, played in library.similar(to: track, excluding: played) }
            client.onDownloadFinished = { url, play, meta in
                if let meta { library.setMeta(meta, for: url) }
                library.reload()
                guard play else { return }
                let tracks = library.tracks
                if let start = tracks.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                    player.play(tracks, startAt: start)
                } else {
                    player.play([library.track(for: url)], startAt: 0)
                }
            }
            await reconnectIfNeeded()
        }
        .onChange(of: library.metadata) { _, _ in player.refreshMeta() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reconnectIfNeeded() } }
        }
    }

    /// Sockets do not survive long suspensions; sign back in on return.
    private func reconnectIfNeeded() async {
        switch client.connectionState {
        case .connected, .connecting: return
        case .disconnected, .failed: break
        }
        guard !username.isEmpty, let password = CredentialStore.password(for: username) else { return }
        await client.connect(username: username, password: password)
    }
}

/// Floating mini player tinted from the artwork: swipe for next/previous,
/// swipe up or tap to open, heart, play and a progress line.
private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var client: SoulseekClient
    @State private var showNowPlaying = false
    @State private var dragOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let track = player.current {
                    bar(track)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: player.current == nil)
        }
    }

    private func bar(_ track: Track) -> some View {
        let liked = library.isFavourite(track)
        let edge: Edge = player.skipDirection >= 0 ? .trailing : .leading
        return HStack(spacing: 10) {
            Group {
                if let artwork = player.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.16))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(player.isPlaying ? 1 : 0.9)

            VStack(alignment: .leading, spacing: 1) {
                Text(player.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    if player.isMixing {
                        Image(systemName: "sparkles").foregroundStyle(Color.brand)
                    }
                    Text(player.isMixing ? "Mixing into next song" : player.subtitle).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            }
            .id(player.current)
            .transition(.push(from: edge))
            .offset(x: dragOffset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Button {
                library.setFavourite(track, !liked)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .foregroundStyle(liked ? Color.brand : .white.opacity(0.85))
                    .frame(width: 38, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(liked ? "Remove from Favourites" : "Add to Favourites")
            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 38, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: {
                Image(systemName: "forward.fill").frame(width: 34, height: 44)
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Next track")
        }
        .foregroundStyle(.white)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 7)
        .background {
            ZStack {
                player.artworkColor ?? Color(white: 0.18)
                Color.black.opacity(0.28)
            }
            .animation(.easeInOut(duration: 0.8), value: player.artworkColor)
        }
        .overlay(alignment: .bottom) {
            MiniProgressLine(clock: player.clock).padding(.horizontal, 8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .animation(.snappy(duration: 0.35), value: player.current)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: player.isPlaying)
        .contentShape(Rectangle())
        .onTapGesture { showNowPlaying = true }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                    if value.translation.width < -70 { player.next() }
                    if value.translation.width > 70 { player.previous() }
                    if value.translation.height < -50, abs(value.translation.width) < 40 { showNowPlaying = true }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open Now Playing") { showNowPlaying = true }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(client)
        }
    }
}

/// Only this line redraws as the song plays, every frame on ProMotion.
private struct MiniProgressLine: View {
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        TimelineView(.animation(paused: !clock.running)) { context in
            GeometryReader { proxy in
                let progress = clock.duration > 0 ? min(1, clock.elapsed(at: context.date) / clock.duration) : 0
                Capsule().fill(.white.opacity(0.9)).frame(width: proxy.size.width * progress, height: 2)
            }
        }
        .frame(height: 2)
    }
}

extension View {
    func withMiniPlayer() -> some View { modifier(MiniPlayerInset()) }
}

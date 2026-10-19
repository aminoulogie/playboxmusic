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

/// Black mini player: swipe for next/previous, heart, progress line.
private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var client: SoulseekClient
    @State private var showNowPlaying = false
    @State private var dragOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if let track = player.current {
                let liked = library.isFavourite(track)
                HStack(spacing: 12) {
                    Group {
                        if let artwork = player.artwork {
                            Image(uiImage: artwork).resizable().scaledToFill()
                        } else {
                            Image(systemName: "music.note")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(white: 0.16))
                        }
                    }
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(player.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .offset(x: dragOffset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    Button {
                        library.setFavourite(track, !liked)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .foregroundStyle(liked ? .pink : .white.opacity(0.8))
                            .frame(width: 40, height: 44)
                    }
                    .accessibilityLabel(liked ? "Remove from Favourites" : "Add to Favourites")
                    Button { player.togglePlayback() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 40, height: 44)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").frame(width: 40, height: 44)
                    }
                    .accessibilityLabel("Next track")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black)
                .overlay(alignment: .top) {
                    GeometryReader { proxy in
                        Rectangle().fill(.white.opacity(0.85)).frame(width: proxy.size.width * player.progress, height: 2)
                    }
                    .frame(height: 2)
                }
                .overlay(alignment: .top) { Divider().opacity(0.4) }
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
    }
}

extension View {
    func withMiniPlayer() -> some View { modifier(MiniPlayerInset()) }
}

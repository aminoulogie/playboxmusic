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

private struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject private var player: MusicPlayer
    @State private var showNowPlaying = false

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.current != nil {
                Button { showNowPlaying = true } label: {
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
                        Spacer(minLength: 0)
                        Button { player.togglePlayback() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        Button { player.next() } label: {
                            Image(systemName: "forward.fill").frame(width: 44, height: 44)
                        }
                        .disabled(!player.hasNext)
                        .accessibilityLabel("Next track")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background {
                        ZStack {
                            Color.black
                            // Faint tint from the cover, like the full player.
                            if let artwork = player.artwork {
                                Image(uiImage: artwork).resizable().scaledToFill().blur(radius: 30).opacity(0.3)
                            }
                        }
                        .clipped()
                    }
                    .overlay(alignment: .top) {
                        GeometryReader { proxy in
                            Rectangle().fill(.tint).frame(width: proxy.size.width * player.progress, height: 2)
                        }
                        .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showNowPlaying) { NowPlayingView() }
            }
        }
    }
}

extension View {
    func withMiniPlayer() -> some View { modifier(MiniPlayerInset()) }
}

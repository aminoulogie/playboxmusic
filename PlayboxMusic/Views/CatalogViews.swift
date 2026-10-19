import SwiftUI

/// iTunes-catalog results: albums as covers, songs as rows with GET buttons.
struct CatalogResultsView: View {
    let albums: [ITunesItem]
    let songs: [ITunesItem]

    var body: some View {
        if !albums.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) {
                                VStack(alignment: .leading, spacing: 4) {
                                    CatalogArtwork(url: album.artworkURL(size: 400), size: 140)
                                    Text(album.collectionName ?? "")
                                        .font(.footnote.weight(.semibold)).lineLimit(1)
                                    Text(album.artistName ?? "")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(width: 140, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            } header: {
                Text("Albums")
            }
        }

        if !songs.isEmpty {
            Section("Songs") {
                ForEach(songs) { song in
                    HStack(spacing: 12) {
                        CatalogArtwork(url: song.artworkURL(size: 200), size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(song.trackName ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                                if song.isExplicit { ExplicitBadge() }
                            }
                            Text([song.artistName, song.collectionName].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        GetSongButton(song: song)
                    }
                }
            }
        }
    }
}

/// Album page modelled on the iTunes Store layout.
struct AlbumDetailView: View {
    @EnvironmentObject private var client: SoulseekClient
    let album: ITunesItem
    @State private var tracks: [ITunesItem] = []
    @State private var loading = true

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    CatalogArtwork(url: album.artworkURL(size: 600), size: 130)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(album.collectionName ?? "").font(.headline).lineLimit(3)
                            if album.isExplicit { ExplicitBadge() }
                        }
                        Text(album.artistName ?? "").font(.subheadline).foregroundStyle(.tint).lineLimit(1)
                        Spacer(minLength: 6)
                        Group {
                            if let genre = album.primaryGenreName { Text(genre) }
                            if let count = album.trackCount { Text("\(count) Songs") }
                            if let released = album.releaseText { Text(released) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        GetAlbumButton(album: album)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Songs") {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(tracks) { track in
                    HStack(spacing: 12) {
                        Text("\(track.trackNumber ?? 0)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(track.trackName ?? "").font(.subheadline).lineLimit(1)
                                if track.isExplicit { ExplicitBadge() }
                            }
                            if track.artistName != album.artistName, let artist = track.artistName {
                                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        if let duration = track.durationText {
                            Text(duration).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        GetSongButton(song: track)
                    }
                }
            }
        }
        .navigationTitle(album.collectionName ?? "Album")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let id = album.collectionId else { return }
            tracks = (try? await ITunesCatalog.albumTracks(id)) ?? []
            loading = false
        }
    }
}

/// Outlined capsule like the iTunes price button. Finds the song on
/// Soulseek, downloads the best file and plays it.
private struct GetSongButton: View {
    @EnvironmentObject private var client: SoulseekClient
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let song: ITunesItem

    private var key: String { "song-\(song.id)" }

    var body: some View {
        FetchButton(state: client.fetches[key], transfers: client.transfers, label: "GET") {
            guard client.isConnected else { return }
            Task {
                await client.fetchSong(
                    key: key,
                    artist: song.artistName,
                    title: song.trackName ?? "",
                    durationSeconds: song.durationSeconds,
                    meta: song.trackMeta(),
                    play: true
                )
            }
        } onPlay: { url in
            library.reload()
            player.play([library.track(for: url)], startAt: 0)
        }
        .disabled(!client.isConnected)
    }
}

private struct GetAlbumButton: View {
    @EnvironmentObject private var client: SoulseekClient
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    let album: ITunesItem

    private var key: String { "album-\(album.id)" }

    var body: some View {
        FetchButton(state: client.fetches[key], transfers: client.transfers, label: "GET ALBUM") {
            guard client.isConnected else { return }
            var meta = album.trackMeta()
            meta.title = album.collectionName ?? ""
            Task {
                await client.fetchAlbum(
                    key: key,
                    artist: album.artistName,
                    album: album.collectionName ?? "",
                    trackCount: album.trackCount,
                    meta: meta,
                    play: true
                )
            }
        } onPlay: { url in
            library.reload()
            player.play([library.track(for: url)], startAt: 0)
        }
        .disabled(!client.isConnected)
    }
}

private struct FetchButton: View {
    let state: SoulseekClient.FetchState?
    let transfers: [SlskTransfer]
    let label: String
    let onGet: () -> Void
    let onPlay: (URL) -> Void

    private var owned: [SlskTransfer] {
        guard case .downloading(let ids) = state else { return [] }
        return transfers.filter { ids.contains($0.id) }
    }

    var body: some View {
        switch state {
        case .searching:
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 64, minHeight: 28)
                .overlay(Capsule().stroke(.tint, lineWidth: 1))
                .accessibilityLabel("Finding on Soulseek")
        case .downloading:
            downloading
        case .notFound:
            Button(action: onGet) { capsule("RETRY") }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .accessibilityLabel("Not found on Soulseek. Retry")
        case nil:
            Button(action: onGet) { capsule(label) }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
    }

    @ViewBuilder
    private var downloading: some View {
        let completed = owned.compactMap { transfer -> URL? in
            if case .completed(let url) = transfer.state { return url }
            return nil
        }
        if !owned.isEmpty, owned.allSatisfy({ if case .failed = $0.state { return true } else { return false } }) {
            Button(action: onGet) { capsule("RETRY") }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
        } else if let first = completed.first, completed.count == owned.count {
            Button { onPlay(first) } label: {
                Text("PLAY")
                    .font(.caption.weight(.bold))
                    .frame(minWidth: 64, minHeight: 28)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        } else {
            let progress = owned.isEmpty ? 0 : owned.map(\.progress).reduce(0, +) / Double(owned.count)
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.03, progress))
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.tint)
            }
            .frame(width: 28, height: 28)
            .frame(minWidth: 64)
            .accessibilityLabel("Downloading \(Int(progress * 100)) percent")
        }
    }

    private func capsule(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 12)
            .frame(minWidth: 64, minHeight: 28)
            .overlay(Capsule().stroke(.tint, lineWidth: 1))
            .contentShape(Capsule())
    }
}

struct CatalogArtwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color(white: 0.14).overlay {
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.07))
    }
}

private struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 13, height: 13)
            .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 2))
            .accessibilityLabel("Explicit")
    }
}

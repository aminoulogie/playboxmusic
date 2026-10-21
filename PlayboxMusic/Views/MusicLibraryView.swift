import SwiftUI

struct MusicLibraryView: View {
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer
    @State private var filter = ""

    private var visible: [Track] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return library.tracks }
        return library.tracks.filter {
            library.title(of: $0).localizedCaseInsensitiveContains(needle)
                || library.subtitle(of: $0).localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        List {
            if filter.isEmpty, !library.tracks.isEmpty {
                LibraryHeader(mix: player.mix, tracks: library.tracks)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
            }
            if filter.isEmpty, !library.favouriteTracks.isEmpty {
                Section("Favourites") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(library.favouriteTracks.enumerated()), id: \.element.id) { offset, track in
                                Button { player.play(library.favouriteTracks, startAt: offset) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ArtworkThumbnail(track: track, size: 110)
                                        Text(library.title(of: track)).font(.caption.weight(.semibold)).lineLimit(1)
                                    }
                                    .frame(width: 110)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }
            }
            ForEach(Array(visible.enumerated()), id: \.element.id) { offset, track in
                Button { player.play(visible, startAt: offset) } label: {
                    HStack(spacing: 12) {
                        ArtworkThumbnail(track: track, size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(library.title(of: track)).font(.subheadline.weight(.semibold)).lineLimit(1)
                                .foregroundStyle(player.current?.id == track.id ? Color.brand : .primary)
                            Text("\(library.subtitle(of: track)) · \(track.fileExtension)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if player.current?.id == track.id {
                            PlayingBars(active: player.isPlaying)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
                .buttonStyle(.plain)
                .animation(.snappy, value: player.current)
                .swipeActions {
                    Button("Delete", role: .destructive) { library.delete(track) }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        library.setFavourite(track, !library.isFavourite(track))
                    } label: {
                        Label("Like", systemImage: library.isFavourite(track) ? "heart.slash" : "heart")
                    }
                    .tint(.pink)
                    Button { player.playNext(track) } label: { Label("Play Next", systemImage: "text.insert") }
                        .tint(.indigo)
                }
            }
        }
        .overlay {
            if library.tracks.isEmpty {
                ContentUnavailableView(
                    "No Music Yet",
                    systemImage: "music.note.list",
                    description: Text("Downloaded tracks are saved here and in Files › Playbox Music › Music.")
                )
            }
        }
        .searchable(text: $filter, prompt: "Filter library")
        .navigationTitle("Library")
        .refreshable { library.reload() }
        .onAppear { library.reload() }
    }
}

/// Spotify-style playlist header: song count, Mix and Shuffle chips and the
/// glowing play button that plays the whole library as a mix.
private struct LibraryHeader: View {
    @EnvironmentObject private var player: MusicPlayer
    @ObservedObject var mix: MixSettings
    let tracks: [Track]

    private var playingLibrary: Bool {
        guard let current = player.current else { return false }
        return tracks.contains(current)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy) { mix.mode = mix.isOn ? .off : .auto }
                    } label: {
                        ChipLabel(title: "Mix", symbol: "slider.horizontal.3", ring: mix.isOn)
                    }
                    Button {
                        if !player.shuffle { player.toggleShuffle() }
                        player.play(tracks.shuffled(), startAt: 0)
                    } label: {
                        ChipLabel(title: "Shuffle", symbol: "shuffle")
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            GlowPlayButton(isPlaying: player.isPlaying && playingLibrary) {
                if playingLibrary {
                    player.togglePlayback()
                } else {
                    player.play(tracks, startAt: 0)
                }
            }
            .padding(.trailing, 6)
        }
        .sensoryFeedback(.selection, trigger: mix.isOn)
    }
}

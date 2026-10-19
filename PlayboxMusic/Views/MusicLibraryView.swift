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
                            Text("\(library.subtitle(of: track)) · \(track.fileExtension)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if player.current?.id == track.id {
                            Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
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

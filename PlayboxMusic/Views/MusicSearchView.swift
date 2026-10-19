import SwiftUI

struct MusicSearchView: View {
    @EnvironmentObject private var client: SoulseekClient
    @State private var query = ""
    @State private var audioOnly = true
    @State private var sort: Sort = .best
    @State private var mode: Mode = .catalog
    @State private var albums: [ITunesItem] = []
    @State private var songs: [ITunesItem] = []
    @State private var catalogLoading = false

    enum Mode: String, CaseIterable, Identifiable {
        case catalog = "Catalog"
        case soulseek = "Soulseek"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case best = "Best match"
        case quality = "Quality"
        case size = "Size"
        var id: String { rawValue }
    }

    private var visibleResults: [SlskSearchResult] {
        let filtered = audioOnly ? client.results.filter(\.isAudio) : client.results
        let sorted: [SlskSearchResult]
        switch sort {
        case .best:
            // Prefer users who can start immediately, then fast, short queues.
            sorted = filtered.sorted {
                if $0.freeSlots != $1.freeSlots { return $0.freeSlots }
                if $0.queueLength != $1.queueLength { return $0.queueLength < $1.queueLength }
                return $0.uploadSpeed > $1.uploadSpeed
            }
        case .quality:
            sorted = filtered.sorted { Self.qualityScore($0) > Self.qualityScore($1) }
        case .size:
            sorted = filtered.sorted { $0.size > $1.size }
        }
        return Array(sorted.prefix(400))
    }

    var body: some View {
        List {
            Section {
                Picker("Search", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if !client.isConnected {
                Section {
                    NavigationLink {
                        MusicAccountView()
                    } label: {
                        Label("Sign in to Soulseek to download", systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                }
            }

            if mode == .catalog {
                CatalogResultsView(albums: albums, songs: songs)
            } else if !client.results.isEmpty || client.isSearching {
                Section {
                    ForEach(visibleResults) { result in
                        ResultRow(result: result)
                    }
                } header: {
                    HStack {
                        Text("\(visibleResults.count) of \(client.results.count) files")
                        if client.isSearching {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
        }
        .overlay {
            if mode == .catalog {
                if catalogLoading && albums.isEmpty && songs.isEmpty {
                    ProgressView()
                } else if albums.isEmpty && songs.isEmpty {
                    ContentUnavailableView(
                        "Find Music",
                        systemImage: "music.magnifyingglass",
                        description: Text("Search albums and songs, then tap GET to download the best copy from Soulseek.")
                    )
                }
            } else if client.isConnected && client.results.isEmpty && !client.isSearching {
                ContentUnavailableView(
                    "Search Soulseek",
                    systemImage: "music.magnifyingglass",
                    description: Text("Try an artist and album or track title. Results arrive from peers over a few seconds.")
                )
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Artist, album or track")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onSubmit(of: .search) {
            if mode == .soulseek { Task { await client.search(query) } }
        }
        // The catalog is fast, so it searches as you type.
        .task(id: mode == .catalog ? query : "") {
            guard mode == .catalog else { return }
            let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 2 else {
                albums = []
                songs = []
                return
            }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            catalogLoading = true
            defer { catalogLoading = false }
            async let foundAlbums = try? ITunesCatalog.search(term, entity: "album", limit: 20)
            async let foundSongs = try? ITunesCatalog.search(term, entity: "song", limit: 40)
            let (newAlbums, newSongs) = await (foundAlbums ?? [], foundSongs ?? [])
            guard !Task.isCancelled else { return }
            albums = newAlbums
            songs = newSongs
        }
        .navigationDestination(for: ITunesItem.self) { AlbumDetailView(album: $0) }
        .toolbar {
            Menu {
                Toggle("Audio files only", isOn: $audioOnly)
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Filter and sort")
            .opacity(mode == .soulseek ? 1 : 0)
            .disabled(mode != .soulseek)
        }
    }

    private static func qualityScore(_ result: SlskSearchResult) -> Double {
        let lossless: Set<String> = ["flac", "alac", "wav", "aif", "aiff", "ape", "wv"]
        if lossless.contains(result.fileExtension) {
            return 10_000 + Double(result.bitDepth ?? 16) * 100 + Double(result.sampleRate ?? 44_100) / 1000
        }
        return Double(result.bitrate ?? 0)
    }
}

private struct ResultRow: View {
    @EnvironmentObject private var client: SoulseekClient
    let result: SlskSearchResult

    private var transfer: SlskTransfer? {
        client.transfers.first { $0.result.id == result.id }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(result.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(result.freeSlots ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(result.freeSlots ? "Free upload slot" : "Queued uploads")
                    Text(result.username).lineLimit(1)
                    Text("·")
                    Text(result.qualityText).lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let transfer, transfer.state.isActive {
                    Text(transfer.statusText).font(.caption2).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
            Button { client.download(result, play: true) } label: {
                Image(systemName: "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download and play")
            Button { client.download(result, play: false) } label: {
                Image(systemName: "arrow.down.circle").font(.title2)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Download")
        }
    }
}

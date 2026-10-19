import SwiftUI

struct MusicSearchView: View {
    @EnvironmentObject private var client: SoulseekClient
    @State private var query = ""
    @State private var audioOnly = true
    @State private var sort: Sort = .best

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
            if !client.isConnected {
                Section {
                    NavigationLink {
                        MusicAccountView()
                    } label: {
                        Label("Sign in to Soulseek to search", systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                }
            }

            if !client.results.isEmpty || client.isSearching {
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
            if client.isConnected && client.results.isEmpty && !client.isSearching {
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
        .onSubmit(of: .search) { Task { await client.search(query) } }
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

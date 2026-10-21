import SwiftUI

/// Ten-band equalizer with presets.
struct EqualizerView: View {
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        EqualizerForm(equalizer: player.equalizer)
            .presentationDetents([.medium, .large])
    }
}

private struct EqualizerForm: View {
    @ObservedObject var equalizer: EqualizerSettings

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Toggle("Equalizer", isOn: $equalizer.enabled)
                Menu {
                    ForEach(EqualizerSettings.presets.map { $0.0 }, id: \.self) { name in
                        Button(name) { equalizer.apply(preset: name) }
                    }
                } label: {
                    HStack {
                        Text("Preset")
                        Spacer()
                        Text(equalizer.presetName).foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<10, id: \.self) { band in
                        VStack(spacing: 6) {
                            Text(String(format: "%+.0f", equalizer.gains[band]))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { Double(equalizer.gains[band]) },
                                set: {
                                    equalizer.gains[band] = Float($0)
                                    equalizer.presetName = "Custom"
                                    equalizer.enabled = true
                                }
                            ), in: -12...12)
                            .rotationEffect(.degrees(-90))
                            .frame(width: 170, height: 28)
                            .frame(width: 30, height: 170)
                            .accessibilityLabel("\(label(EqualizerSettings.frequencies[band])) band")
                            Text(label(EqualizerSettings.frequencies[band]))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .disabled(!equalizer.enabled)
                .opacity(equalizer.enabled ? 1 : 0.4)
                Spacer()
            }
            .padding()
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func label(_ frequency: Float) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }
}

/// Finds the catalog album for the playing song and shows its page.
struct AlbumLookupView: View {
    let meta: TrackMeta?
    let fallbackTitle: String
    @State private var album: ITunesItem?
    @State private var searched = false

    var body: some View {
        NavigationStack {
            Group {
                if let album {
                    AlbumDetailView(album: album)
                } else if searched {
                    ContentUnavailableView("Album Not Found", systemImage: "square.stack",
                                           description: Text("No catalog album matched this song."))
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(for: ITunesItem.self) { item in
                if item.wrapperType == "artist" { ArtistView(artist: item) } else { AlbumDetailView(album: item) }
            }
        }
        .task {
            let term = [meta?.artist, meta?.album ?? meta?.title ?? MusicText.clean(fallbackTitle)]
                .compactMap { $0 }.joined(separator: " ")
            album = try? await ITunesCatalog.search(term, entity: "album", limit: 1).first
            searched = true
        }
    }
}

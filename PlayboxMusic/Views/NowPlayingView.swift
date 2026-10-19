import AVKit
import SwiftUI

/// Full-bleed artwork that fades into black, with title and controls
/// sitting inside the fade.
struct NowPlayingView: View {
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?
    @State private var showQueue = false

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                // A blurred copy tints the black so the page feels lit by the cover.
                if let artwork = player.artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
                        .blur(radius: 70)
                        .opacity(0.28)
                        .clipped()
                        .ignoresSafeArea()
                }

                VStack(spacing: 0) {
                    cover(side: side, topInset: proxy.safeAreaInsets.top)
                    controls
                        .padding(.horizontal, 26)
                        .padding(.top, 6)
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: .top)

                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.35), in: Circle())
                    }
                    .accessibilityLabel("Close Now Playing")
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .presentationBackground(.black)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showQueue) { QueueView() }
    }

    private func cover(side: CGFloat, topInset: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                if let artwork = player.artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color(white: 0.16), .black], startPoint: .top, endPoint: .bottom)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 90, weight: .light))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                }
            }
            .frame(width: side, height: side + topInset)
            .clipped()

            // Fade the lower part of the artwork into the page.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.55), location: 0.7),
                    .init(color: .black.opacity(0.9), location: 0.88),
                    .init(color: .black, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: side + topInset)

            // Keep the status bar readable over bright covers.
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: topInset + 70)
                .frame(maxHeight: .infinity, alignment: .top)

            VStack(spacing: 4) {
                Text(player.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                Text(player.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.bottom, 14)
        }
        .frame(width: side, height: side + topInset)
    }

    private var controls: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
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
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
            }

            HStack {
                RoutePicker()
                    .frame(width: 44, height: 44)
                Spacer()
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title)
                }
                .accessibilityLabel("Previous track")
                Spacer()
                Button { player.togglePlayback() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 46))
                        .frame(width: 64, height: 64)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Spacer()
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title)
                }
                .disabled(!player.hasNext)
                .opacity(player.hasNext ? 1 : 0.35)
                .accessibilityLabel("Next track")
                Spacer()
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Up next")
            }
        }
    }

    private var position: Double { (scrub ?? player.progress) * player.duration }

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A thin capsule progress bar that thickens while dragging.
private struct Scrubber: View {
    let progress: Double
    let enabled: Bool
    let onChange: (Double) -> Void
    let onCommit: () -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(dragging ? 1 : 0.85))
                    .frame(width: max(0, min(1, progress)) * proxy.size.width)
            }
            .frame(height: dragging ? 9 : 5)
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

private struct QueueView: View {
    @EnvironmentObject private var player: MusicPlayer
    @EnvironmentObject private var library: MusicLibrary

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { offset, track in
                    Button { player.play(player.queue, startAt: offset) } label: {
                        HStack(spacing: 12) {
                            ArtworkThumbnail(track: track, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.title(of: track)).lineLimit(1)
                                Text(library.subtitle(of: track)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if offset == player.index {
                                Image(systemName: "waveform").foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
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

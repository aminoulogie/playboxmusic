import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var player: MusicPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 24) {
            Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)
            Spacer()
            Image(systemName: "music.note")
                .font(.system(size: 90))
                .frame(width: 260, height: 260)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 24))
            VStack(spacing: 6) {
                Text(player.current?.title ?? "Not Playing")
                    .font(.title2.bold()).multilineTextAlignment(.center).lineLimit(2)
                Text(player.current?.folder ?? "")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(spacing: 4) {
                Slider(
                    value: Binding(get: { scrub ?? player.progress }, set: { scrub = $0 }),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing, let scrub {
                            player.seek(to: scrub)
                            self.scrub = nil
                        }
                    }
                )
                .disabled(player.duration <= 0)
                .accessibilityLabel("Playback position")
                HStack {
                    Text(format((scrub ?? player.progress) * player.duration))
                    Spacer()
                    Text(format(player.duration))
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 44) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    .accessibilityLabel("Previous track")
                Button { player.togglePlayback() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                    .disabled(!player.hasNext)
                    .accessibilityLabel("Next track")
            }
            .font(.title)
            Spacer()
        }
        .padding(.horizontal, 28)
        .presentationDragIndicator(.hidden)
    }

    private func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var client: SoulseekClient
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var player: MusicPlayer

    var body: some View {
        List {
            ForEach(client.transfers) { transfer in
                Button { open(transfer) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(transfer.result.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(transfer.result.username) · \(transfer.result.qualityText)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if case .transferring = transfer.state {
                            ProgressView(value: transfer.progress)
                        }
                        Text(transfer.statusText)
                            .font(.caption)
                            .foregroundStyle(statusColor(transfer.state))
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Remove", role: .destructive) { client.remove(transfer.id) }
                }
            }
        }
        .overlay {
            if client.transfers.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Downloads from Search appear here.")
                )
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            Button("Clear Finished") { client.clearFinished() }
                .disabled(!client.transfers.contains { !$0.state.isActive })
        }
    }

    private func open(_ transfer: SlskTransfer) {
        switch transfer.state {
        case .completed(let url):
            library.reload()
            player.play([library.track(for: url)], startAt: 0)
        case .failed:
            client.retry(transfer.id)
        default:
            break
        }
    }

    private func statusColor(_ state: SlskTransfer.State) -> Color {
        switch state {
        case .completed: .green
        case .failed: .red
        default: .secondary
        }
    }
}

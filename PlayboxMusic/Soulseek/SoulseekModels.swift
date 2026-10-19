import Foundation

struct SlskSearchResult: Identifiable, Hashable, Sendable {
    let username: String
    let filename: String
    let size: UInt64
    let bitrate: UInt32?
    let duration: UInt32?
    let sampleRate: UInt32?
    let bitDepth: UInt32?
    let freeSlots: Bool
    let uploadSpeed: UInt32
    let queueLength: UInt32

    var id: String { username + "\u{1F}" + filename }

    /// Soulseek paths use backslashes regardless of the sharer's platform.
    private var components: [String] {
        filename.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
    }

    var title: String {
        let name = components.last ?? filename
        return (name as NSString).deletingPathExtension
    }

    var folder: String {
        components.dropLast().suffix(2).joined(separator: " / ")
    }

    var fileExtension: String {
        ((components.last ?? filename) as NSString).pathExtension.lowercased()
    }

    var isAudio: Bool { SlskAudio.extensions.contains(fileExtension) }

    var qualityText: String {
        var parts = [fileExtension.uppercased()]
        if let bitDepth, let sampleRate, bitDepth > 0, sampleRate > 0 {
            parts.append("\(bitDepth)-bit/\(String(format: "%g", Double(sampleRate) / 1000)) kHz")
        } else if let bitrate, bitrate > 0 {
            parts.append("\(bitrate) kbps")
        }
        if let duration, duration > 0 {
            parts.append(String(format: "%d:%02d", duration / 60, duration % 60))
        }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

enum SlskAudio {
    static let extensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "alac", "ogg", "oga", "opus", "wav", "aif", "aiff", "wma", "ape", "wv"
    ]
}

struct SlskTransfer: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case connecting
        case requested
        case queued(position: UInt32?)
        case transferring
        case completed(URL)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .completed, .failed: false
            default: true
            }
        }
    }

    let id = UUID()
    let result: SlskSearchResult
    var state: State = .connecting
    var token: UInt32?
    var size: UInt64
    var received: UInt64 = 0
    var bytesPerSecond: Double = 0
    var playWhenFinished: Bool

    var progress: Double {
        size > 0 ? min(Double(received) / Double(size), 1) : 0
    }

    var statusText: String {
        switch state {
        case .connecting: "Connecting to \(result.username)…"
        case .requested: "Requested"
        case .queued(let position):
            position.map { "Queued · position \($0)" } ?? "Queued by \(result.username)"
        case .transferring:
            "\(String(format: "%.1f%%", progress * 100)) · \(Self.bytes(received)) of \(Self.bytes(size)) · \(Self.bytes(UInt64(max(0, bytesPerSecond))))/s"
        case .completed: "Downloaded"
        case .failed(let reason): reason
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}

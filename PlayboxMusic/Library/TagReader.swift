import AVFoundation

/// Works out a song's title, artist and album: first from the tags inside
/// the file, then from Soulseek-style file and folder names such as
/// "Artist - Album (2020) [FLAC]/03 - Artist - Title.flac".
enum TagReader {
    static func meta(for url: URL) async -> TrackMeta {
        var title: String?
        var artist: String?
        var album: String?

        let asset = AVURLAsset(url: url)
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                switch item.commonKey {
                case .commonKeyTitle?: title = title ?? value
                case .commonKeyArtist?: artist = artist ?? value
                case .commonKeyAlbumName?: album = album ?? value
                default: break
                }
            }
        }

        let parsed = parse(url)
        return TrackMeta(
            title: title ?? parsed.title,
            artist: artist ?? parsed.artist,
            album: album ?? parsed.album,
            artworkURL: nil
        )
    }

    static func parse(_ url: URL) -> (title: String, artist: String?, album: String?) {
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent().lastPathComponent

        // Folder: "Artist - Album (Year) [Format]" → artist, album.
        let folderParts = strip(folder).components(separatedBy: " - ")
        var folderArtist: String?
        var folderAlbum: String?
        if folderParts.count >= 2 {
            folderArtist = folderParts[0]
            folderAlbum = folderParts.dropFirst().joined(separator: " - ")
        } else if !folder.isEmpty, folder != "Music" {
            folderAlbum = strip(folder)
        }

        // File: "03 - Artist - Title", "03. Title", "Artist - Title".
        var name = stem.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: #"^\s*(\d{1,2}[-.])?\d{1,3}\s*[-.)]?\s+"#, with: "", options: .regularExpression)
        let parts = name.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        var title = parts.last ?? name
        var artist = folderArtist
        if parts.count >= 2 {
            artist = parts[0]
            title = parts.dropFirst().joined(separator: " - ")
        }
        title = title.trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? stem : title, artist, folderAlbum)
    }

    /// Removes "(2020)", "[FLAC]", "{Web}" and similar tags.
    private static func strip(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s*[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

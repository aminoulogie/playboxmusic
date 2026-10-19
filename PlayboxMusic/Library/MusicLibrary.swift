import Combine
import Foundation
import Security

struct Track: Identifiable, Hashable {
    let url: URL
    let addedAt: Date

    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var folder: String { url.deletingLastPathComponent().lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }
}

/// Catalog details saved for a downloaded file (title, artist, album, cover).
struct TrackMeta: Codable, Hashable, Sendable {
    var title: String
    var artist: String?
    var album: String?
    var artworkURL: URL?
}

/// Lists audio files downloaded into Documents/Music (also visible in the Files app).
@MainActor
final class MusicLibrary: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var metadata: [String: TrackMeta] = [:]
    @Published private(set) var favourites: Set<String> = []
    let root: URL

    private var metadataURL: URL { root.appendingPathComponent(".playbox-metadata.json") }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: metadataURL),
           let saved = try? JSONDecoder().decode([String: TrackMeta].self, from: data) {
            metadata = saved
        }
        favourites = Set(UserDefaults.standard.stringArray(forKey: "music.favourites") ?? [])
        reload()
    }

    var favouriteTracks: [Track] { tracks.filter(isFavourite) }

    func isFavourite(_ track: Track) -> Bool { favourites.contains(key(for: track.url)) }

    func setFavourite(_ track: Track, _ value: Bool) {
        let id = key(for: track.url)
        if value { favourites.insert(id) } else { favourites.remove(id) }
        UserDefaults.standard.set(Array(favourites), forKey: "music.favourites")
    }

    /// Songs to autoplay after the queue: same artist, then same folder, then
    /// favourites, then anything else not played recently.
    func similar(to track: Track, excluding played: [Track], limit: Int = 10) -> [Track] {
        let exclude = Set(played.suffix(50))
        let pool = tracks.filter { !exclude.contains($0) }
        let artist = meta(for: track)?.artist?.lowercased()
        let sameArtist = pool.filter { artist != nil && meta(for: $0)?.artist?.lowercased() == artist }
        let sameFolder = pool.filter { $0.url.deletingLastPathComponent() == track.url.deletingLastPathComponent() }
        let liked = pool.filter(isFavourite)
        var picked: [Track] = []
        for candidate in sameArtist.shuffled() + sameFolder + liked.shuffled() + pool.shuffled()
        where !picked.contains(candidate) {
            picked.append(candidate)
            if picked.count == limit { break }
        }
        return picked
    }

    /// Whether a catalog song is already downloaded.
    func has(title: String?, artist: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return metadata.values.contains {
            $0.title.lowercased() == title && (artist == nil || $0.artist?.lowercased() == artist?.lowercased())
        }
    }

    func meta(for track: Track) -> TrackMeta? { metadata[key(for: track.url)] }

    func setMeta(_ meta: TrackMeta, for url: URL) {
        metadata[key(for: url)] = meta
        if let data = try? JSONEncoder().encode(metadata) { try? data.write(to: metadataURL, options: .atomic) }
    }

    func title(of track: Track) -> String { meta(for: track)?.title ?? track.title }

    func subtitle(of track: Track) -> String {
        guard let meta = meta(for: track) else { return track.folder }
        return [meta.artist, meta.album].compactMap { $0 }.joined(separator: " — ")
    }

    /// Keys are relative to the Music folder because the app container path changes.
    private func key(for url: URL) -> String {
        let base = root.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    func reload() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            tracks = []
            return
        }
        var found: [Track] = []
        for case let url as URL in enumerator
        where SlskAudio.extensions.contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            found.append(Track(url: url, addedAt: values?.contentModificationDate ?? .distantPast))
        }
        tracks = found.sorted { $0.addedAt > $1.addedAt }
    }

    func track(for url: URL) -> Track {
        tracks.first { $0.url.standardizedFileURL == url.standardizedFileURL }
            ?? Track(url: url, addedAt: Date())
    }

    func delete(_ track: Track) {
        try? FileManager.default.removeItem(at: track.url)
        metadata[key(for: track.url)] = nil
        reload()
    }
}

/// Stores the Soulseek password in the Keychain rather than UserDefaults.
enum CredentialStore {
    private static let service = "com.playboxapp.music.soulseek"

    static func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

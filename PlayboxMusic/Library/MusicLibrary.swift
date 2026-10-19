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

/// Lists audio files downloaded into Documents/Music (also visible in the Files app).
@MainActor
final class MusicLibrary: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    let root: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
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

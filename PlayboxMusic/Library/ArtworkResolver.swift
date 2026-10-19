import AVFoundation
import CryptoKit
import UIKit

/// Finds cover art: catalog URL, then a cover image in the album folder,
/// then embedded artwork, then an iTunes lookup. Results are cached.
actor ArtworkResolver {
    static let shared = ArtworkResolver()

    private let memory = NSCache<NSString, UIImage>()
    private var misses = Set<String>()
    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for track: Track, meta: TrackMeta?) async -> UIImage? {
        let key = track.url.path
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if misses.contains(key) { return nil }

        var image: UIImage?
        if let remote = meta?.artworkURL { image = await remoteImage(remote) }
        if image == nil { image = folderImage(near: track.url) }
        if image == nil { image = await embeddedImage(in: track.url) }
        if image == nil {
            let term = [meta?.artist, meta?.title ?? MusicText.clean(track.title)].compactMap { $0 }.joined(separator: " ")
            if let url = await ITunesCatalog.bestMatch(term)?.artworkURL(size: 1000) {
                image = await remoteImage(url)
            }
        }

        if let image { memory.setObject(image, forKey: key as NSString) } else { misses.insert(key) }
        return image
    }

    func remoteImage(_ url: URL) async -> UIImage? {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(digest + ".jpg")
        if let image = UIImage(contentsOfFile: file.path) { return image }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return nil }
        try? data.write(to: file)
        return image
    }

    private func folderImage(near url: URL) -> UIImage? {
        let folder = url.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let images = files.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
        let preferred = images.first { name in
            ["cover", "folder", "front"].contains { name.lastPathComponent.lowercased().contains($0) }
        } ?? images.first
        return preferred.flatMap { UIImage(contentsOfFile: $0.path) }
    }

    private func embeddedImage(in url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), let image = UIImage(data: data) {
                return image
            }
        }
        return nil
    }
}

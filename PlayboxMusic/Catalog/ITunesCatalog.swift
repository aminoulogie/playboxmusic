import Foundation

/// An album or song from the public iTunes Search API (no account or key).
struct ITunesItem: Decodable, Identifiable, Hashable {
    let wrapperType: String?
    let collectionId: Int?
    let trackId: Int?
    let artistName: String?
    let collectionName: String?
    let trackName: String?
    let artworkUrl100: String?
    let releaseDate: String?
    let primaryGenreName: String?
    let trackCount: Int?
    let trackNumber: Int?
    let discNumber: Int?
    let trackTimeMillis: Int?
    let collectionExplicitness: String?
    let trackExplicitness: String?

    var id: Int { trackId ?? collectionId ?? 0 }
    var isExplicit: Bool { (trackExplicitness ?? collectionExplicitness) == "explicit" }
    var durationSeconds: Int? { trackTimeMillis.map { $0 / 1000 } }

    var durationText: String? {
        durationSeconds.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
    }

    func artworkURL(size: Int) -> URL? {
        guard let artworkUrl100 else { return nil }
        return URL(string: artworkUrl100.replacingOccurrences(of: "100x100", with: "\(size)x\(size)"))
    }

    var releaseText: String? {
        guard let releaseDate, let date = ISO8601DateFormatter().date(from: releaseDate) else { return nil }
        return "Released " + date.formatted(date: .abbreviated, time: .omitted)
    }

    func trackMeta() -> TrackMeta {
        TrackMeta(title: trackName ?? collectionName ?? "", artist: artistName, album: collectionName, artworkURL: artworkURL(size: 1000))
    }
}

enum ITunesCatalog {
    private struct Response: Decodable { let results: [ITunesItem] }

    static func search(_ term: String, entity: String, limit: Int = 25) async throws -> [ITunesItem] {
        try await get("search", [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(limit))
        ])
    }

    static func albumTracks(_ collectionId: Int) async throws -> [ITunesItem] {
        try await get("lookup", [
            URLQueryItem(name: "id", value: String(collectionId)),
            URLQueryItem(name: "entity", value: "song")
        ])
        .filter { $0.wrapperType == "track" }
        .sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
    }

    /// Best-effort cover lookup for files that carry no artwork.
    static func bestMatch(_ term: String) async -> ITunesItem? {
        guard !term.isEmpty else { return nil }
        return try? await search(term, entity: "song", limit: 1).first
    }

    private static func get(_ path: String, _ query: [URLQueryItem]) async throws -> [ITunesItem] {
        var components = URLComponents(string: "https://itunes.apple.com/\(path)")!
        components.queryItems = query
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Response.self, from: data).results
    }
}

enum MusicText {
    /// Strips track numbers, bracketed tags and separators so names search well.
    static func clean(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: #"[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\s*\d{1,3}([\-\.]\d{1,3})?\s*[\-\.]?\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+-\s+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[^\p{L}\p{N}' ]"#, with: " ", options: .regularExpression)
        return text.split(separator: " ").joined(separator: " ")
    }
}

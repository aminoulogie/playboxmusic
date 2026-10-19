import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double?
    let text: String
}

/// Synced lyrics from LRCLIB (lrclib.net), a free, open lyrics database.
actor LyricsService {
    static let shared = LyricsService()

    private struct Response: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let instrumental: Bool?
    }

    private var cache: [String: [LyricLine]] = [:]

    func lyrics(title: String, artist: String?, album: String?, duration: Double?) async -> [LyricLine] {
        let key = [artist ?? "", title].joined(separator: "|").lowercased()
        if let cached = cache[key] { return cached }

        var lines: [LyricLine] = []
        if let artist {
            var query = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist)
            ]
            if let album { query.append(URLQueryItem(name: "album_name", value: album)) }
            if let duration, duration > 0 { query.append(URLQueryItem(name: "duration", value: String(Int(duration)))) }
            if let response: Response = await fetch("get", query) { lines = Self.parse(response) }
        }
        if lines.isEmpty {
            let term = [artist, title].compactMap { $0 }.joined(separator: " ")
            if let results: [Response] = await fetch("search", [URLQueryItem(name: "q", value: term)]),
               let best = results.first(where: { $0.syncedLyrics != nil }) ?? results.first {
                lines = Self.parse(best)
            }
        }
        cache[key] = lines
        return lines
    }

    private func fetch<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async -> T? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")!
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Playbox Music (https://github.com/aminoulogie/playbox)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func parse(_ response: Response) -> [LyricLine] {
        if response.instrumental == true { return [LyricLine(id: 0, time: nil, text: "♪ Instrumental ♪")] }
        if let synced = response.syncedLyrics, !synced.isEmpty {
            var lines: [LyricLine] = []
            for raw in synced.split(separator: "\n") {
                // [mm:ss.xx] text
                guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { continue }
                let stamp = raw[raw.index(after: raw.startIndex)..<close].split(separator: ":")
                guard stamp.count == 2, let minutes = Double(stamp[0]), let seconds = Double(stamp[1]) else { continue }
                let text = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespaces)
                lines.append(LyricLine(id: lines.count, time: minutes * 60 + seconds, text: text.isEmpty ? "♪" : text))
            }
            if !lines.isEmpty { return lines }
        }
        return (response.plainLyrics ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { LyricLine(id: $0.offset, time: nil, text: String($0.element)) }
            .filter { !$0.text.isEmpty }
    }
}

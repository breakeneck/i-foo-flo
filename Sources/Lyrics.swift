// Lyrics — LRCLIB first (free, synced LRC), Genius as plain-text fallback.

import Foundation

struct LyricLine {
    var time: Double
    var text: String
}

struct LyricsResult {
    var synced: [LyricLine]
    var plain: String?
    var source: String
}

@MainActor
enum Lyrics {
    // [mm:ss.xx] text lines, possibly multiple timestamps per line
    static func parseLRC(_ s: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let re = try! NSRegularExpression(pattern: "\\[(\\d+):(\\d+(?:\\.\\d+)?)\\]")
        for raw in s.components(separatedBy: "\n") {
            let line = raw
            var times: [Double] = []
            let range = NSRange(raw.startIndex..., in: raw)
            for m in re.matches(in: raw, range: range) {
                guard let gr = Range(m.range, in: raw),
                      let min = Double(String(raw[Range(m.range(at: 1), in: raw)!])),
                      let sec = Double(String(raw[Range(m.range(at: 2), in: raw)!]))
                else { continue }
                times.append(min * 60 + sec)
                _ = gr
            }
            let text = re.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            for t in times where !text.isEmpty {
                out.append(LyricLine(time: t, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    static func fetch(artist: String, title: String, album: String,
                      duration: TimeInterval) async -> LyricsResult? {
        if let r = await lrclib(artist: artist, title: title, album: album, duration: duration) {
            return r
        }
        if let r = await lrclibSearch(artist: artist, title: title) { return r }
        if let r = await genius(artist: artist, title: title) { return r }
        return nil
    }

    private static func lrclib(artist: String, title: String, album: String,
                               duration: TimeInterval) async -> LyricsResult? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            .init(name: "artist_name", value: artist),
            .init(name: "track_name", value: title),
            .init(name: "album_name", value: album),
            .init(name: "duration", value: String(Int(duration))),
        ]
        guard let obj = await get(comps.url) else { return nil }
        return decode(obj, source: "LRCLIB")
    }

    private static func lrclibSearch(artist: String, title: String) async -> LyricsResult? {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [
            .init(name: "artist_name", value: artist),
            .init(name: "track_name", value: title),
        ]
        guard let data = try? await URLSession.shared.data(from: comps.url!).0,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first(where: { ($0["syncedLyrics"] as? String)?.isEmpty == false })
                ?? arr.first else { return nil }
        return decode(first, source: "LRCLIB")
    }

    private static func decode(_ obj: [String: Any], source: String) -> LyricsResult? {
        let syncedStr = obj["syncedLyrics"] as? String
        let plainStr = obj["plainLyrics"] as? String
        let synced = (syncedStr ?? "").isEmpty ? [] : parseLRC(syncedStr!)
        if synced.isEmpty && (plainStr ?? "").isEmpty { return nil }
        return LyricsResult(synced: synced, plain: plainStr, source: source)
    }

    private static func genius(artist: String, title: String) async -> LyricsResult? {
        let token = Config.shared.geniusToken
        guard !token.isEmpty else { return nil }
        var comps = URLComponents(string: "https://api.genius.com/search")!
        comps.queryItems = [.init(name: "q", value: "\(artist) \(title)")]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = obj.path("response", "hits") as? [[String: Any]],
              let urlStr = hits.first?.path("result", "url") as? String,
              let page = try? await URLSession.shared.data(from: URL(string: urlStr)!).0
        else { return nil }
        // scrape lyrics div: <div class="...lyrics..."> ... </div>
        guard let html = String(data: page, encoding: .utf8),
              let start = html.range(of: "class=\"Lyrics__Container"),
              let end = html.range(of: "</div>", range: start.upperBound..<html.endIndex)
        else { return nil }
        var body = String(html[start.upperBound..<end.lowerBound])
        body = body.replacingOccurrences(of: "<br/>", with: "\n")
        body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        body = body.removingPercentEncoding ?? body
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : LyricsResult(synced: [], plain: text, source: "Genius")
    }

    private static func get(_ url: URL?) async -> [String: Any]? {
        guard let url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension Dictionary {
    fileprivate func path(_ keys: String...) -> Any? {
        var cur: Any? = self
        for k in keys {
            guard let d = cur as? [String: Any] else { return nil }
            cur = d[k]
        }
        return cur
    }
}
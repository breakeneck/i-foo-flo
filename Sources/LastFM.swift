// Last.fm — API v2 with api_sig signing (same key the Python app uses).
// Scrobbles, now-playing, love/unlove, per-track playcount.

import Foundation

// strip '01. ' / '07 - ' track-number prefixes and trailing '(1999)' year —
// Last.fm and lyrics sites don't index those
func cleanQueryTitle(_ s: String) -> String {
    var t = s
    if let r = t.range(of: "^\\s*\\d{1,3}\\s*[.\\-_]\\s*", options: .regularExpression) {
        t.removeSubrange(r)
    }
    if let r = t.range(of: "\\s*\\((?:19|20)\\d{2}\\)\\s*$", options: .regularExpression) {
        t.removeSubrange(r)
    }
    return t.trimmingCharacters(in: .whitespaces)
}

@MainActor
final class LastFM {
    static let shared = LastFM()

    private let apiKey = "ad6ab7666c6d445fd6a65957d4ff823e"
    private let apiSecret = "c0b02d43ce286b7da4d54138bd0f75c0"
    private let base = "https://ws.audioscrobbler.com/2.0/"
    private var sessionKey: String?
    private var authFailed = false

    var isEnabled: Bool {
        Config.shared.lastfmEnabled && !Config.shared.lastfmUser.isEmpty
            && !Config.shared.lastfmPassword.isEmpty
    }

    private func signed(_ params: [String: String], write: Bool) -> [String: String] {
        var p = params
        p["api_key"] = apiKey
        if write, let sk = sessionKey { p["sk"] = sk }
        let sig = p.keys.sorted().map { $0 + (p[$0] ?? "") }.joined() + apiSecret
        p["api_sig"] = sig.md5hex
        p["format"] = "json"
        return p
    }

    @discardableResult
    func login() async -> Bool {
        guard isEnabled else { return false }
        if sessionKey != nil { return true }
        let user = Config.shared.lastfmUser
        let pass = Config.shared.lastfmPassword
        // mobile session: authToken = md5(username + md5(password)) (current Last.fm scheme)
        var p = ["method": "auth.getMobileSession", "username": user,
                 "authToken": (user + pass.md5hex).md5hex]
        p["api_key"] = apiKey
        let sig = p.keys.sorted().map { $0 + p[$0]! }.joined() + apiSecret
        p["api_sig"] = sig.md5hex
        p["format"] = "json"
        guard let obj = await request(method: "POST", params: p),
              let key = obj.pathAny("session", "key") as? String else {
            print("fm login FAILED")
            authFailed = true
            return false
        }
        sessionKey = key
        return true
    }

    func updateNowPlaying(artist: String, title: String) {
        guard isEnabled else { return }
        Task {
            await login()
            _ = await request(method: "POST", params: signed(
                ["method": "track.updateNowPlaying", "artist": artist, "track": cleanQueryTitle(title)],
                write: true))
        }
    }

    func scrobble(artist: String, title: String, album: String, start: Date) {
        guard isEnabled else { return }
        Task {
            await login()
            _ = await request(method: "POST", params: signed([
                "method": "track.scrobble", "artist": artist, "track": cleanQueryTitle(title),
                "album": album, "timestamp": String(Int(start.timeIntervalSince1970)),
            ], write: true))
        }
    }

    func setLoved(_ track: Track, loved: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        guard isEnabled else { completion(false); return }
        Task { @MainActor in
            await login()
            let ok = await request(method: "POST", params: signed([
                "method": loved ? "track.love" : "track.unlove",
                "artist": track.artist, "track": cleanQueryTitle(track.title),
            ], write: true)) != nil
            if ok { FmCache.shared.set(artist: track.artist, title: track.title,
                                       playcount: nil, loved: loved) }
            completion(ok)
        }
    }

    // playcount + loved state for one track
    func info(for track: Track) async -> (playcount: Int, loved: Bool)? {
        guard isEnabled else { return nil }
        if let c = FmCache.shared.get(artist: track.artist, title: track.title),
           let pc = c.playcount {
            return (pc, c.loved)
        }
        await login()
        lastAPIError = false
        guard let obj = await request(method: "GET", params: signed([
            "method": "track.getInfo", "artist": track.artist, "track": cleanQueryTitle(track.title),
            "username": Config.shared.lastfmUser,
        ], write: false)) else {
            // API said no such track (error 6) → remember, don't retry weekly;
            // a plain network failure is retried next pass
            print("fm getInfo fail: \(track.artist) / \(track.title) apiErr=\(lastAPIError)")
            if lastAPIError { FmCache.shared.markUnknown(artist: track.artist, title: track.title) }
            return nil
        }
        guard let info = obj.pathAny("track") as? [String: Any] else {
            FmCache.shared.markUnknown(artist: track.artist, title: track.title)
            return nil
        }
        let pc = Int(info["userplaycount"] as? String ?? "") ?? 0
        let loved = (info["userloved"] as? String) == "1"
        FmCache.shared.set(artist: track.artist, title: track.title,
                           playcount: pc, loved: loved)
        return (pc, loved)
    }

    private var lastAPIError = false

    // all loved tracks (paginated) -> local cache
    func importLoved() async -> Int {
        guard await login() else { return 0 }
        var pairs: [(String, String)] = []
        var page = 1
        while page <= 40 {   // 50 per page, 2000 cap
            guard let obj = await request(method: "GET", params: signed([
                "method": "user.getLovedTracks", "username": Config.shared.lastfmUser,
                "limit": "50", "page": String(page),
            ], write: false)),
            let tracks = obj.pathAny("lovedtracks", "track") as? [[String: Any]],
            !tracks.isEmpty else { break }
            for t in tracks {
                let a = t["artist"] as? [String: Any]
                if let artist = a?["name"] as? String, let title = t["name"] as? String {
                    pairs.append((artist, title))
                }
            }
            let total = Int(obj.pathAny("lovedtracks", "@attr", "total") as? String ?? "")
                ?? Int(obj.pathAny("lovedtracks", "@total") as? String ?? "") ?? 0
            if pairs.count >= total || tracks.count < 50 { break }
            page += 1
        }
        FmCache.shared.importLoved(pairs)
        print("fm loved import: \(pairs.count) tracks")
        return pairs.count
    }

    private func request(method: String, params: [String: String]) async -> [String: Any]? {
        guard var comps = URLComponents(string: base) else { return nil }
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if method == "POST" {
            // params already in URL for sig simplicity; Last.fm accepts query-signed POST
            req.httpBody = Data()
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              resp is HTTPURLResponse,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // Last.fm sends API errors (e.g. 6 "Track not found") with HTTP 404 —
        // still a valid answer, not a network failure
        if obj["error"] != nil {
            lastAPIError = true
            print("fm api error \(obj["error"] ?? "?"): \(obj["message"] ?? "") [\(params["method"] ?? "")]")
            return nil
        }
        return obj
    }
}

extension Dictionary {
    fileprivate func pathAny(_ keys: String...) -> Any? {
        var cur: Any? = self
        for k in keys {
            guard let d = cur as? [String: Any] else { return nil }
            cur = d[k]
        }
        return cur
    }
}
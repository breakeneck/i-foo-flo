// Config — imports the Python app's config.json on first run, then owns its
// own settings in UserDefaults.

import Foundation

@MainActor
final class Config {
    static let shared = Config()
    private let d = UserDefaults.standard
    private let pythonPath = ("~/dev/foobar-qt/config.json" as NSString).expandingTildeInPath

    private init() { bootstrap() }

    private func bootstrap() {
        guard d.object(forKey: "cfg.imported") == nil else { return }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: pythonPath)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for k in ["library_dirs", "volume", "lastfm_username", "lastfm_password",
                      "lyrics_genius_token", "rndOrder"] {
                if let v = obj[k] { d.set(v, forKey: "cfg.\(k)") }
            }
        }
        d.set(true, forKey: "cfg.imported")
    }

    var libraryDirs: [String] {
        get { d.stringArray(forKey: "cfg.library_dirs") ?? [] }
        set { d.set(newValue, forKey: "cfg.library_dirs") }
    }
    var volume: Float {
        get { d.object(forKey: "cfg.volume") as? Float ?? 1.0 }
        set { d.set(newValue, forKey: "cfg.volume") }
    }
    var lastfmUser: String {
        get { d.string(forKey: "cfg.lastfm_username") ?? "" }
        set { d.set(newValue, forKey: "cfg.lastfm_username") }
    }
    var lastfmPassword: String {
        get { d.string(forKey: "cfg.lastfm_password") ?? "" }
        set { d.set(newValue, forKey: "cfg.lastfm_password") }
    }
    var lastfmEnabled: Bool {
        get { d.object(forKey: "cfg.lastfm_enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "cfg.lastfm_enabled") }
    }
    var geniusToken: String {
        get { d.string(forKey: "cfg.lyrics_genius_token") ?? "" }
        set { d.set(newValue, forKey: "cfg.lyrics_genius_token") }
    }
    var lyricsEnabled: Bool {
        get { d.object(forKey: "cfg.lyrics_enabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "cfg.lyrics_enabled") }
    }
    var shuffle: Bool {
        get { d.bool(forKey: "cfg.rndOrder") }
        set { d.set(newValue, forKey: "cfg.rndOrder") }
    }
    /// "off" | "once" (stop after current, then clear) | "always" (stop after every track)
    var stopAfterMode: String {
        get { d.string(forKey: "cfg.stop_after_mode") ?? "off" }
        set { d.set(newValue, forKey: "cfg.stop_after_mode") }
    }
}

// MARK: - MD5 helper (Last.fm api_sig)

import CryptoKit

extension String {
    var md5hex: String {
        Insecure.MD5.hash(data: Data(utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
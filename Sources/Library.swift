// Library — local + SFTP scanning. Remote tracks get metadata from the
// folder layout (tagging remote files would stream them whole).

import Foundation

struct Track {
    var url: URL            // local file or http://127.0.0.1 proxy URL
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var remotePath: String? // sftp path when the source is the server
    var folder: String      // grouping header (album folder)
    var playcount: Int?     // last.fm scrobbles, filled lazily
    var loved: Bool?        // last.fm love state, filled lazily

    var isRemote: Bool { remotePath != nil }
}

enum AudioExt {
    static let allowed = ["mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "aiff", "aif", "caf"]
}

// sftp://server/home/server/hdd/media/Music -> ("server", "/home/...")
func parseSftp(_ s: String) -> (host: String, path: String)? {
    guard s.hasPrefix("sftp://") else { return nil }
    let rest = String(s.dropFirst("sftp://".count))
    guard let slash = rest.firstIndex(of: "/") else { return nil }
    return (String(rest[..<slash]), String(rest[slash...]))
}

@MainActor
final class Library {
    private(set) var tracks: [Track] = []
    var onUpdated: (() -> Void)?
    private var scanSeq = 0

    var dirs: [String] { Config.shared.libraryDirs }

    func updateStats(at i: Int, playcount: Int?, loved: Bool?) {
        guard tracks.indices.contains(i) else { return }
        tracks[i].playcount = playcount
        tracks[i].loved = loved
    }

    func scan() {
        scanSeq += 1
        let seq = scanSeq
        print("scan start, dirs: \(dirs)")
        tracks = []
        onUpdated?()
        Task {
            var result: [Track] = []
            for dir in dirs {
                if let r = parseSftp(dir) {
                    result.append(contentsOf: await scanRemote(host: r.host, root: r.path))
                } else {
                    result.append(contentsOf: await scanLocal(dir))
                }
                if seq == scanSeq { tracks = result; onUpdated?() }
            }
            guard seq == scanSeq else { return }
            tracks = result.sorted {
                let c = $0.folder.localizedCaseInsensitiveCompare($1.folder)
                if c != .orderedSame { return c == .orderedAscending }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            onUpdated?()
        }
    }

    // MARK: local

    private func scanLocal(_ dir: String) async -> [Track] {
        let base = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        var files: [URL] = []
        if let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) {
            for case let url as URL in en where AudioExt.allowed.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        var outTracks: [Track] = []
        for url in files {
            let asset = AVURLAsset(url: url)
            var title = url.deletingPathExtension().lastPathComponent
            var artist = "", album = "", dur: TimeInterval = 0
            if let meta = try? await asset.load(.commonMetadata) {
                for item in meta {
                    guard let key = item.commonKey else { continue }
                    switch key {
                    case .commonKeyTitle:     title = item.stringValue ?? title
                    case .commonKeyArtist:    artist = item.stringValue ?? artist
                    case .commonKeyAlbumName: album = item.stringValue ?? album
                    default: break
                    }
                }
            }
            if let d = try? await asset.load(.duration), d.isNumeric { dur = CMTimeGetSeconds(d) }
                        let folder = !album.isEmpty ? album
                            : url.deletingLastPathComponent().lastPathComponent
                        outTracks.append(Track(url: url, title: title, artist: artist, album: album,
                                               duration: dur, remotePath: nil, folder: folder,
                                               playcount: nil, loved: nil))
        }
        return outTracks
    }

    // MARK: remote (ssh)

    private func scanRemote(host: String, root: String) async -> [Track] {
        let names = AudioExt.allowed.map { "-iname '*.\($0)'" }.joined(separator: " -o ")
        let cmd = "find \(sqt(root)) -type f \\( \(names) \\) 2>/dev/null"
        guard let out = try? await Ssh.run(host: host, command: cmd) else {
            print("ssh find FAILED host=\(host)")
            return []
        }
        print("ssh find ok: \(out.split(separator: "\n").count) files")
        var outTracks: [Track] = []
        for line in out.split(separator: "\n") {
            let path = String(line)
            let comps = path.split(separator: "/").map(String.init)
            let file = comps.last ?? path
            let parent = comps.count >= 2 ? comps[comps.count - 2] : ""
            // server convention: "<Artist>,<Title>.mp3"; fallback "Artist - Title"
            let base = (file as NSString).deletingPathExtension
            var artist = "", title = base
            if let comma = base.firstIndex(of: ",") {
                artist = String(base[..<comma]).trimmingCharacters(in: .whitespaces)
                title = String(base[base.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            } else {
                let parts = base.components(separatedBy: " - ")
                if parts.count >= 2, parts[0].allSatisfy({ $0.isNumber }), parts[0].count <= 4 {
                    // numeric track prefix: "07 - Title" or "001 - Artist - Title"
                    if parts.count >= 3 {
                        artist = parts[1]
                        title = parts.dropFirst(2).joined(separator: " - ")
                    } else {
                        title = parts[1]
                    }
                } else if parts.count >= 2 {
                    artist = parts[0]
                    title = parts.dropFirst().joined(separator: " - ")
                }
                // drop trailing "(1991)" year from titles
                if let paren = title.range(of: #" \(\d{4}\)\s*$"#, options: .regularExpression) {
                    title.removeSubrange(paren)
                }
            }
            // generic container dirs ("Albums", "Disc 2") are not artists
            let generic = parent.range(of: #"^(albums?|disc\s*\d*|cd\s*\d*|bonus.*)$"#,
                                       options: [.regularExpression, .caseInsensitive]) != nil
            if artist.isEmpty && !generic { artist = parent }
            outTracks.append(Track(url: URL(string: "about:blank")!, title: title,
                                   artist: artist, album: "", duration: 0,
                                   remotePath: path, folder: parent,
                                   playcount: nil, loved: nil))
        }
        return outTracks
    }
}

func sqt(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

import AVFoundation
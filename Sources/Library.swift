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
    var lyrics: String?     // lyrics embedded in file tags (USLT/LYRICS)

    var isRemote: Bool { remotePath != nil }

    /// full path to the file — default sort key, shown in the Full Path column
    var fullPath: String {
        if let rp = remotePath { return rp }
        return url.path
    }

    /// directory containing the track — used by the folder tree
    var dirPath: String {
        if let rp = remotePath { return (rp as NSString).deletingLastPathComponent }
        return url.deletingLastPathComponent().path
    }
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

    func updateTags(at i: Int, artist: String, title: String, album: String, lyrics: String?) {
        tracks[i].artist = artist
        tracks[i].title = title
        tracks[i].album = album
        if let lyrics { tracks[i].lyrics = lyrics }
    }

    func hydrateStatsFromCache() {
        var map: [String: (Int, Bool)] = [:]
        for r in FmCache.shared.all() { map[r.artist + "\u{1}" + r.title] = (r.playcount, r.loved) }
        guard !map.isEmpty else { return }
        for i in tracks.indices {
            guard let s = map[tracks[i].artist + "\u{1}" + tracks[i].title] else { continue }
            if tracks[i].playcount == nil { tracks[i].playcount = s.0 }
            if tracks[i].loved == nil { tracks[i].loved = s.1 }
        }
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
                        let folder = !album.isEmpty ? cleanName(album)
                            : cleanName(url.deletingLastPathComponent().lastPathComponent)
                        outTracks.append(Track(url: url, title: title, artist: artist, album: album,
                                               duration: dur, remotePath: nil, folder: folder,
                                               playcount: nil, loved: nil, lyrics: nil))
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
        let tags = await fetchRemoteTags(host: host, root: root)
        print("ssh tags ok: \(tags.count) files tagged")
        var outTracks: [Track] = []
        for line in out.split(separator: "\n") {
            let path = String(line)
            // hierarchy relative to the library root decides artist/album:
            // root/<Artist>/<file>            → parent = artist
            // root/<Artist>/<Album>/<file>    → grandparent = artist, parent = album
            // root/<Collection>/<Artist>/<Album>/<file> works too
            let rel = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
            let segs = rel.split(separator: "/").map(String.init)
            let file = segs.last ?? path
            let parent = segs.count >= 2 ? segs[segs.count - 2] : ""
            let grandparent = segs.count >= 3 ? segs[segs.count - 3] : ""
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
            }
            title = cleanName(title)
            // path-derived fallbacks: grandparent wins as artist when it exists
            let generic = parent.range(of: #"^(albums?|disc\s*\d*|cd\s*\d*|bonus.*)$"#,
                                       options: [.regularExpression, .caseInsensitive]) != nil
            if artist.isEmpty {
                if !grandparent.isEmpty { artist = grandparent }
                else if !generic { artist = parent }
            }
            // parent dir is an album when there is a deeper artist level
            var album = ""
            if !grandparent.isEmpty && !generic { album = cleanName(parent) }
            // grouping header stays path-derived; tags only fill artist/title/album/duration
            let folder = !album.isEmpty ? album : cleanName(parent)
            // ID3 tags win over filename/path guessing
            var dur: TimeInterval = 0
            var embeddedLyrics: String?
            if let tg = tags[path] {
                if !tg.artist.isEmpty { artist = tg.artist }
                if !tg.title.isEmpty { title = tg.title }
                if !tg.album.isEmpty { album = tg.album }
                dur = tg.duration
                embeddedLyrics = tg.lyrics
            }
            outTracks.append(Track(url: URL(string: "about:blank")!, title: title,
                                   artist: artist, album: album, duration: dur,
                                   remotePath: path, folder: folder,
                                   playcount: nil, loved: nil, lyrics: embeddedLyrics))
        }
        for t in outTracks.prefix(3) {
            print("parsed: artist=[\(t.artist)] title=[\(t.title)] album=[\(t.album)] folder=[\(t.folder)]")
        }
        return outTracks
    }
}

// MARK: remote ID3 tags (read server-side in one ssh call)

struct RemoteTag {
    var artist = "", title = "", album = "", lyrics = ""
    var duration: TimeInterval = 0
}

private let tagScript = #"""
import os, sys, struct, json, subprocess

def synchsafe(b):
    return (b[0]<<21)|(b[1]<<14)|(b[2]<<7)|b[3]

def dec_text(body):
    if not body: return ""
    enc = body[0]
    try:
        if enc == 0: s = body[1:].decode("latin1")
        elif enc == 1: s = body[1:].decode("utf-16", errors="replace")
        elif enc == 2: s = body[1:].decode("utf-16-be", errors="replace")
        else: s = body[1:].decode("utf-8", errors="replace")
    except Exception:
        s = body[1:].decode("latin1", errors="replace")
    return s.strip("\x00").strip()

def uslt_text(body):
    # [enc][lang(3)][desc]\x00[text]  — some taggers store full LRC here
    if not body: return ""
    enc = body[0]
    rest = body[1:]
    try:
        rest2 = rest[3:]  # drop language code
        if enc in (1, 2):
            i = 0
            while i+1 < len(rest2):
                if rest2[i] == 0 and rest2[i+1] == 0: break
                i += 2
            txt = rest2[i+2:]
            return txt.decode("utf-16" if enc == 1 else "utf-16-be",
                              errors="replace").strip("\x00").strip()
        i = rest2.find(b"\x00")
        txt = rest2[i+1:] if i >= 0 else rest2
        return txt.decode("latin1" if enc == 0 else "utf-8",
                          errors="replace").strip("\x00").strip()
    except Exception:
        return dec_text(body)

def id3(path):
    with open(path, "rb") as fh:
        h = fh.read(10)
        if h[:3] != b"ID3": return None
        ver = h[3]; flags = h[5]
        size = synchsafe(h[6:10])
        data = fh.read(size)
    if ver >= 3 and (flags & 0x40):  # extended header
        eh = synchsafe(data[0:4]) if ver == 4 else struct.unpack(">I", data[0:4])[0]
        data = data[4+eh:]
    fidlen = 3 if ver == 2 else 4
    hdrlen = fidlen + (3 if ver == 2 else 6)
    out = {}
    p = 0
    while p + hdrlen <= len(data) and data[p] != 0:
        fid = data[p:p+fidlen].decode("latin1").rstrip("\x00")
        if ver >= 4: sz = synchsafe(data[p+4:p+8])
        elif ver == 3: sz = struct.unpack(">I", data[p+4:p+8])[0]
        else: sz = (data[p+3]<<16)|(data[p+4]<<8)|data[p+5]
        if sz == 0 or p+hdrlen+sz > len(data): break
        body = data[p+hdrlen:p+hdrlen+sz]
        if fid in ("TPE1","TP1") and "artist" not in out: out["artist"] = dec_text(body)
        elif fid in ("TIT2","TT2") and "title" not in out: out["title"] = dec_text(body)
        elif fid in ("TALB","TAL") and "album" not in out: out["album"] = dec_text(body)
        elif fid in ("TLEN","TLE") and "duration" not in out:
            try: out["duration"] = int(dec_text(body))//1000
            except Exception: pass
        elif fid in ("USLT","ULT") and "lyrics" not in out: out["lyrics"] = uslt_text(body)
        p += hdrlen + sz
    return out

def flac_tags(path):
    with open(path, "rb") as fh:
        if fh.read(4) != b"fLaC": return None
        out = {}
        while True:
            hb = fh.read(4)
            if len(hb) < 4: break
            btype = hb[0] & 0x7f; last = hb[0] & 0x80
            sz = int.from_bytes(hb[1:4], "little")
            block = fh.read(sz)
            if btype == 4:  # VORBIS_COMMENT
                p = 0
                p += int.from_bytes(block[p:p+4], "little") + 4  # vendor
                n = int.from_bytes(block[p:p+4], "little"); p += 4
                for _ in range(n):
                    l = int.from_bytes(block[p:p+4], "little"); p += 4
                    c = block[p:p+l]; p += l
                    try: s = c.decode("utf-8")
                    except Exception: continue
                    if "=" not in s: continue
                    k, v = s.split("=", 1)
                    k = k.upper()
                    if k == "ARTIST" and "artist" not in out: out["artist"] = v
                    elif k == "TITLE" and "title" not in out: out["title"] = v
                    elif k == "ALBUM" and "album" not in out: out["album"] = v
                    elif k == "LENGTH" and "duration" not in out:
                        try: out["duration"] = int(v)//1000
                        except Exception: pass
                    elif k in ("LYRICS","UNSYNCEDLYRICS") and "lyrics" not in out: out["lyrics"] = v
            if last: break
        return out

root = sys.argv[1]
r = subprocess.run(["find", root, "-type", "f", "(",
                    "-iname", "*.mp3", "-o", "-iname", "*.m4a", "-o", "-iname", "*.aac",
                    "-o", "-iname", "*.flac", "-o", "-iname", "*.wav", ")", "-print0"],
                   capture_output=True)
for f in r.stdout.split(b"\x00"):
    if not f: continue
    fp = f.decode("utf-8", "surrogateescape")
    t = None
    try:
        if fp.lower().endswith(".flac"):
            t = flac_tags(fp)
        if t is None:
            t = id3(fp)
    except Exception:
        t = None
    print(json.dumps({"p": fp, "t": t or {}}, ensure_ascii=False))
"""#

func fetchRemoteTags(host: String, root: String) async -> [String: RemoteTag] {
    let cmd = "python3 - \(sqt(root)) <<'FBS_PY'\n\(tagScript)\nFBS_PY"
    guard let out = try? await Ssh.run(host: host, command: cmd, timeout: 300) else {
        print("ssh tag fetch FAILED host=\(host)")
        return [:]
    }
    var map: [String: RemoteTag] = [:]
    for line in out.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = obj["p"] as? String,
              let t = obj["t"] as? [String: Any] else { continue }
        var tag = RemoteTag()
        tag.artist = (t["artist"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        tag.title = (t["title"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        tag.album = (t["album"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        tag.lyrics = (t["lyrics"] as? String) ?? ""
        tag.duration = TimeInterval(t["duration"] as? Int ?? 0)
        map[p] = tag
    }
    return map
}

/// strip "01 - " track prefixes and trailing "(2000)" years from display names
func cleanName(_ s: String) -> String {
    var t = s
    if let r = t.range(of: #"^\d{1,4}\s*-\s*"#, options: .regularExpression) { t.removeSubrange(r) }
    if let r = t.range(of: #"\s*\(\d{4}\)\s*$"#, options: .regularExpression) { t.removeSubrange(r) }
    return t.trimmingCharacters(in: .whitespaces)
}

func sqt(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

import AVFoundation
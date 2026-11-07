// Tag editor (F2 / context menu) — ID3v2.3 for MP3.
// Local files: written natively. Remote files: rewritten server-side via ssh+python3.

import AppKit

struct TagValues {
    var artist = "", title = "", album = "", year = ""
    var genre = "", trackNo = "", durationMs = "", lyrics = ""

    var json: String {
        let d: [String: String] = ["artist": artist, "title": title, "album": album,
                                   "year": year, "genre": genre, "track": trackNo,
                                   "duration": durationMs, "lyrics": lyrics]
        let j = try! JSONSerialization.data(withJSONObject: d)
        return String(decoding: j, as: UTF8.self)
    }
}

enum TagWriterError: LocalizedError {
    case notAudio(String), corrupted(String)
    var errorDescription: String? {
        switch self { case .notAudio(let m), .corrupted(let m): return m }
    }
}

enum TagWriter {
    // MARK: text encoding: UTF-16 with BOM (universal for ID3v2.3 readers)
    private static func u16(_ s: String) -> Data {
        var d = Data([0xFF, 0xFE])
        for unit in s.utf16 {
            d.append(UInt8(unit & 0xFF))
            d.append(UInt8(unit >> 8))
        }
        return d
    }

    private static func frame(_ id: String, _ text: String) -> Data {
        var f = Data(id.utf8)
        var body = Data([0x01]); body.append(u16(text))
        f.append(contentsOf: [UInt8(body.count >> 24 & 0xFF), UInt8(body.count >> 16 & 0xFF),
                              UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)])
        f.append(contentsOf: [0, 0])
        f.append(body)
        return f
    }

    private static func synchsafe(_ n: Int) -> Data {
        Data([UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
    }

    static func buildTag(_ v: TagValues) -> Data {
        var frames = Data()
        for (id, val) in [("TIT2", v.title), ("TPE1", v.artist), ("TALB", v.album),
                          ("TYER", v.year), ("TCON", v.genre), ("TRCK", v.trackNo),
                          ("TLEN", v.durationMs)] where !val.isEmpty {
            frames.append(frame(id, val))
        }
        if !v.lyrics.isEmpty {
            var body = Data("eng".utf8)
            body.append(u16(""))
            body.append(u16(v.lyrics))
            var f = Data("USLT".utf8)
            f.append(contentsOf: [UInt8(body.count >> 24 & 0xFF), UInt8(body.count >> 16 & 0xFF),
                                  UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)])
            f.append(contentsOf: [0, 0])
            f.append(body)
            frames.append(f)
        }
        var tag = Data("ID3".utf8); tag.append(contentsOf: [3, 0, 0])
        tag.append(synchsafe(frames.count))
        tag.append(frames)
        return tag
    }

    static func writeLocal(url: URL, values: TagValues) throws {
        if url.pathExtension.lowercased() == "flac" { try writeLocalFlac(url: url, values: values); return }
        let raw = try Data(contentsOf: url)
        var off = 0
        if raw.count > 10, raw.subdata(in: 0..<3) == Data("ID3".utf8) {
            let sz = (Int(raw[6]) << 21) | (Int(raw[7]) << 14) | (Int(raw[8]) << 7) | Int(raw[9])
            off = 10 + sz
        }
        var audio = raw.subdata(in: off..<raw.count)
        if audio.count > 128, audio.subdata(in: audio.count - 128..<audio.count - 125) == Data("TAG".utf8) {
            audio = audio.subdata(in: 0..<audio.count - 128)
        }
        let tmp = url.appendingPathExtension("amltmp")
        var out = buildTag(values)
        out.append(audio)
        try out.write(to: tmp)
        try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // FLAC: rewrite the VORBIS_COMMENT metadata block in place, keeping all
    // other blocks (STREAMINFO, PICTURE, PADDING...) byte-identical.
    static func writeLocalFlac(url: URL, values: TagValues) throws {
        let raw = try Data(contentsOf: url)
        guard raw.count > 4, raw.subdata(in: 0..<4) == Data("fLaC".utf8) else {
            throw TagWriterError.notAudio("не FLAC (немає магії fLaC)")
        }
        // collect metadata blocks: [isLast, type, payload]
        struct Block { var last: Bool; var type: UInt8; var payload: Data }
        var blocks: [Block] = []
        var off = 4
        while true {
            guard off + 4 <= raw.count else { throw TagWriterError.corrupted("обрізаний заголовок") }
            let hdr = raw[off]
            let last = hdr & 0x80 != 0
            let type = hdr & 0x7f
            let size = (Int(raw[off + 1]) << 16) | (Int(raw[off + 2]) << 8) | Int(raw[off + 3])
            guard off + 4 + size <= raw.count else { throw TagWriterError.corrupted("обрізаний блок") }
            blocks.append(Block(last: last, type: type,
                                payload: raw.subdata(in: off + 4 ..< off + 4 + size)))
            off += 4 + size
            if last { break }
        }
        // build new VORBIS_COMMENT payload
        var comments: [String] = []
        func add(_ key: String, _ v: String) {
            let s = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { comments.append("\(key)=\(s)") }
        }
        add("ARTIST", values.artist); add("TITLE", values.title); add("ALBUM", values.album)
        add("DATE", values.year); add("GENRE", values.genre); add("TRACKNUMBER", values.trackNo)
        add("LENGTH", values.durationMs); add("LYRICS", values.lyrics)
        var vc = Data()
        func le32(_ d: inout Data, _ n: Int) {
            d.append(contentsOf: [UInt8(n & 0xff), UInt8((n >> 8) & 0xff),
                                  UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff)])
        }
        let vendor = Data("foobar-swift".utf8)
        le32(&vc, vendor.count); vc.append(vendor)
        le32(&vc, comments.count)
        for c in comments { let cd = Data(c.utf8); le32(&vc, cd.count); vc.append(cd) }
        // rebuild file: drop old VORBIS_COMMENT (type 4), insert fresh one
        // right after STREAMINFO (must stay block 0)
        var out = Data("fLaC".utf8)
        var kept: [Block] = []
        for b in blocks where b.type != 4 { kept.append(b) }
        var newBlocks: [Block] = []
        for (i, b) in kept.enumerated() {
            newBlocks.append(b)
            if b.type == 0 { newBlocks.append(Block(last: false, type: 4, payload: vc)) }
        }
        if !newBlocks.contains(where: { $0.type == 4 }) {
            newBlocks.insert(Block(last: false, type: 4, payload: vc), at: 0)
        }
        for i in newBlocks.indices {
            let b = newBlocks[i]
            let isLast = i == newBlocks.count - 1
            out.append(UInt8(b.type | (isLast ? 0x80 : 0)))
            let s = b.payload.count
            out.append(UInt8((s >> 16) & 0xff)); out.append(UInt8((s >> 8) & 0xff)); out.append(UInt8(s & 0xff))
            out.append(b.payload)
        }
        out.append(raw.subdata(in: off..<raw.count))   // audio frames
        let tmp = url.appendingPathExtension("amltmp")
        try out.write(to: tmp)
        try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // server-side rewrite via ssh + python3 (same ID3v2.3 layout)
    static let pyScript = """
        import base64, json, os, struct, sys
        p = sys.argv[1]
        vals = json.loads(base64.b64decode(sys.argv[2]).decode())
        def u16(s):
            return b'\\xff\\xfe' + s.encode('utf-16-le')
        def frame(fid, text):
            data = b'\\x01' + u16(text)
            return fid.encode() + struct.pack('>I', len(data)) + b'\\x00\\x00' + data
        frames = b''
        for fid, key in [('TIT2','title'),('TPE1','artist'),('TALB','album'),
                         ('TYER','year'),('TCON','genre'),('TRCK','track'),('TLEN','duration')]:
            v = vals.get(key, '').strip()
            if v: frames += frame(fid, v)
        lyr = vals.get('lyrics', '')
        if lyr:
            data = b'eng' + u16('') + u16(lyr)
            frames += b'USLT' + struct.pack('>I', len(data)) + b'\\x00\\x00' + data
        n = len(frames)
        syn = bytes([(n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f])
        with open(p, 'rb') as f: raw = f.read()
        off = 0
        if raw[:3] == b'ID3':
            off = 10 + (raw[6] << 21 | raw[7] << 14 | raw[8] << 7 | raw[9])
        audio = raw[off:]
        if len(audio) > 128 and audio[-128:-125] == b'TAG': audio = audio[:-128]
        tmp = p + '.amltmp'
        with open(tmp, 'wb') as f: f.write(b'ID3\\x03\\x00\\x00' + syn + frames + audio)
        os.replace(tmp, p)
        print('ok')
        """

    // server-side FLAC rewrite via mutagen (installed on the host)
    static let pyFlacScript = """
        import base64, json, sys
        from mutagen.flac import FLAC
        p = sys.argv[1]
        vals = json.loads(base64.b64decode(sys.argv[2]).decode())
        audio = FLAC(p)
        if audio.tags is None:
            audio.add_tags()
        tags = audio.tags
        for key, field in [('ARTIST','artist'),('TITLE','title'),('ALBUM','album'),
                           ('DATE','year'),('GENRE','genre'),('TRACKNUMBER','trackNo'),
                           ('LENGTH','durationMs'),('LYRICS','lyrics')]:
            v = vals.get(field, '').strip()
            if v: tags[key] = [v]
            elif key in tags: del tags[key]
        audio.save()
        print('ok')
        """

    static func writeRemote(host: String, path: String, values: TagValues) async throws {
        let isFlac = path.lowercased().hasSuffix(".flac")
        let script = base64Encoded(Data(isFlac ? pyFlacScript.utf8 : pyScript.utf8))
        let vals = base64Encoded(Data(values.json.utf8))
        let q = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        _ = try await Ssh.run(host: host,
            command: "echo \(script) | base64 -d > /tmp/aml_tag.py && python3 /tmp/aml_tag.py \(q) \(vals)",
            timeout: 60)
    }

    private static func base64Encoded(_ d: Data) -> String { d.base64EncodedString() }
}

@MainActor
final class TagEditorWindow: NSObject, NSWindowDelegate {
    static let shared = TagEditorWindow()
    private var window: NSWindow?
    private var fields: [String: NSTextField] = [:]
    private var pathField: NSTextField?
    private var lyricsView: NSTextView?
    private var currentTrack: Track?

    func edit(track: Track) {
        if window == nil { build() }
        currentTrack = track
        let embedded = track.lyrics ?? ""
        let cached = LyricsCache.shared.get(artist: track.artist, title: track.title)
        set("artist", track.artist); set("title", track.title); set("album", track.album)
        set("year", ""); set("genre", ""); set("trackNo", "")
        set("durationMs", track.duration > 0 ? String(Int(track.duration * 1000)) : "")
        pathField?.stringValue = track.fullPath
        pathField?.toolTip = track.fullPath
        lyricsView?.string = embedded.isEmpty ? (cached?.synced ?? cached?.plain ?? "") : embedded
        window?.title = "Теги: \(track.artist) — \(track.title)"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func set(_ k: String, _ v: String) { fields[k]?.stringValue = v }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 550),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Редактор тегів"
        w.center()
        w.delegate = self
        let v = NSView()
        let rows: [(String, String)] = [("artist", "Артист"), ("title", "Назва"),
                                        ("album", "Альбом"), ("year", "Рік"),
                                        ("genre", "Жанр"), ("trackNo", "№ треку"),
                                        ("durationMs", "Тривалість, мс")]
        for (k, _) in rows {
            let f = NSTextField(string: "")
            f.placeholderString = k
            fields[k] = f
        }
        let g2 = NSGridView(views: [])
        g2.rowSpacing = 6
        g2.columnSpacing = 8
        for (k, label) in rows {
            let l = NSTextField(labelWithString: label); l.font = .systemFont(ofSize: 11)
            let f = fields[k]!
            g2.addRow(with: [l, f])
        }
        g2.column(at: 1).xPlacement = .fill
        g2.translatesAutoresizingMaskIntoConstraints = false
        // read-only full path row (selectable so it can be copied)
        let g1 = NSGridView(views: [])
        g1.rowSpacing = 6
        g1.columnSpacing = 8
        let pathLbl = NSTextField(labelWithString: "Повний шлях"); pathLbl.font = .systemFont(ofSize: 11)
        let pf = NSTextField(string: "")
        pf.isEditable = false
        pf.isSelectable = true
        pf.font = .systemFont(ofSize: 11)
        pf.lineBreakMode = .byTruncatingMiddle
        pathField = pf
        g1.addRow(with: [pathLbl, pf])
        g1.column(at: 1).xPlacement = .fill
        g1.translatesAutoresizingMaskIntoConstraints = false
        let lyrLabel = NSTextField(labelWithString: "Лірика (USLT)")
        lyrLabel.font = .systemFont(ofSize: 11)
        let tv = NSTextView()
        tv.font = .systemFont(ofSize: 12)
        tv.isRichText = false
        lyricsView = tv
        let lscroll = NSScrollView()
        lscroll.documentView = tv
        lscroll.hasVerticalScroller = true
        lscroll.translatesAutoresizingMaskIntoConstraints = false
        lscroll.heightAnchor.constraint(equalToConstant: 200).isActive = true
        let save = NSButton(title: "Зберегти теги", target: self, action: #selector(saveTapped))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        statusLabel = status
        let btnRow = NSStackView(views: [save, status])
        v.addSubview(g1); v.addSubview(g2); v.addSubview(lyrLabel); v.addSubview(lscroll); v.addSubview(btnRow)
        g1.translatesAutoresizingMaskIntoConstraints = false
        g2.translatesAutoresizingMaskIntoConstraints = false
        lyrLabel.translatesAutoresizingMaskIntoConstraints = false
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            g1.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            g1.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            g1.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            g2.topAnchor.constraint(equalTo: g1.bottomAnchor, constant: 12),
            g2.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            g2.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            lyrLabel.topAnchor.constraint(equalTo: g2.bottomAnchor, constant: 12),
            lyrLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            lscroll.topAnchor.constraint(equalTo: lyrLabel.bottomAnchor, constant: 4),
            lscroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            lscroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            btnRow.topAnchor.constraint(equalTo: lscroll.bottomAnchor, constant: 12),
            btnRow.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
        ])
        w.contentView = v
        window = w
    }

    private var statusLabel: NSTextField?

    @objc private func saveTapped() {
        guard let t = currentTrack else { return }
        var vals = TagValues()
        vals.artist = get("artist"); vals.title = get("title"); vals.album = get("album")
        vals.year = get("year"); vals.genre = get("genre"); vals.trackNo = get("trackNo")
        vals.durationMs = get("durationMs")
        vals.lyrics = lyricsView?.string ?? ""
        statusLabel?.stringValue = "запис…"
        let done: @MainActor (String?) -> Void = { [weak self] err in
            guard let self else { return }
            if let err {
                self.statusLabel?.stringValue = "✗ \(err)"
                return
            }
            // reflect in library + table
            guard let app = AppDelegate.shared else { return }
            let key = TagKeyHelper.key(t)
            for i in app.lib.tracks.indices where TagKeyHelper.key(app.lib.tracks[i]) == key {
                app.lib.updateTags(at: i, artist: vals.artist, title: vals.title,
                                   album: vals.album,
                                   lyrics: vals.lyrics.isEmpty ? nil : vals.lyrics)
            }
            app.applyFilter()
            self.statusLabel?.stringValue = "✓ збережено"
        }
        if t.isRemote, let rp = t.remotePath, let host = AppDelegate.shared?.remoteHost(for: rp) {
            Task {
                do { try await TagWriter.writeRemote(host: host, path: rp, values: vals); done(nil) }
                catch { done("\(error)") }
            }
        } else {
            DispatchQueue.global().async {
                do { try TagWriter.writeLocal(url: t.url, values: vals) } catch {
                    DispatchQueue.main.async { done("\(error)") }; return
                }
                DispatchQueue.main.async { done(nil) }
            }
        }
    }

    private func get(_ k: String) -> String { fields[k]?.stringValue ?? "" }
}

enum TagKeyHelper {
    static func key(_ t: Track) -> String { t.remotePath ?? t.url.path }
}
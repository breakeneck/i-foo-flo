// Local SQLite cache for lyrics (synced LRC and plain kept in SEPARATE columns,
// like USLT vs SYLT tags) so we don't hit the network on every play.
// Remote files live on the server — rewriting their tags would mean re-uploading
// whole tracks, so the cache DB is the storage for them; embedded tag lyrics
// (USLT/LYRICS) are read straight from the file and win over the cache.

import Foundation
import SQLite3

@MainActor
final class LyricsCache {
    static let shared = LyricsCache()

    private var db: OpaquePointer?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("FooBarSwift", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("lyrics.db").path
        let rc = sqlite3_open(path, &db)
        if rc != SQLITE_OK {
            print("lyrics cache: open FAILED rc=\(rc) path=\(path)")
            db = nil; return
        }
        let crc = sqlite3_exec(db, """
        CREATE TABLE IF NOT EXISTS lyrics(
            artist TEXT NOT NULL COLLATE NOCASE,
            title  TEXT NOT NULL COLLATE NOCASE,
            synced TEXT DEFAULT '',
            plain  TEXT DEFAULT '',
            source TEXT DEFAULT '',
            cached_at REAL DEFAULT 0,
            PRIMARY KEY(artist, title));
        """, nil, nil, nil)
        if crc != SQLITE_OK {
            print("lyrics cache: CREATE FAILED rc=\(crc) err=\(String(cString: sqlite3_errmsg(db)))")
        }
    }

    struct Entry { var synced: String; var plain: String; var source: String }

    func get(artist: String, title: String) -> Entry? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            SELECT synced, plain, source, cached_at FROM lyrics WHERE artist=? AND title=?
            """, -1, &stmt, nil) == SQLITE_OK else { return nil }
        let b = { (i: Int32, _ s: String) in
            sqlite3_bind_text(stmt, i, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        b(1, artist); b(2, title)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let age = Date().timeIntervalSince1970 - sqlite3_column_double(stmt, 3)
        guard age < 90 * 86400 else { return nil }   // revalidate quarterly
        let synced = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let plain = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let source = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        if synced.isEmpty && plain.isEmpty { return nil }
        return Entry(synced: synced, plain: plain, source: source)
    }

    func set(artist: String, title: String, synced: String, plain: String, source: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            INSERT INTO lyrics(artist,title,synced,plain,source,cached_at) VALUES(?,?,?,?,?,?)
            ON CONFLICT(artist,title) DO UPDATE SET
                synced=CASE WHEN excluded.synced!='' THEN excluded.synced ELSE lyrics.synced END,
                plain=CASE WHEN excluded.plain!='' THEN excluded.plain ELSE lyrics.plain END,
                source=excluded.source, cached_at=excluded.cached_at
            """, -1, &stmt, nil) == SQLITE_OK else { return }
        let b = { (i: Int32, _ s: String) in
            sqlite3_bind_text(stmt, i, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        b(1, artist); b(2, title); b(3, synced); b(4, plain); b(5, source)
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }
}
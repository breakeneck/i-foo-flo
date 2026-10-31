// Local SQLite cache for Last.fm stats (playcount, loved) so we don't
// re-pull the whole library on every launch. import SQLite3 ships in the SDK.

import Foundation
import SQLite3

@MainActor
final class FmCache {
    static let shared = FmCache()

    private var db: OpaquePointer?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("FooBarSwift", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("fmcache.db").path
        if sqlite3_open(path, &db) != SQLITE_OK { db = nil; return }
        exec("""
        CREATE TABLE IF NOT EXISTS track_stats(
            artist TEXT NOT NULL COLLATE NOCASE,
            title  TEXT NOT NULL COLLATE NOCASE,
            playcount INTEGER DEFAULT 0,
            loved     INTEGER DEFAULT 0,
            cached_at REAL DEFAULT 0,
            PRIMARY KEY(artist, title));
        """)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    struct Stats { var playcount: Int?; var loved: Bool }

    func get(artist: String, title: String) -> Stats? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT playcount, loved, cached_at FROM track_stats WHERE artist=? AND title=?",
                                 -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, artist, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let age = Date().timeIntervalSince1970 - sqlite3_column_double(stmt, 2)
        guard age < 7 * 86400 else { return nil }   // revalidate weekly
        // playcount NULL or -1 means "not looked up yet" (or not found on last.fm)
        var pc: Int? = nil
        if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            let v = Int(sqlite3_column_int(stmt, 0))
            if v >= 0 { pc = v }
        }
        return Stats(playcount: pc, loved: sqlite3_column_int(stmt, 1) == 1)
    }

    /// true when we still need a track.getInfo for this track
    func needsLookup(artist: String, title: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT playcount, cached_at FROM track_stats WHERE artist=? AND title=?",
                                 -1, &stmt, nil) == SQLITE_OK else { return true }
        sqlite3_bind_text(stmt, 1, artist, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return true }
        let age = Date().timeIntervalSince1970 - sqlite3_column_double(stmt, 1)
        if age >= 7 * 86400 { return true }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return true }
        return false   // -1 = looked up, not found → don't retry
    }

    /// remember "looked up, last.fm doesn't know this track"
    func markUnknown(artist: String, title: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
            INSERT INTO track_stats(artist,title,playcount,loved,cached_at) VALUES(?,?,-1,0,?)
            ON CONFLICT(artist,title) DO UPDATE SET playcount=-1, cached_at=?
            """, -1, &stmt, nil) == SQLITE_OK else { return }
        let b = { (i: Int32, _ s: String) in
            sqlite3_bind_text(stmt, i, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        b(1, artist); b(2, title)
        let now = Date().timeIntervalSince1970
        sqlite3_bind_double(stmt, 3, now)
        sqlite3_bind_double(stmt, 4, now)
        sqlite3_step(stmt)
    }

    func lovedCount() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM track_stats WHERE loved=1",
                                 -1, &stmt, nil) == SQLITE_OK else { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    func set(artist: String, title: String, playcount: Int?, loved: Bool?) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        INSERT INTO track_stats(artist,title,playcount,loved,cached_at) VALUES(?,?,?,?,?)
        ON CONFLICT(artist,title) DO UPDATE SET
            playcount=COALESCE(?,playcount), loved=COALESCE(?,loved), cached_at=?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        let now = Date().timeIntervalSince1970
        let b = { (i: Int32, _ s: String) in
            sqlite3_bind_text(stmt, i, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        b(1, artist); b(2, title)
        sqlite3_bind_int(stmt, 3, Int32(playcount ?? 0))
        sqlite3_bind_int(stmt, 4, Int32(loved == true ? 1 : 0))
        sqlite3_bind_double(stmt, 5, now)
        if let pc = playcount { sqlite3_bind_int(stmt, 6, Int32(pc)) } else { sqlite3_bind_null(stmt, 6) }
        if let l = loved { sqlite3_bind_int(stmt, 7, l ? 1 : 0) } else { sqlite3_bind_null(stmt, 7) }
        sqlite3_bind_double(stmt, 8, now)
        sqlite3_step(stmt)
    }

    func lovedSet() -> Set<String> {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT artist||char(31)||title FROM track_stats WHERE loved=1",
                                 -1, &stmt, nil) == SQLITE_OK else { return [] }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                out.insert(String(cString: c))
            }
        }
        return out
    }

    func importLoved(_ pairs: [(String, String)]) {
        exec("BEGIN")
        for (artist, title) in pairs { set(artist: artist, title: title, playcount: nil, loved: true) }
        exec("COMMIT")
    }
}
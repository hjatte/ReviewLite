import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: Error {
    case open(String)
    case prepare(String)
    case step(String)
    case migration(String)
}

final class Database {
    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "reviewlite.db", qos: .utility)

    private init() {}

    var dataDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ReviewLite", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    var framesDirectory: URL {
        let url = dataDirectory.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func open() throws {
        try queue.sync {
            let url = dataDirectory.appendingPathComponent("index.db")
            if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
                let msg = String(cString: sqlite3_errmsg(db))
                throw DatabaseError.open(msg)
            }
            try execLocked("PRAGMA journal_mode=WAL;")
            try execLocked("PRAGMA synchronous=NORMAL;")
            try migrateLocked()
        }
    }

    private func execLocked(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            throw DatabaseError.migration(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func migrateLocked() throws {
        // Drop legacy v0 schema if present (had segment_path/segment_offset columns).
        var legacy = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(frames);", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cName = sqlite3_column_text(stmt, 1) {
                    let name = String(cString: cName)
                    if name == "segment_path" { legacy = true }
                }
            }
            sqlite3_finalize(stmt)
        }
        if legacy {
            try execLocked("DROP TABLE frames;")
        }

        try execLocked("""
            CREATE TABLE IF NOT EXISTS frames (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                captured_at REAL NOT NULL,
                image_path TEXT NOT NULL,
                app_bundle_id TEXT,
                window_title TEXT,
                ocr_text TEXT,
                ocr_at REAL
            );
        """)
        try execLocked("CREATE INDEX IF NOT EXISTS idx_frames_captured_at ON frames(captured_at);")

        // Add ocr_text/ocr_at to existing frames tables that predate M2.
        try addColumnIfMissing(table: "frames", column: "ocr_text", definition: "TEXT")
        try addColumnIfMissing(table: "frames", column: "ocr_at", definition: "REAL")

        try execLocked("""
            CREATE VIRTUAL TABLE IF NOT EXISTS ocr_fts USING fts5(
                text,
                content='',
                tokenize='porter unicode61'
            );
        """)
        try execLocked("""
            CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
                text,
                content='',
                tokenize='porter unicode61'
            );
        """)
        // Backfill transcript_fts from existing transcript_segments on first-run after
        // the index was added (one-shot — no-op once the indexes match).
        try backfillTranscriptFTSLocked()

        try execLocked("""
            CREATE TABLE IF NOT EXISTS meetings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at REAL NOT NULL,
                ended_at REAL,
                audio_path TEXT NOT NULL,
                triggering_app TEXT,
                transcript_status TEXT NOT NULL DEFAULT 'pending',
                error_message TEXT
            );
        """)
        try execLocked("CREATE INDEX IF NOT EXISTS idx_meetings_started ON meetings(started_at);")

        try execLocked("""
            CREATE TABLE IF NOT EXISTS transcript_segments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                meeting_id INTEGER NOT NULL,
                start_sec REAL NOT NULL,
                end_sec REAL NOT NULL,
                text TEXT NOT NULL,
                FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
            );
        """)
        try execLocked("CREATE INDEX IF NOT EXISTS idx_segments_meeting ON transcript_segments(meeting_id, start_sec);")

        try addColumnIfMissing(table: "meetings", column: "minutes", definition: "TEXT")
        try addColumnIfMissing(table: "meetings", column: "minutes_generated_at", definition: "REAL")
        try addColumnIfMissing(table: "meetings", column: "minutes_provider", definition: "TEXT")

        // Sweep zombie meetings from any previous run that was killed mid-recording.
        // A meeting with status='pending' AND ended_at IS NULL never finished its lifecycle,
        // so its on-disk audio (if any) is incomplete — delete the row and the workdir.
        sweepZombieMeetingsLocked()
    }

    private func sweepZombieMeetingsLocked() {
        var stmt: OpaquePointer?
        let sql = "SELECT id, audio_path FROM meetings WHERE transcript_status = 'pending' AND ended_at IS NULL;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        var zombies: [(id: Int64, dir: URL)] = []
        let baseDir = self.meetingsDirectory
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let path = String(cString: sqlite3_column_text(stmt, 1))
            let workDir = baseDir.appendingPathComponent(URL(fileURLWithPath: path).deletingLastPathComponent().path, isDirectory: true)
            zombies.append((id, workDir))
        }
        sqlite3_finalize(stmt)
        for z in zombies {
            try? FileManager.default.removeItem(at: z.dir)
            var del: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM transcript_segments WHERE meeting_id = ?;", -1, &del, nil) == SQLITE_OK {
                sqlite3_bind_int64(del, 1, z.id); sqlite3_step(del); sqlite3_finalize(del)
            }
            var del2: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM meetings WHERE id = ?;", -1, &del2, nil) == SQLITE_OK {
                sqlite3_bind_int64(del2, 1, z.id); sqlite3_step(del2); sqlite3_finalize(del2)
            }
        }
        if !zombies.isEmpty {
            Log.storage.info("Cleaned up \(zombies.count) zombie meeting(s) from previous run")
        }
    }

    var meetingsDirectory: URL {
        let url = dataDirectory.appendingPathComponent("meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func backfillTranscriptFTSLocked() throws {
        var stmt: OpaquePointer?
        var ftsCount: Int64 = 0
        var segCount: Int64 = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM transcript_fts;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { ftsCount = sqlite3_column_int64(stmt, 0) }
            sqlite3_finalize(stmt)
        }
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM transcript_segments;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW { segCount = sqlite3_column_int64(stmt, 0) }
            sqlite3_finalize(stmt)
        }
        guard segCount > 0, ftsCount < segCount else { return }
        try execLocked("INSERT INTO transcript_fts(rowid, text) SELECT id, text FROM transcript_segments WHERE id NOT IN (SELECT rowid FROM transcript_fts);")
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        var stmt: OpaquePointer?
        var exists = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cName = sqlite3_column_text(stmt, 1) {
                    if String(cString: cName) == column { exists = true; break }
                }
            }
            sqlite3_finalize(stmt)
        }
        if !exists {
            try execLocked("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
        }
    }

    @discardableResult
    func insertFrame(capturedAt: Date, imagePath: String, appBundleID: String?, windowTitle: String?) throws -> Int64 {
        try queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO frames (captured_at, image_path, app_bundle_id, window_title) VALUES (?, ?, ?, ?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepare(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, capturedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, imagePath, -1, SQLITE_TRANSIENT)
            if let b = appBundleID {
                sqlite3_bind_text(stmt, 3, b, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if let t = windowTitle {
                sqlite3_bind_text(stmt, 4, t, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.step(String(cString: sqlite3_errmsg(db)))
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func frame(at instant: Date) -> FrameRecord? {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
                SELECT id, captured_at, image_path, app_bundle_id, window_title
                FROM frames
                WHERE captured_at <= ?
                ORDER BY captured_at DESC
                LIMIT 1;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, instant.timeIntervalSince1970)
            return readFirstFrame(stmt: stmt)
        }
    }

    func earliestFrameDate() -> Date? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT MIN(captured_at) FROM frames;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    func latestFrameDate() -> Date? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT MAX(captured_at) FROM frames;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    func setOCR(frameID: Int64, text: String) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            let sql = "UPDATE frames SET ocr_text = ?, ocr_at = ? WHERE id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepare(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_text(stmt, 1, text, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 3, frameID)
            let rc = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            guard rc == SQLITE_DONE else { throw DatabaseError.step(String(cString: sqlite3_errmsg(db))) }

            // Mirror into FTS5
            var ftsDel: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM ocr_fts WHERE rowid = ?;", -1, &ftsDel, nil) == SQLITE_OK {
                sqlite3_bind_int64(ftsDel, 1, frameID)
                sqlite3_step(ftsDel)
                sqlite3_finalize(ftsDel)
            }
            var ftsIns: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT INTO ocr_fts(rowid, text) VALUES (?, ?);", -1, &ftsIns, nil) == SQLITE_OK {
                sqlite3_bind_int64(ftsIns, 1, frameID)
                sqlite3_bind_text(ftsIns, 2, text, -1, SQLITE_TRANSIENT)
                sqlite3_step(ftsIns)
                sqlite3_finalize(ftsIns)
            }
        }
    }

    enum SearchHitKind: String, Hashable {
        case frame
        case transcript
    }

    struct SearchHit: Identifiable, Hashable {
        var id: String              // composite key so frame and transcript IDs don't collide
        var kind: SearchHitKind
        var capturedAt: Date
        var imagePath: String?      // nil for transcript hits
        var appBundleID: String?
        var windowTitle: String?
        var snippet: String
        var meetingID: Int64?       // populated for transcript hits
    }

    /// Unified search across captured-frame OCR text AND meeting-transcript text. A transcript
    /// hit's `capturedAt` is the wall-clock moment the matched line was spoken
    /// (`meeting.started_at + segment.start_sec`), so clicking it can jump the timeline cursor
    /// straight to that moment and resume the meeting audio.
    func searchAll(query rawQuery: String, limit: Int = 100) -> [SearchHit] {
        let q = sanitizeFTSQuery(rawQuery)
        guard !q.isEmpty else { return [] }
        var hits: [SearchHit] = []

        queue.sync {
            // 1. Frame OCR matches.
            var stmt: OpaquePointer?
            let sqlFrames = """
                SELECT f.id, f.captured_at, f.image_path, f.app_bundle_id, f.window_title,
                       snippet(ocr_fts, 0, '«', '»', '…', 12)
                FROM ocr_fts
                JOIN frames f ON f.id = ocr_fts.rowid
                WHERE ocr_fts MATCH ?
                ORDER BY f.captured_at DESC
                LIMIT ?;
            """
            if sqlite3_prepare_v2(db, sqlFrames, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, q, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(limit))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_int64(stmt, 0)
                    let ts = sqlite3_column_double(stmt, 1)
                    let path = String(cString: sqlite3_column_text(stmt, 2))
                    let bundle = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                    let title = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                    let snippet = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                    hits.append(SearchHit(
                        id: "f-\(id)",
                        kind: .frame,
                        capturedAt: Date(timeIntervalSince1970: ts),
                        imagePath: path,
                        appBundleID: bundle,
                        windowTitle: title,
                        snippet: snippet,
                        meetingID: nil
                    ))
                }
                sqlite3_finalize(stmt)
            }

            // 2. Meeting transcript matches.
            var tstmt: OpaquePointer?
            let sqlTrans = """
                SELECT ts.id, m.id, m.started_at + ts.start_sec AS abs_time, m.triggering_app,
                       snippet(transcript_fts, 0, '«', '»', '…', 12)
                FROM transcript_fts
                JOIN transcript_segments ts ON ts.id = transcript_fts.rowid
                JOIN meetings m ON m.id = ts.meeting_id
                WHERE transcript_fts MATCH ?
                ORDER BY abs_time DESC
                LIMIT ?;
            """
            if sqlite3_prepare_v2(db, sqlTrans, -1, &tstmt, nil) == SQLITE_OK {
                sqlite3_bind_text(tstmt, 1, q, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(tstmt, 2, Int32(limit))
                while sqlite3_step(tstmt) == SQLITE_ROW {
                    let segID = sqlite3_column_int64(tstmt, 0)
                    let meetingID = sqlite3_column_int64(tstmt, 1)
                    let absTime = sqlite3_column_double(tstmt, 2)
                    let app = sqlite3_column_text(tstmt, 3).map { String(cString: $0) }
                    let snippet = sqlite3_column_text(tstmt, 4).map { String(cString: $0) } ?? ""
                    hits.append(SearchHit(
                        id: "t-\(segID)",
                        kind: .transcript,
                        capturedAt: Date(timeIntervalSince1970: absTime),
                        imagePath: nil,
                        appBundleID: app,
                        windowTitle: nil,
                        snippet: snippet,
                        meetingID: meetingID
                    ))
                }
                sqlite3_finalize(tstmt)
            }
        }

        // Interleave by recency so users see the most-recent matches across both sources first.
        hits.sort { $0.capturedAt > $1.capturedAt }
        if hits.count > limit { hits = Array(hits.prefix(limit)) }
        return hits
    }

    @available(*, deprecated, message: "Use searchAll. Kept temporarily for callers we haven't updated yet.")
    func searchOCR(query rawQuery: String, limit: Int = 100) -> [SearchHit] {
        return searchAll(query: rawQuery, limit: limit)
    }

    /// Wraps each whitespace-separated token in double quotes and escapes embedded quotes,
    /// so user input is treated as literal phrases rather than FTS5 syntax.
    private func sanitizeFTSQuery(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace })
        let quoted = tokens.map { token -> String in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return quoted.joined(separator: " ")
    }

    // MARK: - Meetings

    @discardableResult
    func insertMeeting(startedAt: Date, audioPath: String, triggeringApp: String?) throws -> Int64 {
        try queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO meetings (started_at, audio_path, triggering_app) VALUES (?, ?, ?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepare(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, startedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, audioPath, -1, SQLITE_TRANSIENT)
            if let a = triggeringApp {
                sqlite3_bind_text(stmt, 3, a, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.step(String(cString: sqlite3_errmsg(db)))
            }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func finishMeeting(id: Int64, endedAt: Date, audioPath: String) throws {
        try queue.sync {
            var stmt: OpaquePointer?
            let sql = "UPDATE meetings SET ended_at = ?, audio_path = ? WHERE id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepare(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, endedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, audioPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.step(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func setTranscriptStatus(meetingID: Int64, status: String, error: String? = nil) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "UPDATE meetings SET transcript_status = ?, error_message = ? WHERE id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT)
            if let e = error {
                sqlite3_bind_text(stmt, 2, e, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_int64(stmt, 3, meetingID)
            sqlite3_step(stmt)
        }
    }

    func deleteMeeting(id: Int64) {
        queue.sync {
            var s1: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM transcript_segments WHERE meeting_id = ?;", -1, &s1, nil) == SQLITE_OK {
                sqlite3_bind_int64(s1, 1, id); sqlite3_step(s1); sqlite3_finalize(s1)
            }
            var s2: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM meetings WHERE id = ?;", -1, &s2, nil) == SQLITE_OK {
                sqlite3_bind_int64(s2, 1, id); sqlite3_step(s2); sqlite3_finalize(s2)
            }
        }
    }

    func appendTranscriptSegments(meetingID: Int64, segments: [(start: Double, end: Double, text: String)]) {
        queue.sync {
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            for s in segments {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "INSERT INTO transcript_segments (meeting_id, start_sec, end_sec, text) VALUES (?, ?, ?, ?);", -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(stmt, 1, meetingID)
                    sqlite3_bind_double(stmt, 2, s.start)
                    sqlite3_bind_double(stmt, 3, s.end)
                    sqlite3_bind_text(stmt, 4, s.text, -1, SQLITE_TRANSIENT)
                    if sqlite3_step(stmt) == SQLITE_DONE {
                        let rowID = sqlite3_last_insert_rowid(db)
                        // Mirror into the transcript FTS index so unified search can find it.
                        var ftsStmt: OpaquePointer?
                        if sqlite3_prepare_v2(db, "INSERT INTO transcript_fts(rowid, text) VALUES (?, ?);", -1, &ftsStmt, nil) == SQLITE_OK {
                            sqlite3_bind_int64(ftsStmt, 1, rowID)
                            sqlite3_bind_text(ftsStmt, 2, s.text, -1, SQLITE_TRANSIENT)
                            sqlite3_step(ftsStmt)
                            sqlite3_finalize(ftsStmt)
                        }
                    }
                    sqlite3_finalize(stmt)
                }
            }
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }
    }

    // MARK: - Retention

    /// Deletes frames and meetings whose start time is older than `cutoff`, plus their on-disk files.
    /// Returns the number of frames + meetings removed.
    @discardableResult
    func purgeOlderThan(_ cutoff: Date) -> (framesRemoved: Int, meetingsRemoved: Int) {
        queue.sync {
            let cutoffTs = cutoff.timeIntervalSince1970

            var oldFramePaths: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT image_path FROM frames WHERE captured_at < ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoffTs)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    oldFramePaths.append(String(cString: sqlite3_column_text(stmt, 0)))
                }
                sqlite3_finalize(stmt)
            }

            var oldMeetingDirs: [String] = []
            var oldMeetingIDs: [Int64] = []
            var mstmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id, audio_path FROM meetings WHERE started_at < ?;", -1, &mstmt, nil) == SQLITE_OK {
                sqlite3_bind_double(mstmt, 1, cutoffTs)
                while sqlite3_step(mstmt) == SQLITE_ROW {
                    let id = sqlite3_column_int64(mstmt, 0)
                    let audio = String(cString: sqlite3_column_text(mstmt, 1))
                    oldMeetingIDs.append(id)
                    oldMeetingDirs.append(URL(fileURLWithPath: audio).deletingLastPathComponent().path)
                }
                sqlite3_finalize(mstmt)
            }

            // Delete DB rows in a single transaction.
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            var del: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM ocr_fts WHERE rowid IN (SELECT id FROM frames WHERE captured_at < ?);", -1, &del, nil) == SQLITE_OK {
                sqlite3_bind_double(del, 1, cutoffTs); sqlite3_step(del); sqlite3_finalize(del)
            }
            var d2: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM frames WHERE captured_at < ?;", -1, &d2, nil) == SQLITE_OK {
                sqlite3_bind_double(d2, 1, cutoffTs); sqlite3_step(d2); sqlite3_finalize(d2)
            }
            var d3: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM transcript_segments WHERE meeting_id IN (SELECT id FROM meetings WHERE started_at < ?);", -1, &d3, nil) == SQLITE_OK {
                sqlite3_bind_double(d3, 1, cutoffTs); sqlite3_step(d3); sqlite3_finalize(d3)
            }
            var d4: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM meetings WHERE started_at < ?;", -1, &d4, nil) == SQLITE_OK {
                sqlite3_bind_double(d4, 1, cutoffTs); sqlite3_step(d4); sqlite3_finalize(d4)
            }
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)

            // Delete on-disk files.
            for relPath in oldFramePaths {
                let url = framesDirectory.appendingPathComponent(relPath)
                try? FileManager.default.removeItem(at: url)
            }
            for dir in Set(oldMeetingDirs) {
                let url = meetingsDirectory.appendingPathComponent(dir)
                try? FileManager.default.removeItem(at: url)
            }

            // Sweep up empty per-day folders in frames/.
            if let dayFolders = try? FileManager.default.contentsOfDirectory(at: framesDirectory, includingPropertiesForKeys: nil) {
                for folder in dayFolders {
                    if let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil), contents.isEmpty {
                        try? FileManager.default.removeItem(at: folder)
                    }
                }
            }

            return (oldFramePaths.count, oldMeetingIDs.count)
        }
    }

    /// Deletes any frames whose `app_bundle_id` is in the supplied set, plus the on-disk
    /// HEIC files. Returns the number of rows removed.
    @discardableResult
    func purgeFrames(matchingBundleIDs bundles: Set<String>) -> Int {
        guard !bundles.isEmpty else { return 0 }
        return queue.sync {
            let placeholders = bundles.map { _ in "?" }.joined(separator: ",")
            var paths: [String] = []
            var ids: [Int64] = []

            var sel: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id, image_path FROM frames WHERE app_bundle_id IN (\(placeholders));", -1, &sel, nil) == SQLITE_OK {
                for (idx, b) in bundles.enumerated() {
                    sqlite3_bind_text(sel, Int32(idx + 1), b, -1, SQLITE_TRANSIENT)
                }
                while sqlite3_step(sel) == SQLITE_ROW {
                    ids.append(sqlite3_column_int64(sel, 0))
                    paths.append(String(cString: sqlite3_column_text(sel, 1)))
                }
                sqlite3_finalize(sel)
            }

            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            var ftsDel: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM ocr_fts WHERE rowid IN (SELECT id FROM frames WHERE app_bundle_id IN (\(placeholders)));", -1, &ftsDel, nil) == SQLITE_OK {
                for (idx, b) in bundles.enumerated() {
                    sqlite3_bind_text(ftsDel, Int32(idx + 1), b, -1, SQLITE_TRANSIENT)
                }
                sqlite3_step(ftsDel)
                sqlite3_finalize(ftsDel)
            }
            var rowDel: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM frames WHERE app_bundle_id IN (\(placeholders));", -1, &rowDel, nil) == SQLITE_OK {
                for (idx, b) in bundles.enumerated() {
                    sqlite3_bind_text(rowDel, Int32(idx + 1), b, -1, SQLITE_TRANSIENT)
                }
                sqlite3_step(rowDel)
                sqlite3_finalize(rowDel)
            }
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)

            for relPath in paths {
                let url = framesDirectory.appendingPathComponent(relPath)
                try? FileManager.default.removeItem(at: url)
            }

            return ids.count
        }
    }

    /// Walks the on-disk frames and meetings directories and deletes anything not referenced by
    /// the current DB rows. Catches stragglers from interrupted runs or schema bugs so disk
    /// usage doesn't drift away from what the user sees in the app.
    @discardableResult
    func purgeOrphanFiles() -> (frames: Int, meetingDirs: Int) {
        queue.sync {
            let fm = FileManager.default

            // Frames: collect every image_path from DB into a set.
            var validFramePaths = Set<String>()
            var fstmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT image_path FROM frames;", -1, &fstmt, nil) == SQLITE_OK {
                while sqlite3_step(fstmt) == SQLITE_ROW {
                    validFramePaths.insert(String(cString: sqlite3_column_text(fstmt, 0)))
                }
                sqlite3_finalize(fstmt)
            }
            var orphanFrames = 0
            if let dayDirs = try? fm.contentsOfDirectory(at: framesDirectory, includingPropertiesForKeys: nil) {
                for dayDir in dayDirs {
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: dayDir.path, isDirectory: &isDir)
                    if !isDir.boolValue { continue }
                    if let files = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil) {
                        for file in files {
                            let rel = "\(dayDir.lastPathComponent)/\(file.lastPathComponent)"
                            if !validFramePaths.contains(rel) {
                                try? fm.removeItem(at: file)
                                orphanFrames += 1
                            }
                        }
                        if let remaining = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil),
                           remaining.isEmpty {
                            try? fm.removeItem(at: dayDir)
                        }
                    }
                }
            }

            // Meetings: each meeting lives in `<uuid>/...` so collect each unique workdir.
            var validMeetingDirs = Set<String>()
            var mstmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT audio_path FROM meetings;", -1, &mstmt, nil) == SQLITE_OK {
                while sqlite3_step(mstmt) == SQLITE_ROW {
                    let path = String(cString: sqlite3_column_text(mstmt, 0))
                    let dirName = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                    if !dirName.isEmpty {
                        validMeetingDirs.insert(dirName)
                    }
                }
                sqlite3_finalize(mstmt)
            }
            var orphanMeetings = 0
            if let dirs = try? fm.contentsOfDirectory(at: meetingsDirectory, includingPropertiesForKeys: nil) {
                for dir in dirs {
                    if !validMeetingDirs.contains(dir.lastPathComponent) {
                        try? fm.removeItem(at: dir)
                        orphanMeetings += 1
                    }
                }
            }

            return (orphanFrames, orphanMeetings)
        }
    }

    func meetings() -> [MeetingRecord] {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
                SELECT id, started_at, ended_at, audio_path, triggering_app, transcript_status, error_message, minutes, minutes_generated_at, minutes_provider
                FROM meetings ORDER BY started_at DESC;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [MeetingRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                let ended: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                let audio = String(cString: sqlite3_column_text(stmt, 3))
                let app = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let status = String(cString: sqlite3_column_text(stmt, 5))
                let err = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                out.append(MeetingRecord(id: id, startedAt: started, endedAt: ended, audioPath: audio, triggeringApp: app, transcriptStatus: status, errorMessage: err))
            }
            return out
        }
    }

    /// Returns the meeting covering the given instant, if any.
    /// "Covering" = startedAt <= instant <= endedAt (or endedAt is null and the meeting is still in progress).
    func meeting(coveringInstant: Date) -> MeetingRecord? {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
                SELECT id, started_at, ended_at, audio_path, triggering_app, transcript_status, error_message, minutes, minutes_generated_at, minutes_provider
                FROM meetings
                WHERE started_at <= ?
                  AND (ended_at IS NULL OR ended_at >= ?)
                ORDER BY started_at DESC
                LIMIT 1;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, coveringInstant.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, coveringInstant.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readMeeting(stmt: stmt)
        }
    }

    private func readMeeting(stmt: OpaquePointer?) -> MeetingRecord {
        let id = sqlite3_column_int64(stmt, 0)
        let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let ended: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let audio = String(cString: sqlite3_column_text(stmt, 3))
        let app = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        let status = String(cString: sqlite3_column_text(stmt, 5))
        let err = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let minutes = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let mgenAt: Date? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        let provider = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
        return MeetingRecord(
            id: id, startedAt: started, endedAt: ended, audioPath: audio,
            triggeringApp: app, transcriptStatus: status, errorMessage: err,
            minutes: minutes, minutesGeneratedAt: mgenAt, minutesProvider: provider
        )
    }

    func setMinutes(meetingID: Int64, minutes: String, provider: String) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "UPDATE meetings SET minutes = ?, minutes_generated_at = ?, minutes_provider = ? WHERE id = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, minutes, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, provider, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, meetingID)
            sqlite3_step(stmt)
        }
    }

    func transcriptSegments(meetingID: Int64) -> [TranscriptSegmentRecord] {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT id, start_sec, end_sec, text FROM transcript_segments WHERE meeting_id = ? ORDER BY start_sec;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, meetingID)
            var out: [TranscriptSegmentRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let s = sqlite3_column_double(stmt, 1)
                let e = sqlite3_column_double(stmt, 2)
                let t = String(cString: sqlite3_column_text(stmt, 3))
                out.append(TranscriptSegmentRecord(id: id, start: s, end: e, text: t))
            }
            return out
        }
    }

    // MARK: - Per-day queries

    func frameRange(inDay dayStart: Date) -> (start: Date, end: Date)? {
        queue.sync {
            var stmt: OpaquePointer?
            let s = dayStart.timeIntervalSince1970
            let e = s + 86400
            guard sqlite3_prepare_v2(db, "SELECT MIN(captured_at), MAX(captured_at) FROM frames WHERE captured_at >= ? AND captured_at < ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, s)
            sqlite3_bind_double(stmt, 2, e)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return nil }
            return (Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)))
        }
    }

    func frameCount(inDay dayStart: Date) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            let s = dayStart.timeIntervalSince1970
            let e = s + 86400
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM frames WHERE captured_at >= ? AND captured_at < ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, s)
            sqlite3_bind_double(stmt, 2, e)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Meetings that overlap the given day (open-ended meetings are treated as extending to now).
    func meetings(inDay dayStart: Date) -> [MeetingRecord] {
        queue.sync {
            var stmt: OpaquePointer?
            let s = dayStart.timeIntervalSince1970
            let e = s + 86400
            let nowTs = Date().timeIntervalSince1970
            let sql = """
                SELECT id, started_at, ended_at, audio_path, triggering_app, transcript_status, error_message, minutes, minutes_generated_at, minutes_provider
                FROM meetings
                WHERE started_at < ?
                  AND COALESCE(ended_at, ?) >= ?
                ORDER BY started_at;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, e)
            sqlite3_bind_double(stmt, 2, nowTs)
            sqlite3_bind_double(stmt, 3, s)
            var out: [MeetingRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(readMeeting(stmt: stmt))
            }
            return out
        }
    }

    func frameCount() -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM frames;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func readFirstFrame(stmt: OpaquePointer?) -> FrameRecord? {
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let id = sqlite3_column_int64(stmt, 0)
        let ts = sqlite3_column_double(stmt, 1)
        let path = String(cString: sqlite3_column_text(stmt, 2))
        let bundle = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
        let title = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
        return FrameRecord(
            id: id,
            capturedAt: Date(timeIntervalSince1970: ts),
            imagePath: path,
            appBundleID: bundle,
            windowTitle: title
        )
    }
}

import Foundation
import SQLite3

// SQLite FTS5 full-text index over agent session transcripts. Driven off the
// same discovery the table uses (SessionIndexer.entries) and the same streaming
// extractor (SessionIndexer.indexableMessages), so it indexes exactly the
// conversation text — typed prompts + assistant replies — never loading a whole
// multi-MB transcript into memory. Folds only the appended tail of a growing
// file via a per-session byte cursor (mirrors the token indexer's model).
//
// Two connections so search stays instant during the one-time cold build:
//  • writeDB on the scan queue folds transcript bytes,
//  • readDB on queryQueue answers MATCH against the WAL snapshot concurrently.
// Session metadata (title / folder / time) is NOT stored here — the UI joins it
// from the live SessionIndexer.entries by session id, so it's always fresh.

// One matching message — the unit of a search result. FTS5 returns a message
// row once however many times the term occurs inside it, so multiple hits within
// a single message collapse to one result.
struct MessageHit: Sendable {
    let sessionId: String
    let provider: SessionProvider
    let role: String           // "user" / "assistant"
    let timestamp: Date?
    // Excerpt with matched terms wrapped in SearchIndex.hlStart … hlEnd
    // sentinels, which the UI turns into highlighted ranges.
    let marked: String
    // Leading slice of the raw message text — lets the Messages screen find and
    // scroll to this exact message (matched against the transcript events).
    let locator: String
}

final class SearchIndex {
    // Sentinels FTS5 snippet() wraps around matched terms: control chars (STX /
    // ETX) that never occur in transcript prose. Mirrored by the UI highlighter.
    static let hlStart = "\u{02}"
    static let hlEnd   = "\u{03}"

    // Result messages returned are capped so a broad query can't build
    // thousands of result views.
    private static let maxResults = 200
    private static let schemaVersion = 1

    private static let dbURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appending(path: "EpiScope", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "search.sqlite")
    }()

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // The FTS backfill shares the scan queue — see WorkScheduler.scanQueue.
    private let queryQueue = DispatchQueue(label: "episcope.search.query", qos: .userInitiated)

    private var writeDB: OpaquePointer?   // scan queue only
    private var readDB: OpaquePointer?    // queryQueue only

    // sessionId -> (observed file size, parse cursor, next seq). scan queue only.
    private var cursors: [String: (size: Int64, offset: Int64, seq: Int64)] = [:]
    // sessionId -> resolved transcript URL (Codex/Desktop need a tree walk to
    // locate — cache it so reconcile doesn't re-scan every tick). scan queue only.
    private var urlCache: [String: URL] = [:]
    // Coalescing: while a (possibly long) pass runs, newer reconciles just stash
    // the latest snapshot here; the running pass picks it up when it finishes.
    private var latestWork: [WorkItem]?
    private var scheduled = false

    private struct WorkItem {
        let id: String
        let provider: SessionProvider
        let cwd: String
        let size: Int64
        let transcriptPath: String?
        let external: Bool
    }

    // Progress for the UI. Called on main; set before open(). done==total==0 idle.
    var onProgress: ((_ done: Int, _ total: Int) -> Void)?
    private var indexedFiles = 0
    private var totalFiles = 0

    // MARK: - Lifecycle

    func open() {
        // Ordered, not parallel: only openWrite carries SQLITE_OPEN_CREATE, so
        // on a fresh install openRead used to lose the race against the file
        // existing at all. It has no retry, so readDB stayed nil for the life
        // of the process and deep search returned nothing, silently — and the
        // next launch found the file and worked, which is why it never
        // reproduced for anyone who restarted the app.
        WorkScheduler.shared.run(.init(id: "search-open", deferrable: false)) { [weak self] in
            guard let self else { return }
            self.openWrite()
            self.queryQueue.async { [weak self] in self?.openRead() }
        }
    }

    private func openWrite() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(Self.dbURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else { return }
        writeDB = db
        exec(db, "PRAGMA journal_mode=WAL;")
        exec(db, "PRAGMA synchronous=NORMAL;")
        exec(db, "PRAGMA busy_timeout=4000;")
        ensureSchema(db)
        loadCursors(db)
    }

    private func openRead() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(Self.dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { return }
        readDB = db
        exec(db, "PRAGMA busy_timeout=4000;")
    }

    private func ensureSchema(_ db: OpaquePointer) {
        // Wipe + rebuild if the schema version moved (or the db predates it).
        if scalarInt(db, "PRAGMA user_version;") != Self.schemaVersion {
            exec(db, "DROP TABLE IF EXISTS msg;")
            exec(db, "DROP TABLE IF EXISTS cursor;")
        }
        exec(db, """
            CREATE VIRTUAL TABLE IF NOT EXISTS msg USING fts5(
                text,
                session_id UNINDEXED,
                provider   UNINDEXED,
                role       UNINDEXED,
                ts         UNINDEXED,
                seq        UNINDEXED,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            """)
        exec(db, """
            CREATE TABLE IF NOT EXISTS cursor(
                session_id TEXT PRIMARY KEY,
                provider   TEXT,
                file_size  INTEGER,
                offset     INTEGER,
                next_seq   INTEGER
            );
            """)
        exec(db, "PRAGMA user_version=\(Self.schemaVersion);")
    }

    private func loadCursors(_ db: OpaquePointer) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "SELECT session_id, file_size, offset, next_seq FROM cursor;", -1, &stmt, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            cursors[String(cString: c)] = (sqlite3_column_int64(stmt, 1),
                                           sqlite3_column_int64(stmt, 2),
                                           sqlite3_column_int64(stmt, 3))
        }
    }

    // MARK: - Reconcile (called from main when entries change)

    func reconcile(entries: [SessionIndexEntry]) {
        // Staged sessions must never reach the real full-text database — it
        // outlives demo mode, and a fake row in it is a permanent lie.
        if DemoFleet.isEnabled { return }
        let work = entries.map {
            WorkItem(id: $0.sessionId, provider: $0.provider, cwd: $0.cwd,
                     size: $0.fileSize, transcriptPath: $0.transcriptPath,
                     external: $0.isExternalSource)
        }
        // Deferred: the backfill is the heaviest thing at launch and nobody can
        // search before the window is even open, so it waits for the index.
        WorkScheduler.shared.run(.init(id: "search-reconcile")) { [weak self] in
            guard let self else { return }
            self.latestWork = work
            guard !self.scheduled else { return }
            self.scheduled = true
            while let next = self.latestWork {
                self.latestWork = nil
                self.runReconcile(next)
            }
            self.scheduled = false
        }
    }

    private func runReconcile(_ work: [WorkItem]) {
        guard let db = writeDB else { return }
        pruneVanished(db, live: Set(work.map(\.id)))
        // New sessions, or files whose size changed since last fold.
        let todo = work.filter { item in
            guard let c = cursors[item.id] else { return item.size > 0 }
            return item.size != c.size
        }
        guard !todo.isEmpty else { return }

        totalFiles = todo.count
        indexedFiles = 0
        reportProgress()
        for item in todo {
            autoreleasepool { indexSession(db, item) }
            indexedFiles += 1
            if indexedFiles % 5 == 0 || indexedFiles == totalFiles { reportProgress() }
        }
        totalFiles = 0
        indexedFiles = 0
        reportProgress()
    }

    private func indexSession(_ db: OpaquePointer, _ item: WorkItem) {
        var startOffset: Int64 = 0
        var seq: Int64 = 0
        if let prev = cursors[item.id] {
            if item.size >= prev.size {
                startOffset = prev.offset
                seq = prev.seq
            } else {
                // File shrank / was replaced — drop its rows and rebuild.
                deleteSession(db, item.id)
            }
        }
        guard let url = resolveURL(item) else { return }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "INSERT INTO msg(text, session_id, provider, role, ts, seq) VALUES(?,?,?,?,?,?);",
            -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        exec(db, "BEGIN;")
        var localSeq = seq
        let prov = item.provider.rawValue
        let newOffset = SessionIndexer.indexableMessages(
            provider: item.provider, at: url, fromOffset: startOffset
        ) { role, ts, text in
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, text, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, item.id, -1, Self.transient)
            sqlite3_bind_text(stmt, 3, prov, -1, Self.transient)
            sqlite3_bind_text(stmt, 4, role, -1, Self.transient)
            sqlite3_bind_int64(stmt, 5, ts.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0)
            sqlite3_bind_int64(stmt, 6, localSeq)
            sqlite3_step(stmt)
            localSeq += 1
        }
        exec(db, "COMMIT;")

        cursors[item.id] = (item.size, newOffset, localSeq)
        upsertCursor(db, id: item.id, provider: prov, size: item.size, offset: newOffset, seq: localSeq)
    }

    private func resolveURL(_ item: WorkItem) -> URL? {
        if let u = urlCache[item.id] { return u }
        guard let u = SessionIndexer.transcriptURL(
            provider: item.provider, sessionId: item.id, cwd: item.cwd,
            transcriptPath: item.transcriptPath, external: item.external) else { return nil }
        urlCache[item.id] = u
        return u
    }

    // The index holds the full text of every message of every session, so it is
    // roughly a second copy of ~/.claude/projects — and until now nothing ever
    // removed a row: deleteSession only fires when a file shrinks, so a session
    // the user deleted (or a project directory that was removed) kept its text
    // here forever and the database only ever grew. Dropping rows for sessions
    // that are no longer in the index is self-healing if it ever fires too
    // eagerly, since a session with no cursor is simply treated as new.
    private func pruneVanished(_ db: OpaquePointer, live: Set<String>) {
        guard !live.isEmpty else { return }   // nothing scanned yet — not "all gone"
        let gone = cursors.keys.filter { !live.contains($0) }
        guard !gone.isEmpty else { return }
        exec(db, "BEGIN;")
        for id in gone {
            deleteSession(db, id)
            deleteCursor(db, id)
            cursors[id] = nil
        }
        exec(db, "COMMIT;")
    }

    private func deleteCursor(_ db: OpaquePointer, _ id: String) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM cursor WHERE session_id=?;", -1, &s, nil)
                == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, id, -1, Self.transient)
        sqlite3_step(s)
    }

    private func deleteSession(_ db: OpaquePointer, _ id: String) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM msg WHERE session_id=?;", -1, &s, nil) == SQLITE_OK
        else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, id, -1, Self.transient)
        sqlite3_step(s)
    }

    private func upsertCursor(_ db: OpaquePointer, id: String, provider: String,
                              size: Int64, offset: Int64, seq: Int64) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO cursor(session_id, provider, file_size, offset, next_seq)
            VALUES(?,?,?,?,?)
            ON CONFLICT(session_id) DO UPDATE SET
                provider=excluded.provider, file_size=excluded.file_size,
                offset=excluded.offset, next_seq=excluded.next_seq;
            """, -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, id, -1, Self.transient)
        sqlite3_bind_text(s, 2, provider, -1, Self.transient)
        sqlite3_bind_int64(s, 3, size)
        sqlite3_bind_int64(s, 4, offset)
        sqlite3_bind_int64(s, 5, seq)
        sqlite3_step(s)
    }

    private func reportProgress() {
        guard let cb = onProgress else { return }
        let d = indexedFiles, t = totalFiles
        DispatchQueue.main.async { cb(d, t) }
    }

    // MARK: - Query

    func search(_ raw: String, completion: @escaping ([MessageHit]) -> Void) {
        if DemoFleet.isEnabled {
            let hits = DemoFleet.search(raw)
            DispatchQueue.main.async { completion(hits) }
            return
        }
        guard let match = Self.ftsQuery(from: raw) else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        queryQueue.async { [weak self] in
            let hits = self?.runQuery(match) ?? []
            DispatchQueue.main.async { completion(hits) }
        }
    }

    private func runQuery(_ match: String) -> [MessageHit] {
        guard let db = readDB else { return [] }
        // One row per matching message, best-ranked first. FTS5 already returns
        // a message once however many times the term occurs in it; the seen-set
        // is belt-and-braces against any duplicate rows.
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT session_id, provider, role, ts, seq,
                   snippet(msg, 0, char(2), char(3), '…', 14), text
            FROM msg WHERE msg MATCH ?1 ORDER BY rank LIMIT ?2;
            """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, match, -1, Self.transient)
        sqlite3_bind_int(stmt, 2, Int32(Self.maxResults))

        var seen = Set<String>()
        var out: [MessageHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sidC = sqlite3_column_text(stmt, 0) else { continue }
            let sid = String(cString: sidC)
            let prov = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "claude"
            let provider = SessionProvider(rawValue: prov) ?? .claude
            let role = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let tsMs = sqlite3_column_int64(stmt, 3)
            let seq = sqlite3_column_int64(stmt, 4)
            let marked = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
            let text = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
            // One result per message (sessionId + ordinal).
            if !seen.insert("\(sid):\(seq)").inserted { continue }
            let ts = tsMs > 0 ? Date(timeIntervalSince1970: Double(tsMs) / 1000) : nil
            out.append(MessageHit(sessionId: sid, provider: provider, role: role,
                                  timestamp: ts, marked: marked,
                                  locator: String(text.prefix(400))))
        }
        return out
    }

    // Build a safe FTS5 MATCH string from free user input: each whitespace
    // token is quoted (so quotes/parens/colons/dashes can't be FTS operators),
    // ANDed together, and the last token gets a prefix '*' for as-you-type.
    static func ftsQuery(from raw: String) -> String? {
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        var parts: [String] = []
        for (i, tok) in tokens.enumerated() {
            let escaped = tok.replacingOccurrences(of: "\"", with: "\"\"")
            // Prefix-match the last token (≥2 chars) so results refine while typing.
            if i == tokens.count - 1, tok.count >= 2 {
                parts.append("\"\(escaped)\"*")
            } else {
                parts.append("\"\(escaped)\"")
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - SQLite helpers

    @discardableResult
    private func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func scalarInt(_ db: OpaquePointer, _ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }
}

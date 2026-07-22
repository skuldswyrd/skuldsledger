import Foundation
import GRDB

/// Single-file SQLite store: Trading/Records/skuld_journal.sqlite.
/// One DB for all days — session_id/date partition per day, cross-day stats
/// (weekly re-rank) stay one query away.
final class AppDatabase {
    let dbQueue: DatabaseQueue

    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrator.migrate(dbQueue)
    }

    static func open() throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: Workspace.recordsDir, withIntermediateDirectories: true)
        return try AppDatabase(path: Workspace.databaseURL.path)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                  id TEXT PRIMARY KEY,
                  date TEXT NOT NULL,
                  instrument TEXT NOT NULL,
                  ib_high REAL,
                  ib_low REAL,
                  trades_taken INTEGER NOT NULL DEFAULT 0,
                  status TEXT NOT NULL DEFAULT 'open',
                  created_at TEXT NOT NULL
                );

                CREATE INDEX idx_sessions_date ON sessions(date);

                CREATE TABLE levels (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL REFERENCES sessions(id),
                  name TEXT NOT NULL,
                  price REAL NOT NULL,
                  stars INTEGER NOT NULL,
                  rank_score INTEGER,
                  broken INTEGER NOT NULL DEFAULT 0,
                  notes TEXT
                );

                CREATE INDEX idx_levels_session ON levels(session_id);

                CREATE TABLE entries (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL REFERENCES sessions(id),
                  ts TEXT NOT NULL,
                  screenshot_path TEXT NOT NULL DEFAULT '',
                  comment TEXT,
                  looking_for TEXT,
                  want_to_see TEXT,
                  action TEXT,
                  play_type TEXT,
                  level_id TEXT REFERENCES levels(id),
                  mentor_reply TEXT,
                  mentor_claude_session_id TEXT
                );

                CREATE INDEX idx_entries_session ON entries(session_id);

                CREATE TABLE trades (
                  id TEXT PRIMARY KEY,
                  entry_id TEXT NOT NULL REFERENCES entries(id),
                  play_type TEXT NOT NULL,
                  level_id TEXT REFERENCES levels(id),
                  contracts INTEGER NOT NULL DEFAULT 1,
                  entry_price REAL,
                  stop_price REAL,
                  target_price REAL,
                  exit_price REAL,
                  ticks_result REAL,
                  usd_result REAL,
                  result TEXT
                );

                CREATE TABLE chops (
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL REFERENCES sessions(id),
                  ts TEXT NOT NULL,
                  range_high REAL,
                  range_low REAL,
                  crossings INTEGER
                );
                """)
        }

        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE comments (
                  id TEXT PRIMARY KEY,
                  entry_id TEXT NOT NULL REFERENCES entries(id),
                  ts TEXT NOT NULL,
                  author TEXT NOT NULL,
                  text TEXT NOT NULL
                );

                CREATE INDEX idx_comments_entry ON comments(entry_id);

                ALTER TABLE entries ADD COLUMN instrument TEXT;
                ALTER TABLE trades ADD COLUMN instrument TEXT;

                UPDATE entries SET instrument =
                  (SELECT instrument FROM sessions WHERE sessions.id = entries.session_id);
                UPDATE trades SET instrument =
                  (SELECT e.instrument FROM entries e WHERE e.id = trades.entry_id);
                """)
        }

        return migrator
    }

    // MARK: - Sessions

    func fetchSession(date: String) throws -> SessionRecord? {
        try dbQueue.read { db in
            try SessionRecord
                .filter(Column("date") == date)
                .order(Column("created_at").desc)
                .fetchOne(db)
        }
    }

    func save(_ session: SessionRecord) throws {
        try dbQueue.write { db in try session.save(db) }
    }

    /// Most recent session across all days — seeds the next setup screen.
    func latestSession() throws -> SessionRecord? {
        try dbQueue.read { db in
            try SessionRecord
                .order(Column("created_at").desc)
                .fetchOne(db)
        }
    }

    // MARK: - Levels

    func levels(sessionId: String) throws -> [LevelRecord] {
        try dbQueue.read { db in
            try LevelRecord
                .filter(Column("session_id") == sessionId)
                .order(Column("price").desc)
                .fetchAll(db)
        }
    }

    func save(_ level: LevelRecord) throws {
        try dbQueue.write { db in try level.save(db) }
    }

    func saveLevels(_ levels: [LevelRecord]) throws {
        try dbQueue.write { db in
            for level in levels { try level.save(db) }
        }
    }

    // MARK: - Entries

    func entries(sessionId: String) throws -> [EntryRecord] {
        try dbQueue.read { db in
            try EntryRecord
                .filter(Column("session_id") == sessionId)
                .order(Column("ts").desc)
                .fetchAll(db)
        }
    }

    func save(_ entry: EntryRecord) throws {
        try dbQueue.write { db in try entry.save(db) }
    }

    func updateEntryMentor(id: String, reply: String?, claudeSessionId: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE entries
                    SET mentor_reply = ?, mentor_claude_session_id = ?
                    WHERE id = ?
                    """,
                arguments: [reply, claudeSessionId, id])
        }
    }

    /// Most recent stored claude session id for a session's entries (for --resume).
    func latestMentorSessionId(sessionId: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT mentor_claude_session_id FROM entries
                    WHERE session_id = ? AND mentor_claude_session_id IS NOT NULL
                    ORDER BY ts DESC LIMIT 1
                    """,
                arguments: [sessionId])
        }
    }

    // MARK: - Trades

    func trades(sessionId: String) throws -> [TradeRecord] {
        try dbQueue.read { db in
            try TradeRecord.fetchAll(
                db,
                sql: """
                    SELECT trades.* FROM trades
                    JOIN entries ON entries.id = trades.entry_id
                    WHERE entries.session_id = ?
                    ORDER BY entries.ts ASC
                    """,
                arguments: [sessionId])
        }
    }

    func save(_ trade: TradeRecord) throws {
        try dbQueue.write { db in try trade.save(db) }
    }

    // MARK: - Comments

    /// All comments for a session's entries, oldest first, grouped by entry.
    func comments(sessionId: String) throws -> [String: [CommentRecord]] {
        let rows = try dbQueue.read { db in
            try CommentRecord.fetchAll(
                db,
                sql: """
                    SELECT comments.* FROM comments
                    JOIN entries ON entries.id = comments.entry_id
                    WHERE entries.session_id = ?
                    ORDER BY comments.ts ASC
                    """,
                arguments: [sessionId])
        }
        return Dictionary(grouping: rows, by: \.entryId)
    }

    func save(_ comment: CommentRecord) throws {
        try dbQueue.write { db in try comment.save(db) }
    }

    // MARK: - Deletes (post CRUD)

    /// Removes an entry and everything hanging off it (comments, trades).
    func deleteEntry(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM comments WHERE entry_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM trades WHERE entry_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM entries WHERE id = ?", arguments: [id])
        }
    }

    func deleteTrade(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM trades WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Chops

    func chops(sessionId: String) throws -> [ChopRecord] {
        try dbQueue.read { db in
            try ChopRecord
                .filter(Column("session_id") == sessionId)
                .order(Column("ts").asc)
                .fetchAll(db)
        }
    }

    func save(_ chop: ChopRecord) throws {
        try dbQueue.write { db in try chop.save(db) }
    }
}

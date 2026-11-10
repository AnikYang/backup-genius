import Foundation
import CSQLite

enum Field {
    case text(String), int(Int64), blob(Data), real(Double)
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Catalog {
    private let db: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    init(_ url: URL) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard let handle else { throw BackupError.message("无法打开本地索引") }
        db = handle
        if status != SQLITE_OK {
            let error = failure()
            sqlite3_close(handle)
            throw error
        }
        do {
            try executeSQL("""
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=FULL;
                PRAGMA busy_timeout=3000;
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS files (
                    path TEXT PRIMARY KEY, folded TEXT NOT NULL, identity TEXT NOT NULL,
                    kind TEXT NOT NULL, payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS files_by_name ON files(folded);
                CREATE INDEX IF NOT EXISTS files_by_identity ON files(identity);
                CREATE TABLE IF NOT EXISTS aligned (path TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS dirty (side TEXT NOT NULL, path TEXT NOT NULL, flags INTEGER NOT NULL,
                    PRIMARY KEY(side, path));
                CREATE TABLE IF NOT EXISTS versions (id TEXT PRIMARY KEY, time REAL NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX IF NOT EXISTS versions_by_time ON versions(time);
                CREATE TABLE IF NOT EXISTS version_chunks (
                    version TEXT NOT NULL, hash BLOB NOT NULL, PRIMARY KEY(version, hash));
                CREATE INDEX IF NOT EXISTS referenced_chunks ON version_chunks(hash);
                CREATE TABLE IF NOT EXISTS chunks (
                    hash BLOB PRIMARY KEY, pack TEXT NOT NULL, offset INTEGER NOT NULL, length INTEGER NOT NULL);
                CREATE INDEX IF NOT EXISTS chunks_by_pack ON chunks(pack);
                CREATE TABLE IF NOT EXISTS activity (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS backup_runs (
                    id TEXT PRIMARY KEY, started REAL NOT NULL, finished REAL, outcome TEXT NOT NULL,
                    added INTEGER NOT NULL DEFAULT 0, updated INTEGER NOT NULL DEFAULT 0, issues INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS backup_runs_by_date ON backup_runs(started DESC, id DESC);
                CREATE TABLE IF NOT EXISTS backup_run_changes (
                    sequence INTEGER PRIMARY KEY, run TEXT NOT NULL, kind TEXT NOT NULL,
                    search_path TEXT NOT NULL, payload BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS backup_run_changes_by_run ON backup_run_changes(run, sequence DESC);
                CREATE INDEX IF NOT EXISTS backup_run_changes_by_kind ON backup_run_changes(run, kind, sequence DESC);
                """)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    private func failure() -> BackupError {
        .message("本地索引：\(String(cString: sqlite3_errmsg(db)))")
    }

    private func executeSQL(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func transaction(_ action: () throws -> Void) throws {
        try executeSQL("BEGIN IMMEDIATE")
        do {
            try action()
            try executeSQL("COMMIT")
        } catch {
            try? executeSQL("ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, _ fields: [Field], _ row: (OpaquePointer) throws -> Void) throws {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
            statement = prepared
            statements[sql] = prepared
        }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (index, field) in fields.enumerated() {
            let column = Int32(index + 1)
            let status: Int32
            switch field {
            case let .text(value): status = sqlite3_bind_text(statement, column, value, -1, transient)
            case let .int(value): status = sqlite3_bind_int64(statement, column, value)
            case let .real(value): status = sqlite3_bind_double(statement, column, value)
            case let .blob(value):
                status = value.isEmpty ? sqlite3_bind_zeroblob(statement, column, 0) : value.withUnsafeBytes {
                    sqlite3_bind_blob(statement, column, $0.baseAddress, Int32($0.count), transient)
                }
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(statement)
            case SQLITE_DONE: return
            default: throw failure()
            }
        }
    }

    private func execute(_ sql: String, _ fields: [Field] = []) throws {
        try run(sql, fields) { _ in }
    }

    private func data(_ row: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }

    private func string(_ row: OpaquePointer, _ column: Int32) -> String {
        guard let text = sqlite3_column_text(row, column) else { return "" }
        return String(cString: text)
    }

    func get(_ key: String) throws -> String? {
        var value: String?
        try run("SELECT value FROM meta WHERE key=?", [.text(key)]) { value = string($0, 0) }
        return value
    }

    func set(_ key: String, _ value: String) throws {
        try execute("INSERT OR REPLACE INTO meta VALUES (?,?)", [.text(key), .text(value)])
    }

    func file(_ path: String) throws -> FileRecord? {
        var result: FileRecord?
        try run("SELECT payload FROM files WHERE path=?", [.text(path)]) {
            result = try JSONDecoder().decode(FileRecord.self, from: data($0, 0))
        }
        return result
    }

    func visitFiles(below path: String = "", _ visit: (FileRecord) throws -> Void) throws {
        let decode: (OpaquePointer) throws -> Void = {
            try visit(JSONDecoder().decode(FileRecord.self, from: self.data($0, 0)))
        }
        if path.isEmpty {
            try run("SELECT payload FROM files", [], decode)
        } else {
            try run("SELECT payload FROM files WHERE path=? OR (path>=? AND path<?)",
                    [.text(path), .text(path + "/"), .text(path + "0")], decode)
        }
    }

    func paths(folded: String) throws -> [String] {
        var result: [String] = []
        try run("SELECT path FROM files WHERE folded=?", [.text(folded)]) { result.append(string($0, 0)) }
        return result
    }

    func fileCount() throws -> Int {
        var result = 0
        try run("SELECT count(*) FROM files WHERE kind!='directory'", []) { result = Int(sqlite3_column_int64($0, 0)) }
        return result
    }

    func recordChanges(_ changes: Changes, side: String) throws {
        try transaction {
            if changes.resetCursor { try set("\(side).cursor", "0") }
            if changes.cursor > 0 {
                let previous = UInt64(try get("\(side).cursor") ?? "") ?? 0
                try set("\(side).cursor", String(max(previous, changes.cursor)))
            }
            if changes.fullScan { try set("\(side).full", "1") }
            for (path, flags) in changes.paths {
                try execute("""
                    INSERT INTO dirty VALUES (?,?,?)
                    ON CONFLICT(side,path) DO UPDATE SET flags=flags|excluded.flags
                    """, [.text(side), .text(path), .int(Int64(flags))])
            }
        }
    }

    func pending(_ side: String) throws -> Changes {
        var result = Changes()
        result.fullScan = try get("\(side).full") == "1"
        try run("SELECT path, flags FROM dirty WHERE side=?", [.text(side)]) {
            result.paths[string($0, 0)] = UInt32(sqlite3_column_int64($0, 1))
        }
        return result
    }

    func finishScan(sourceRetry: [String: UInt32], targetRetry: Set<String>, verified: Bool, date: Date?) throws {
        try transaction {
            try execute("DELETE FROM dirty")
            try set("source.full", "0")
            try set("target.full", "0")
            try set("source.baseline", "1")
            for (path, flags) in sourceRetry {
                try execute("INSERT INTO dirty VALUES ('source',?,?)", [.text(path), .int(Int64(flags))])
            }
            for path in targetRetry {
                try execute("INSERT INTO dirty VALUES ('target',?,?)", [.text(path), .int(Int64(flagModified))])
            }
            if let date { try set("lastSuccess", String(date.timeIntervalSinceReferenceDate)) }
            if verified { try set("lastVerify", String(Date().timeIntervalSinceReferenceDate)) }
        }
    }

    func putActivity(_ entries: [Activity]) throws {
        guard !entries.isEmpty else { return }
        try transaction {
            for activity in entries {
                try execute("INSERT INTO activity(payload) VALUES (?)", [.blob(try JSONEncoder().encode(activity))])
            }
            try execute("DELETE FROM activity WHERE sequence <= (SELECT max(sequence)-2000 FROM activity)")
        }
    }

    func activities() throws -> [Activity] {
        var result: [Activity] = []
        try run("SELECT payload FROM activity ORDER BY sequence DESC LIMIT 500", []) {
            result.append(try JSONDecoder().decode(Activity.self, from: data($0, 0)))
        }
        return result
    }

    func beginRun(_ tag: BackupRunTag) throws {
        // A run without a recorded finish may have only partially committed.
        try execute("INSERT OR IGNORE INTO backup_runs(id,started,outcome) VALUES (?,?,?)", [
            .text(tag.id.uuidString), .real(tag.started.timeIntervalSinceReferenceDate),
            .text(BackupRun.Outcome.unconfirmed.rawValue),
        ])
    }

    func finishRun(_ id: UUID, outcome: BackupRun.Outcome, at date: Date, issues: Int) throws {
        try execute("UPDATE backup_runs SET finished=?,outcome=?,issues=? WHERE id=?", [
            .real(date.timeIntervalSinceReferenceDate), .text(outcome.rawValue), .int(Int64(issues)), .text(id.uuidString),
        ])
    }

    func latestRunID() throws -> UUID? {
        var result: UUID?
        try run("SELECT id FROM backup_runs ORDER BY started DESC,id DESC LIMIT 1", []) {
            result = UUID(uuidString: string($0, 0))
        }
        return result
    }

    func backupRuns() throws -> [BackupRun] {
        var result: [BackupRun] = []
        try run("SELECT id,started,finished,outcome,added,updated,issues FROM backup_runs ORDER BY started DESC,id DESC", []) {
            guard let id = UUID(uuidString: string($0, 0)), let outcome = BackupRun.Outcome(rawValue: string($0, 3)) else {
                throw BackupError.message("备份历史记录无效")
            }
            let started = Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 1))
            let finished = sqlite3_column_type($0, 2) == SQLITE_NULL ? nil :
                Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 2))
            result.append(BackupRun(id: id, started: started, finished: finished, outcome: outcome,
                                    added: Int(sqlite3_column_int64($0, 4)), updated: Int(sqlite3_column_int64($0, 5)),
                                    issueCount: Int(sqlite3_column_int64($0, 6))))
        }
        return result
    }

    func backupChanges(in id: UUID, kind: Activity.Kind?, query: String, limit: Int, offset: Int) throws -> BackupRunChangePage {
        var whereClause = "WHERE run=?"
        var fields: [Field] = [.text(id.uuidString)]
        if let kind {
            whereClause += " AND kind=?"
            fields.append(.text(kind.rawValue))
        }
        if !query.isEmpty {
            whereClause += " AND instr(search_path,?)>0"
            fields.append(.text(pathKey(query, caseSensitive: false)))
        }
        var total = 0
        try run("SELECT count(*) FROM backup_run_changes \(whereClause)", fields) {
            total = Int(sqlite3_column_int64($0, 0))
        }
        var items: [Activity] = []
        try run("SELECT payload FROM backup_run_changes \(whereClause) ORDER BY sequence DESC LIMIT ? OFFSET ?",
                fields + [.int(Int64(limit)), .int(Int64(offset))]) {
            items.append(try JSONDecoder().decode(Activity.self, from: data($0, 0)))
        }
        return BackupRunChangePage(items: items, total: total)
    }

    func versions() throws -> [ArchivedVersion] {
        var result: [ArchivedVersion] = []
        try run("SELECT payload FROM versions ORDER BY time DESC", []) {
            result.append(try JSONDecoder().decode(ArchivedVersion.self, from: data($0, 0)))
        }
        return result
    }

    func version(_ id: UUID) throws -> ArchivedVersion? {
        var result: ArchivedVersion?
        try run("SELECT payload FROM versions WHERE id=?", [.text(id.uuidString)]) {
            result = try JSONDecoder().decode(ArchivedVersion.self, from: data($0, 0))
        }
        return result
    }

    func chunk(_ hash: Data) throws -> ChunkLocation? {
        var result: ChunkLocation?
        try run("SELECT pack, offset, length FROM chunks WHERE hash=?", [.blob(hash)]) {
            guard let pack = UUID(uuidString: string($0, 0)) else { throw BackupError.message("历史数据索引损坏") }
            result = ChunkLocation(hash: hash, pack: pack, offset: sqlite3_column_int64($0, 1),
                                   length: Int(sqlite3_column_int64($0, 2)))
        }
        return result
    }

    func usedPacks() throws -> Set<UUID> {
        var result = Set<UUID>()
        try run("SELECT DISTINCT pack FROM chunks JOIN version_chunks USING (hash)", []) {
            if let pack = UUID(uuidString: string($0, 0)) { result.insert(pack) }
        }
        return result
    }

    func packs() throws -> Set<UUID> {
        var result = Set<UUID>()
        try run("SELECT DISTINCT pack FROM chunks", []) {
            if let pack = UUID(uuidString: string($0, 0)) { result.insert(pack) }
        }
        return result
    }

    func liveChunks(in pack: UUID) throws -> [ChunkLocation] {
        var result: [ChunkLocation] = []
        try run("""
            SELECT hash, offset, length FROM chunks
            WHERE pack=? AND EXISTS(SELECT 1 FROM version_chunks WHERE hash=chunks.hash) ORDER BY offset
            """, [.text(pack.uuidString)]) {
            result.append(ChunkLocation(hash: data($0, 0), pack: pack, offset: sqlite3_column_int64($0, 1),
                                        length: Int(sqlite3_column_int64($0, 2))))
        }
        return result
    }

    var generation: Int64 {
        get throws { Int64(try get("generation") ?? "") ?? 0 }
    }

    func resetDiskIndex() throws {
        try transaction {
            try execute("DELETE FROM files")
            try execute("DELETE FROM versions")
            try execute("DELETE FROM version_chunks")
            try execute("DELETE FROM chunks")
            try set("generation", "0")
            try set("source.full", "1")
        }
    }

    func alignment() throws -> [String: FileRecord] {
        var result: [String: FileRecord] = [:]
        try run("SELECT path,payload FROM aligned", []) {
            result[string($0, 0)] = try JSONDecoder().decode(FileRecord.self, from: data($0, 1))
        }
        return result
    }

    func bindSource(_ identity: String) throws {
        try transaction {
            try execute("DELETE FROM aligned")
            try execute("INSERT INTO aligned SELECT path,payload FROM files")
            try set("aligned.source", identity)
            try execute("DELETE FROM dirty WHERE side='source'")
            try set("source.stream", "")
            try set("source.cursor", "0")
            try set("source.full", "1")
        }
    }

    func apply(_ batch: DiskBatch, caseSensitive: Bool, align: Bool = false) throws {
        try transaction {
            guard try generation + 1 == batch.generation else { throw BackupError.message("备份记录顺序异常") }
            if let tag = batch.run { try beginRun(tag) }
            var added: Int64 = 0
            var updated: Int64 = 0
            for chunk in batch.chunks {
                try execute("INSERT OR REPLACE INTO chunks VALUES (?,?,?,?)",
                            [.blob(chunk.hash), .text(chunk.pack.uuidString), .int(chunk.offset), .int(Int64(chunk.length))])
            }
            for edit in batch.edits {
                if let old = edit.from {
                    try execute("DELETE FROM files WHERE path=?", [.text(old)])
                    if align { try execute("DELETE FROM aligned WHERE path=?", [.text(old)]) }
                }
                if let record = edit.next {
                    try execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?)", [
                        .text(record.path), .text(pathKey(record.path, caseSensitive: caseSensitive)),
                        .text(record.source.identity), .text(record.source.kind.rawValue),
                        .blob(try JSONEncoder().encode(record)),
                    ])
                    if align {
                        try execute("INSERT OR REPLACE INTO aligned SELECT path,payload FROM files WHERE path=?", [.text(record.path)])
                    }
                } else if edit.method != .archive {
                    try execute("DELETE FROM files WHERE path=?", [.text(edit.path)])
                    if align { try execute("DELETE FROM aligned WHERE path=?", [.text(edit.path)]) }
                }
                if let version = edit.archive {
                    let id = version.item.id.uuidString
                    try execute("INSERT OR REPLACE INTO versions VALUES (?,?,?)", [
                        .text(id), .real(version.item.date.timeIntervalSinceReferenceDate),
                        .blob(try JSONEncoder().encode(version)),
                    ])
                    if version.clone == nil {
                        for index in 0..<(version.hashes.count / digestSize) {
                            try execute("INSERT OR IGNORE INTO version_chunks VALUES (?,?)",
                                        [.text(id), .blob(version.hashes.blockHash(index)!)])
                        }
                    }
                }
                if let activity = edit.activity {
                    let payload = try JSONEncoder().encode(activity)
                    try execute("INSERT INTO activity(payload) VALUES (?)", [.blob(payload)])
                    if let tag = batch.run, let entry = edit.next, entry.source.kind != .directory,
                       activity.kind == .added || activity.kind == .updated {
                        try execute("INSERT INTO backup_run_changes(run,kind,search_path,payload) VALUES (?,?,?,?)", [
                            .text(tag.id.uuidString), .text(activity.kind.rawValue),
                            .text(pathKey(activity.path, caseSensitive: false)), .blob(payload),
                        ])
                        if activity.kind == .added { added += 1 } else { updated += 1 }
                    }
                }
            }
            if let tag = batch.run, added + updated > 0 {
                try execute("UPDATE backup_runs SET added=added+?,updated=updated+? WHERE id=?",
                            [.int(added), .int(updated), .text(tag.id.uuidString)])
            }
            if !batch.edits.isEmpty {
                try execute("DELETE FROM activity WHERE sequence <= (SELECT max(sequence)-2000 FROM activity)")
            }
            for version in batch.pruned {
                try execute("DELETE FROM versions WHERE id=?", [.text(version.uuidString)])
                try execute("DELETE FROM version_chunks WHERE version=?", [.text(version.uuidString)])
            }
            for pack in batch.retiredPacks {
                try execute("DELETE FROM chunks WHERE pack=?", [.text(pack.uuidString)])
            }
            try set("generation", String(batch.generation))
            try set("lastBatch", batch.id.uuidString)
            if let writer = batch.writer { try set("writer", writer.uuidString) }
        }
    }
}

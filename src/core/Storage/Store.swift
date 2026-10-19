import Foundation

/// Where RunBo keeps its data. Everything lives under the current user's
/// Application Support directory and is only readable by that user.
public enum StoragePaths {
    /// Application Support folder for the App. Earlier builds used `TerminalDeck`;
    /// `migrateLegacySupportDirectoryIfNeeded` moves that store into place once.
    public static let folderName = "RunBo"
    public static let legacyFolderName = "TerminalDeck"

    public static func applicationSupportBase() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    public static func supportDirectory() -> URL {
        applicationSupportBase().appendingPathComponent(folderName, isDirectory: true)
    }

    /// Migrates the pre-rename Application Support store so existing cards and history survive.
    /// Returns the directory a store should open: the new folder once it exists, or the untouched
    /// legacy folder if neither moving nor copying works, so data is never stranded behind a rename.
    public static func migrateLegacySupportDirectoryIfNeeded(
        in base: URL = applicationSupportBase(),
        fileManager: FileManager = .default
    ) -> URL {
        let target = base.appendingPathComponent(folderName, isDirectory: true)
        guard !fileManager.fileExists(atPath: target.path) else { return target }
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        guard fileManager.fileExists(atPath: legacy.path) else { return target }
        do {
            try fileManager.moveItem(at: legacy, to: target)
            return target
        } catch {
            // Cross-volume or permission failure: copy and keep the old folder as a backup.
            do {
                try fileManager.copyItem(at: legacy, to: target)
                return target
            } catch {
                return legacy
            }
        }
    }

    public static func databaseURL(in directory: URL? = nil) -> URL {
        (directory ?? supportDirectory()).appendingPathComponent("deck.sqlite3")
    }

    public static func shimDirectory(in directory: URL? = nil) -> URL {
        (directory ?? supportDirectory()).appendingPathComponent("shims", isDirectory: true)
    }

    /// Creates a directory (and parents) with `0700` permissions.
    @discardableResult
    public static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // createDirectory does not tighten permissions of an existing directory.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Restricts a file to the current user.
    public static func restrictToOwner(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Rules from `session-history`: both card menus keep only the current run and the
/// previous run, temporary terminals expire 24 hours after their last input or output
/// once they ended.
public enum RetentionPolicy {
    /// Finished sessions kept per card/temporary terminal: the one just replaced and
    /// the one before it. While a session is running, only one finished predecessor is
    /// kept so the card still has exactly "this run + the previous run".
    public static let sessionHistoryLimit = 2
    public static let tempIdleTimeout: TimeInterval = 24 * 60 * 60

    /// Temporary terminal ids that must be deleted now.
    /// - Parameters:
    ///   - temps: all temporary terminals.
    ///   - latestSessions: newest session per temporary terminal id.
    ///   - now: reference time (injected for tests).
    public static func expiredTempIDs(
        temps: [TempTerminal],
        latestSessions: [String: SessionRecord],
        now: Date = Date()
    ) -> [String] {
        temps.compactMap { temp in
            // Copies live for this App run, retained launch cards indefinitely. Neither uses the ad-hoc 24h clock.
            guard temp.copy?.runID == nil, temp.launchConfiguration == nil else { return nil }
            guard let session = latestSessions[temp.id] else {
                // No session recorded: nothing is running, expire on the activity clock.
                return temp.lastActivityAt.addingTimeInterval(tempIdleTimeout) <= now ? temp.id : nil
            }
            // A live session is never expired by the timer.
            guard session.isFinished else { return nil }
            let deadline = temp.lastActivityAt.addingTimeInterval(tempIdleTimeout)
            return deadline <= now ? temp.id : nil
        }
    }
}

/// History event payload bytes and session counts, including running sessions.
public struct HistoryUsage: Equatable, Sendable {
    public var eventBytes: Int64
    public var finishedSessions: Int
    public var runningSessions: Int

    public init(eventBytes: Int64 = 0, finishedSessions: Int = 0, runningSessions: Int = 0) {
        self.eventBytes = eventBytes
        self.finishedSessions = finishedSessions
        self.runningSessions = runningSessions
    }

    public var humanReadableBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: eventBytes)
    }
}

/// Versioned SQLite metadata store: preset cards, temporary terminals, sessions,
/// appended history events and settings.
/// Thread safety: every statement goes through `Database`, which serialises access.
public final class DataStore: @unchecked Sendable {
    public static let schemaVersion: Int64 = 4

    public let directory: URL
    public let database: Database

    /// Opens (creating if needed) the store inside `directory`.
    /// Defaults to `~/Library/Application Support/RunBo`, migrating the pre-rename
    /// `~/Library/Application Support/TerminalDeck` store on first launch.
    public init(directory: URL? = nil) throws {
        let resolved = directory ?? StoragePaths.migrateLegacySupportDirectoryIfNeeded()
        try StoragePaths.ensureDirectory(resolved)
        self.directory = resolved
        let dbURL = StoragePaths.databaseURL(in: resolved)
        self.database = try Database(path: dbURL.path)
        try migrate()
        StoragePaths.restrictToOwner(dbURL)
    }

    /// In-memory store, used by the self-test harness.
    public static func inMemory() throws -> DataStore {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("runbo-store-\(UUID().uuidString)", isDirectory: true)
        return try DataStore(directory: temp)
    }

    // MARK: - Migrations

    private func migrate() throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER NOT NULL
        );
        """)
        var current = try database.query("SELECT version FROM schema_version LIMIT 1;") { $0.int(0) }.first ?? 0
        if current < 1 {
            try database.transaction {
                try database.execute("""
                CREATE TABLE IF NOT EXISTS preset_cards (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    command TEXT NOT NULL,
                    shell_override TEXT,
                    working_directory TEXT,
                    environment TEXT NOT NULL DEFAULT '',
                    auto_run INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS temp_terminals (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_activity_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    owner_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    shell TEXT NOT NULL,
                    working_directory TEXT,
                    started_at REAL NOT NULL,
                    ended_at REAL,
                    termination TEXT,
                    last_command_exit_status INTEGER,
                    last_command_failed INTEGER NOT NULL DEFAULT 0,
                    launch_failed INTEGER NOT NULL DEFAULT 0,
                    unexpected_exit INTEGER NOT NULL DEFAULT 0,
                    last_command_text TEXT
                );
                CREATE INDEX IF NOT EXISTS sessions_owner ON sessions (kind, owner_id, started_at DESC);

                CREATE TABLE IF NOT EXISTS session_events (
                    session_id TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    timestamp REAL NOT NULL,
                    kind TEXT NOT NULL,
                    data BLOB,
                    cols INTEGER NOT NULL DEFAULT 0,
                    rows INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (session_id, sequence)
                ) WITHOUT ROWID;

                CREATE TABLE IF NOT EXISTS settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
                try setSchemaVersion(1)
                current = 1
            }
        }
        if current < 2 {
            // v2 adds the "command result unknown" marker required by the design:
            // an unreadable status must be shown as unknown, never as a failure.
            try database.transaction {
                try database.execute("ALTER TABLE sessions ADD COLUMN last_command_status_unknown INTEGER NOT NULL DEFAULT 0;")
                try setSchemaVersion(2)
            }
        }
        if current < 3 {
            // v3 adds card tags. The vocabulary lives in its own table so a rename is one
            // UPDATE instead of a rewrite of every card; the two card tables only hold a
            // reference. `ON DELETE SET NULL` is what makes "delete a tag" mean "those cards
            // go back to 未加标签" rather than "those cards disappear" — deleting a tag must
            // never cascade into deleting cards.
            //
            // Both columns are nullable with no default, so every existing row lands on NULL
            // and therefore in the untagged block. No row is rewritten by this migration.
            try database.transaction {
                try database.execute("""
                CREATE TABLE IF NOT EXISTS tags (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    sort_order INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL
                );
                CREATE UNIQUE INDEX IF NOT EXISTS tags_name ON tags (name);

                ALTER TABLE preset_cards ADD COLUMN tag_id TEXT REFERENCES tags(id) ON DELETE SET NULL;
                ALTER TABLE temp_terminals ADD COLUMN tag_id TEXT REFERENCES tags(id) ON DELETE SET NULL;
                """)
                try setSchemaVersion(3)
            }
        }
        if current < 4 { try migrateCopies() }
    }

    private func migrateCopies() throws {
        try database.transaction {
            for table in ["preset_cards", "temp_terminals"] {
                try database.execute("""
                ALTER TABLE \(table) ADD COLUMN copy_source_id TEXT;
                ALTER TABLE \(table) ADD COLUMN copy_number INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE \(table) ADD COLUMN copy_anchor_id TEXT;
                ALTER TABLE \(table) ADD COLUMN clone_run_id TEXT;
                """)
            }
            try database.execute("""
            ALTER TABLE temp_terminals ADD COLUMN launch_shell TEXT;
            ALTER TABLE temp_terminals ADD COLUMN launch_directory TEXT;
            ALTER TABLE temp_terminals ADD COLUMN launch_environment TEXT NOT NULL DEFAULT '';
            """)
            try setSchemaVersion(4)
        }
    }

    private func setSchemaVersion(_ version: Int64) throws {
        try database.execute("DELETE FROM schema_version;")
        try database.run("INSERT INTO schema_version (version) VALUES (?);", [.integer(version)])
    }

    // MARK: - Tags

    /// Every tag, in block order.
    public func tags() throws -> [CardTag] {
        try database.query("SELECT id, name, sort_order, created_at FROM tags ORDER BY sort_order ASC, created_at ASC;") { row in
            CardTag(id: row.string(0), name: row.string(1), sortOrder: Int(row.int(2)), createdAt: row.date(3))
        }
    }

    public func save(_ tag: CardTag) throws {
        try database.run("""
        INSERT INTO tags (id, name, sort_order, created_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET name = excluded.name, sort_order = excluded.sort_order;
        """, [.text(tag.id), .text(tag.name), .integer(Int64(tag.sortOrder)), .date(tag.createdAt)])
    }

    /// Saves several tags in one transaction, so a reorder cannot half-apply.
    public func save(_ tags: [CardTag]) throws {
        guard !tags.isEmpty else { return }
        try database.transaction {
            for tag in tags { try save(tag) }
        }
    }

    /// Renames a tag. Cards are untouched: they point at the id, so the new name shows
    /// up everywhere the tag does.
    public func renameTag(id: String, to name: String) throws {
        try database.run("UPDATE tags SET name = ? WHERE id = ?;", [.text(name), .text(id)])
    }

    /// Deletes the tag only. `ON DELETE SET NULL` returns its cards to 未加标签;
    /// no card, session or history row is deleted here.
    public func deleteTag(id: String) throws {
        try database.run("DELETE FROM tags WHERE id = ?;", [.text(id)])
    }

    /// Files a card under a tag, or clears it with `nil`.
    public func setTag(_ tagId: String?, kind: SessionKind, ownerId: String) throws {
        let table = Self.table(for: kind)
        try database.run("""
        UPDATE \(table) SET tag_id = CASE WHEN id = ? THEN ? ELSE tag_id END,
            copy_anchor_id = NULL WHERE id = ? OR copy_anchor_id = ?;
        """, [.text(ownerId), .optText(tagId), .text(ownerId), .text(ownerId)])
    }

    /// How many cards and terminals currently reference each tag.
    public func tagUsageCounts() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for table in ["preset_cards", "temp_terminals"] {
            let rows = try database.query("SELECT tag_id, COUNT(*) FROM \(table) WHERE tag_id IS NOT NULL GROUP BY tag_id;") { row in
                (row.string(0), Int(row.int(1)))
            }
            for (id, count) in rows { counts[id, default: 0] += count }
        }
        return counts
    }

    private static func table(for kind: SessionKind) -> String {
        switch kind {
        case .preset: return "preset_cards"
        case .temp: return "temp_terminals"
        }
    }

    // MARK: - Settings

    public func string(forKey key: String) throws -> String? {
        try database.query("SELECT value FROM settings WHERE key = ?;", [.text(key)]) { $0.string(0) }.first
    }

    public func setString(_ value: String, forKey key: String) throws {
        try database.run(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            [.text(key), .text(value)]
        )
    }

    // MARK: - Preset cards

    public func cards() throws -> [PresetCard] {
        let cards = try database.query("SELECT id, title, command, shell_override, working_directory, environment, auto_run, created_at, updated_at, tag_id, copy_source_id, copy_number, copy_anchor_id, clone_run_id FROM preset_cards ORDER BY created_at ASC;") { row in
            PresetCard(
                id: row.string(0),
                title: row.string(1),
                command: row.string(2),
                shellOverride: row.optionalString(3),
                workingDirectory: row.optionalString(4),
                environment: EnvironmentParser.parse(row.string(5)),
                autoRun: row.bool(6),
                createdAt: row.date(7),
                updatedAt: row.date(8),
                tagId: row.optionalString(9),
                copy: Self.copy(from: row, offset: 10)
            )
        }
        return PresetCardReordering.ordered(cards, stored: try string(forKey: PresetCardReordering.storageKey))
    }

    /// Commit the category and position atomically. A failed order write must not leave a
    /// card in a different group, and stale drags must not recreate deleted cards/tags.
    public func movePresetCard(id: String, to destination: CardDropDestination) throws -> [PresetCard] {
        try database.transaction {
            if let tagId = destination.tagId, !(try tags()).contains(where: { $0.id == tagId }) {
                throw CardReorderingError.staleDestination
            }
            guard let moved = PresetCardReordering.moving(try cards(), id: id, to: destination) else {
                throw CardReorderingError.staleDestination
            }
            try setTag(destination.tagId, kind: .preset, ownerId: id)
            try setString(PresetCardReordering.storageValue(ids: moved.map(\.id)),
                          forKey: PresetCardReordering.storageKey)
            // setTag also detaches layout anchors: dragging moves a card, not its copies.
            return try cards()
        }
    }

    public func save(_ card: PresetCard) throws {
        try database.run("""
        INSERT INTO preset_cards (id, title, command, shell_override, working_directory, environment, auto_run, created_at, updated_at, tag_id, copy_source_id, copy_number, copy_anchor_id, clone_run_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            command = excluded.command,
            shell_override = excluded.shell_override,
            working_directory = excluded.working_directory,
            environment = excluded.environment,
            auto_run = excluded.auto_run,
            updated_at = excluded.updated_at,
            tag_id = excluded.tag_id,
            copy_source_id = excluded.copy_source_id,
            copy_number = excluded.copy_number,
            copy_anchor_id = excluded.copy_anchor_id,
            clone_run_id = excluded.clone_run_id;
        """, [
            .text(card.id),
            .text(card.title),
            .text(card.command),
            .optText(card.shellOverride),
            .optText(card.workingDirectory),
            .text(EnvironmentParser.render(card.environment)),
            .bool(card.autoRun),
            .date(card.createdAt),
            .date(card.updatedAt),
            .optText(card.tagId),
            .optText(card.copy?.sourceID),
            .integer(Int64(card.copy?.number ?? 0)),
            .optText(card.copy?.anchorID),
            .optText(card.copy?.runID),
        ])
    }

    /// Deletes a card and every session/event that belongs to it.
    public func deleteCard(id: String) throws {
        try database.transaction {
            for session in try sessions(kind: .preset, ownerId: id) {
                try deleteEvents(sessionId: session.id)
            }
            try database.run("DELETE FROM sessions WHERE kind = ? AND owner_id = ?;", [.text(SessionKind.preset.rawValue), .text(id)])
            try database.run("DELETE FROM preset_cards WHERE id = ?;", [.text(id)])
        }
    }

    // MARK: - Temporary terminals

    public func temps() throws -> [TempTerminal] {
        let values = try database.query("SELECT id, title, created_at, last_activity_at, tag_id, copy_source_id, copy_number, copy_anchor_id, clone_run_id, launch_shell, launch_directory, launch_environment FROM temp_terminals ORDER BY created_at ASC;") { row in
            TempTerminal(id: row.string(0), title: row.string(1), createdAt: row.date(2),
                         lastActivityAt: row.date(3), tagId: row.optionalString(4),
                         copy: Self.copy(from: row, offset: 5),
                         launchConfiguration: row.optionalString(9).map {
                             TerminalLaunchConfiguration(shell: $0, workingDirectory: row.optionalString(10),
                                                         environment: EnvironmentParser.parse(row.string(11)))
                         })
        }
        return CardCopyLayout.ordered(values, stored: try string(forKey: CardCopyLayout.terminalOrderKey))
    }

    public func save(_ temp: TempTerminal) throws {
        try database.run("""
        INSERT INTO temp_terminals (id, title, created_at, last_activity_at, tag_id, copy_source_id, copy_number, copy_anchor_id, clone_run_id, launch_shell, launch_directory, launch_environment)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET title = excluded.title, last_activity_at = excluded.last_activity_at,
            tag_id = excluded.tag_id, copy_source_id = excluded.copy_source_id,
            copy_number = excluded.copy_number, copy_anchor_id = excluded.copy_anchor_id,
            clone_run_id = excluded.clone_run_id, launch_shell = excluded.launch_shell,
            launch_directory = excluded.launch_directory, launch_environment = excluded.launch_environment;
        """, [.text(temp.id), .text(temp.title), .date(temp.createdAt), .date(temp.lastActivityAt),
              .optText(temp.tagId), .optText(temp.copy?.sourceID), .integer(Int64(temp.copy?.number ?? 0)),
              .optText(temp.copy?.anchorID), .optText(temp.copy?.runID),
              .optText(temp.launchConfiguration?.shell), .optText(temp.launchConfiguration?.workingDirectory),
              .text(EnvironmentParser.render(temp.launchConfiguration?.environment ?? [:]))])
    }

    /// Records user input or terminal output for the 24 hour expiry clock.
    public func touchTemp(id: String, at date: Date = Date()) throws {
        try database.run("UPDATE temp_terminals SET last_activity_at = ? WHERE id = ?;", [.date(date), .text(id)])
    }

    public func deleteTemp(id: String) throws {
        try database.transaction {
            for session in try sessions(kind: .temp, ownerId: id) {
                try deleteEvents(sessionId: session.id)
            }
            try database.run("DELETE FROM sessions WHERE kind = ? AND owner_id = ?;", [.text(SessionKind.temp.rawValue), .text(id)])
            try database.run("DELETE FROM temp_terminals WHERE id = ?;", [.text(id)])
        }
    }

    private static func copy(from row: Row, offset: Int32) -> CardCopy? {
        // Older retained cards still have provenance/anchors on disk. Decode them as ordinary
        // cards without rewriting IDs, configuration, order or history; the next save clears
        // obsolete metadata. Even active legacy copies no longer bind their grid position.
        guard let source = row.optionalString(offset), let runID = row.optionalString(offset+3) else { return nil }
        return CardCopy(sourceID: source, number: Int(row.int(offset+1)),
                        anchorID: nil, runID: runID)
    }

    // MARK: - Sessions

    public func save(_ session: SessionRecord) throws {
        try database.run("""
        INSERT INTO sessions (id, kind, owner_id, title, shell, working_directory, started_at, ended_at, termination, last_command_exit_status, last_command_failed, last_command_status_unknown, launch_failed, unexpected_exit, last_command_text)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            ended_at = excluded.ended_at,
            termination = excluded.termination,
            last_command_exit_status = excluded.last_command_exit_status,
            last_command_failed = excluded.last_command_failed,
            last_command_status_unknown = excluded.last_command_status_unknown,
            launch_failed = excluded.launch_failed,
            unexpected_exit = excluded.unexpected_exit,
            last_command_text = excluded.last_command_text;
        """, [
            .text(session.id),
            .text(session.kind.rawValue),
            .text(session.ownerId),
            .text(session.title),
            .text(session.shell),
            .optText(session.workingDirectory),
            .date(session.startedAt),
            .date(session.endedAt),
            .optText(session.termination?.rawValue),
            .optInt(session.lastCommandExitStatus),
            .bool(session.lastCommandFailed),
            .bool(session.lastCommandStatusUnknown),
            .bool(session.launchFailed),
            .bool(session.unexpectedExit),
            .optText(session.lastCommandText),
        ])
    }

    /// Newest first.
    public func sessions(kind: SessionKind, ownerId: String) throws -> [SessionRecord] {
        try database.query("""
        SELECT id, kind, owner_id, title, shell, working_directory, started_at, ended_at, termination, last_command_exit_status, last_command_failed, last_command_status_unknown, launch_failed, unexpected_exit, last_command_text
        FROM sessions WHERE kind = ? AND owner_id = ? ORDER BY started_at DESC;
        """, [.text(kind.rawValue), .text(ownerId)]) { Self.session(from: $0) }
    }

    public func session(id: String) throws -> SessionRecord? {
        try database.query("""
        SELECT id, kind, owner_id, title, shell, working_directory, started_at, ended_at, termination, last_command_exit_status, last_command_failed, last_command_status_unknown, launch_failed, unexpected_exit, last_command_text
        FROM sessions WHERE id = ?;
        """, [.text(id)]) { Self.session(from: $0) }.first
    }

    public func latestSession(kind: SessionKind, ownerId: String) throws -> SessionRecord? {
        try sessions(kind: kind, ownerId: ownerId).first
    }

    /// Sessions that never recorded an end: leftovers from a crash or a hard kill.
    public func unfinishedSessions() throws -> [SessionRecord] {
        try database.query("""
        SELECT id, kind, owner_id, title, shell, working_directory, started_at, ended_at, termination, last_command_exit_status, last_command_failed, last_command_status_unknown, launch_failed, unexpected_exit, last_command_text
        FROM sessions WHERE ended_at IS NULL ORDER BY started_at ASC;
        """) { Self.session(from: $0) }
    }

    private static func session(from row: Row) -> SessionRecord {
        SessionRecord(
            id: row.string(0),
            kind: SessionKind(rawValue: row.string(1)) ?? .temp,
            ownerId: row.string(2),
            title: row.string(3),
            shell: row.string(4),
            workingDirectory: row.optionalString(5),
            startedAt: row.date(6),
            endedAt: row.optionalDate(7),
            termination: row.optionalString(8).flatMap(TerminationReason.init(rawValue:)),
            lastCommandExitStatus: row.optionalInt32(9),
            lastCommandFailed: row.bool(10),
            lastCommandStatusUnknown: row.bool(11),
            launchFailed: row.bool(12),
            unexpectedExit: row.bool(13),
            lastCommandText: row.optionalString(14)
        )
    }

    public func deleteSession(id: String) throws {
        try database.transaction {
            try deleteEvents(sessionId: id)
            try database.run("DELETE FROM sessions WHERE id = ?;", [.text(id)])
        }
    }

    // MARK: - Events

    public func append(_ events: [SessionEvent]) throws {
        guard !events.isEmpty else { return }
        try database.transaction {
            for event in events {
                try database.run("""
                INSERT OR REPLACE INTO session_events (session_id, sequence, timestamp, kind, data, cols, rows)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """, [
                    .text(event.sessionId),
                    .integer(event.sequence),
                    .date(event.timestamp),
                    .text(event.kind.rawValue),
                    .blob(event.data),
                    .integer(Int64(event.cols)),
                    .integer(Int64(event.rows)),
                ])
            }
        }
    }

    public func events(sessionId: String) throws -> [SessionEvent] {
        try database.query("""
        SELECT session_id, sequence, timestamp, kind, data, cols, rows
        FROM session_events WHERE session_id = ? ORDER BY sequence ASC;
        """, [.text(sessionId)]) { Self.event(from: $0) }
    }

    /// One page of a session's recorded events, for replaying large histories without
    /// holding every blob in memory at once. `afterSequence` is exclusive.
    public func events(sessionId: String, afterSequence: Int64, limit: Int) throws -> [SessionEvent] {
        guard limit > 0 else { return [] }
        return try database.query("""
        SELECT session_id, sequence, timestamp, kind, data, cols, rows
        FROM session_events WHERE session_id = ? AND sequence > ?
        ORDER BY sequence ASC LIMIT ?;
        """, [.text(sessionId), .integer(afterSequence), .integer(Int64(limit))]) { Self.event(from: $0) }
    }

    private static func event(from row: Row) -> SessionEvent {
        SessionEvent(
            sessionId: row.string(0),
            sequence: row.int(1),
            timestamp: row.date(2),
            kind: SessionEventKind(rawValue: row.string(3)) ?? .output,
            data: row.data(4),
            cols: Int(row.int(5)),
            rows: Int(row.int(6))
        )
    }

    public func nextSequence(sessionId: String) throws -> Int64 {
        let value = try database.query("SELECT COALESCE(MAX(sequence), -1) FROM session_events WHERE session_id = ?;", [.text(sessionId)]) { $0.int(0) }.first ?? -1
        return value + 1
    }

    private func deleteEvents(sessionId: String) throws {
        try database.run("DELETE FROM session_events WHERE session_id = ?;", [.text(sessionId)])
    }

    // MARK: - Retention

    /// Keeps the newest `limit` finished sessions for one card in either menu and
    /// deletes older ones together with their history. Running sessions are never trimmed.
    @discardableResult
    public func trimHistory(kind: SessionKind, ownerId: String, limit: Int = RetentionPolicy.sessionHistoryLimit) throws -> [String] {
        let finished = try sessions(kind: kind, ownerId: ownerId).filter { $0.isFinished }
        guard finished.count > limit else { return [] }
        let doomed = finished.dropFirst(limit)
        let ids = doomed.map(\.id)
        try database.transaction {
            for id in ids {
                try deleteEvents(sessionId: id)
                try database.run("DELETE FROM sessions WHERE id = ?;", [.text(id)])
            }
        }
        return ids
    }

    /// Applies the current retention rule to every owner already in the database, so an
    /// older installation drops from ten records to two on its next launch instead of
    /// waiting for each card to run again.
    @discardableResult
    public func trimAllHistory(limit: Int = RetentionPolicy.sessionHistoryLimit) throws -> [String] {
        // Session rows have no foreign key to the two card tables. A crash between deleting
        // a card and its sessions, or an old build's late finalization, could leave rows (and
        // blobs) that no card can ever show again. Remove them on the same startup pass.
        let orphanIDs = try database.query("""
        SELECT id FROM sessions WHERE
            (kind = 'preset' AND owner_id NOT IN (SELECT id FROM preset_cards))
            OR (kind = 'temp' AND owner_id NOT IN (SELECT id FROM temp_terminals));
        """) { $0.string(0) }
        var removed: [String] = []
        if !orphanIDs.isEmpty {
            try database.transaction {
                for id in orphanIDs {
                    try deleteEvents(sessionId: id)
                    try database.run("DELETE FROM sessions WHERE id = ?;", [.text(id)])
                }
            }
            removed += orphanIDs
        }
        let owners = try database.query("SELECT DISTINCT kind, owner_id FROM sessions;") { row in
            (kind: SessionKind(rawValue: row.string(0)) ?? .temp, ownerId: row.string(1))
        }
        for owner in owners {
            // A session that survived reconciliation may still be running (for example
            // when this helper is called later). Count it as the current record.
            let records = try sessions(kind: owner.kind, ownerId: owner.ownerId)
            let finishedLimit = records.contains { !$0.isFinished } ? max(0, limit - 1) : limit
            removed += try trimHistory(kind: owner.kind, ownerId: owner.ownerId, limit: finishedLimit)
        }
        return removed
    }

    /// Deletes history of every finished session, leaving running sessions untouched.
    @discardableResult
    public func clearFinishedHistory() throws -> Int64 {
        let finished = try database.query("SELECT id FROM sessions WHERE ended_at IS NOT NULL;") { $0.string(0) }
        guard !finished.isEmpty else { return 0 }
        let freed = try database.query("SELECT COALESCE(SUM(LENGTH(data)), 0) FROM session_events WHERE session_id IN (SELECT id FROM sessions WHERE ended_at IS NOT NULL);") { $0.int(0) }.first ?? 0
        try database.transaction {
            for id in finished {
                try deleteEvents(sessionId: id)
                try database.run("DELETE FROM sessions WHERE id = ?;", [.text(id)])
            }
        }
        return freed
    }

    public func historyUsage() throws -> HistoryUsage {
        let bytes = try database.query("SELECT COALESCE(SUM(LENGTH(data)), 0) FROM session_events;") { $0.int(0) }.first ?? 0
        let finished = try database.query("SELECT COUNT(*) FROM sessions WHERE ended_at IS NOT NULL;") { $0.int(0) }.first ?? 0
        let running = try database.query("SELECT COUNT(*) FROM sessions WHERE ended_at IS NULL;") { $0.int(0) }.first ?? 0
        return HistoryUsage(eventBytes: bytes, finishedSessions: Int(finished), runningSessions: Int(running))
    }

    /// Size of the database files on disk, separate from history event payload bytes.
    public func diskUsageBytes() -> Int64 {
        database.checkpoint()
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let path = database.filePath + suffix
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path), let size = attributes[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }
}

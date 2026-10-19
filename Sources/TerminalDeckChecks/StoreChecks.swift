import Foundation
import TerminalDeckKit

func registerStoreChecks() {
    register("store.creates-schema") {
        let (store, root) = try makeStore("store-schema")
        defer { TempSpace.clean(root) }

        try expect(FileManager.default.fileExists(atPath: store.database.filePath), "database file must exist")
        try expectEqual(try store.cards(), [], "cards start empty")
        try expectEqual(try store.temps(), [], "temps start empty")
        try expectEqual(try store.unfinishedSessions(), [], "no unfinished sessions")
        let usage = try store.historyUsage()
        try expectEqual(usage.eventBytes, 0, "initial event bytes")
        try expectEqual(usage.finishedSessions, 0, "initial finished sessions")
        try expectEqual(usage.runningSessions, 0, "initial running sessions")
        // Settings table is part of the schema.
        try store.setString("dark", forKey: "appearance")
        try expectEqual(try store.string(forKey: "appearance"), "dark", "settings round trip")
        // The database must record the version the Kit declares (not a hardcoded number).
        let recordedVersion = try store.database.query("SELECT version FROM schema_version LIMIT 1;") { $0.int(0) }.first
        try expectEqual(recordedVersion, TerminalDeckStore.schemaVersion, "recorded schema version")
    }

    register("store.migrates-legacy-support-directory") {
        let base = try TempSpace.make("store-legacy-support")
        defer { TempSpace.clean(base) }

        // A pre-rename store with real data must move to the RunBo folder intact.
        let legacy = base.appendingPathComponent(DeckPaths.legacyFolderName, isDirectory: true)
        do {
            let store = try TerminalDeckStore(directory: legacy)
            try store.save(PresetCard(
                id: "legacy-card",
                title: "Legacy",
                command: "echo legacy",
                createdAt: Date(timeIntervalSince1970: 1_800_700_000),
                updatedAt: Date(timeIntervalSince1970: 1_800_700_000)
            ))
        }
        let migrated = DeckPaths.migrateLegacySupportDirectoryIfNeeded(in: base)
        try expectEqual(migrated.lastPathComponent, DeckPaths.folderName, "legacy support folder migrates to the new name")
        try expect(!FileManager.default.fileExists(atPath: legacy.path), "the old support folder is not left behind")
        try expectEqual(try TerminalDeckStore(directory: migrated).cards().map(\.id), ["legacy-card"], "cards survive the rename")

        // An existing RunBo folder always wins; the old folder is never merged or deleted.
        let source = base.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try TempSpace.write("legacy", to: source.appendingPathComponent("marker"))
        let old = base.appendingPathComponent(DeckPaths.legacyFolderName, isDirectory: true)
        try FileManager.default.moveItem(at: source, to: old)
        let current = base.appendingPathComponent(DeckPaths.folderName, isDirectory: true)
        try TempSpace.write("current", to: current.appendingPathComponent("marker"))
        let kept = DeckPaths.migrateLegacySupportDirectoryIfNeeded(in: base)
        try expectEqual(kept.path, current.path, "an existing new folder is kept as-is")
        try expectEqual(try String(contentsOf: current.appendingPathComponent("marker"), encoding: .utf8), "current", "the new folder is untouched")
        try expectEqual(try String(contentsOf: old.appendingPathComponent("marker"), encoding: .utf8), "legacy", "the old folder is left for manual recovery")

        // With neither folder present the default location is prepared, not an error.
        let empty = base.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let fresh = DeckPaths.migrateLegacySupportDirectoryIfNeeded(in: empty)
        try expectEqual(fresh.path, empty.appendingPathComponent(DeckPaths.folderName).path, "a fresh install resolves to the new folder")
    }

    register("store.fresh-directory-schema") {
        let root = try TempSpace.make("store-fresh-schema")
        defer { TempSpace.clean(root) }
        let expectedTables = ["preset_cards", "schema_version", "session_events", "sessions", "settings", "tags", "temp_terminals"]

        let versionAfterFirstOpen: Int64?
        do {
            let store = try TerminalDeckStore(directory: root)
            versionAfterFirstOpen = try storeSchemaVersion(store)
            try expectEqual(versionAfterFirstOpen, TerminalDeckStore.schemaVersion, "a fresh store records the current schema version")
            try expectEqual(try storeTableNames(store).sorted(), expectedTables, "every expected table is created")
            try expectSessionColumns(store, "fresh schema")
            try expectEqual(try storeColumns(store, table: "session_events").contains("data"), true, "session_events stores blobs")
            try expect(try storeColumns(store, table: "sessions").contains("last_command_status_unknown"), "fresh schema carries the v2 column")
            // The freshly created schema is usable through the public API.
            try store.save(PresetCard(
                id: "fresh-card",
                title: "Fresh",
                command: "echo fresh",
                createdAt: Date(timeIntervalSince1970: 1_800_600_000),
                updatedAt: Date(timeIntervalSince1970: 1_800_600_000)
            ))
            try store.append([SessionEvent(sessionId: "fresh-session", sequence: 0, kind: .output, data: Data([0x46]))])
        }

        // Re-opening an already-current database must not re-run migrations.
        let reopened = try TerminalDeckStore(directory: root)
        try expectEqual(try storeSchemaVersion(reopened), versionAfterFirstOpen, "reopening keeps the recorded schema version")
        try expectEqual(try storeSchemaVersion(reopened), TerminalDeckStore.schemaVersion, "reopening stays at the current schema version")
        try expectEqual(try storeTableNames(reopened).sorted(), expectedTables, "tables survive reopening")
        try expectSessionColumns(reopened, "reopened schema")
        try expectEqual(try reopened.cards().map(\.id), ["fresh-card"], "rows written before reopening are still readable")
        try expectEqual(try reopened.events(sessionId: "fresh-session").count, 1, "events written before reopening are still readable")
        try reopened.save(PresetCard(
            id: "fresh-card-2",
            title: "Fresh 2",
            command: "echo fresh2",
            createdAt: Date(timeIntervalSince1970: 1_800_600_100),
            updatedAt: Date(timeIntervalSince1970: 1_800_600_100)
        ))
        try expectEqual(try reopened.cards().map(\.id).sorted(), ["fresh-card", "fresh-card-2"], "the reopened store accepts writes")
    }

    register("store.migrates-v1-database") {
        let root = try TempSpace.make("store-v1-migration")
        defer { TempSpace.clean(root) }
        let databaseURL = DeckPaths.databaseURL(in: root)

        // Hand-build a v1-shaped database through the public `Database` API: the historical
        // DDL has no `last_command_status_unknown` column and stamps schema_version = 1.
        do {
            let database = try Database(path: databaseURL.path)
            try database.execute("""
            CREATE TABLE schema_version (
                version INTEGER NOT NULL
            );
            CREATE TABLE preset_cards (
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
            CREATE TABLE temp_terminals (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_activity_at REAL NOT NULL
            );
            CREATE TABLE sessions (
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
            CREATE INDEX sessions_owner ON sessions (kind, owner_id, started_at DESC);
            CREATE TABLE session_events (
                session_id TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                kind TEXT NOT NULL,
                data BLOB,
                cols INTEGER NOT NULL DEFAULT 0,
                rows INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (session_id, sequence)
            ) WITHOUT ROWID;
            CREATE TABLE settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
            try database.run("INSERT INTO schema_version (version) VALUES (1);")
            try database.run("""
            INSERT INTO preset_cards (id, title, command, shell_override, working_directory, environment, auto_run, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .text("v1-card"), .text("V1 card"), .text("echo v1"), .null, .null,
                .text("A=1"), .integer(1), .real(1_800_700_000), .real(1_800_700_000),
            ])
            // launch_failed and unexpected_exit are both 1, and last_command_text is not
            // numeric: any column-index slip introduced by the new column shows up here.
            try database.run("""
            INSERT INTO sessions (id, kind, owner_id, title, shell, working_directory, started_at, ended_at, termination, last_command_exit_status, last_command_failed, launch_failed, unexpected_exit, last_command_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [
                .text("v1-session"), .text("preset"), .text("v1-card"), .text("V1 card"), .text("/bin/zsh"),
                .null, .real(1_800_700_100), .real(1_800_700_200), .text("exited"),
                .integer(0), .integer(0), .integer(1), .integer(1), .text("echo v1"),
            ])
            try database.run("INSERT INTO session_events (session_id, sequence, timestamp, kind, data, cols, rows) VALUES (?, ?, ?, ?, ?, ?, ?);", [
                .text("v1-session"), .integer(0), .real(1_800_700_110), .text("output"), .blob(Data([0x68, 0x69])), .integer(0), .integer(0),
            ])
            try database.run("INSERT INTO session_events (session_id, sequence, timestamp, kind, data, cols, rows) VALUES (?, ?, ?, ?, ?, ?, ?);", [
                .text("v1-session"), .integer(1), .real(1_800_700_120), .text("resize"), .blob(Data()), .integer(100), .integer(40),
            ])
        } // the raw connection closes here

        // Opening it must migrate it (v1 -> current) without losing anything.
        let store = try TerminalDeckStore(directory: root)
        try expectEqual(try storeSchemaVersion(store), TerminalDeckStore.schemaVersion, "opening a v1 database bumps schema_version")
        try expectSessionColumns(store, "migrated schema")

        let expectedCard = PresetCard(
            id: "v1-card",
            title: "V1 card",
            command: "echo v1",
            environment: ["A": "1"],
            autoRun: true,
            createdAt: Date(timeIntervalSince1970: 1_800_700_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_700_000)
        )
        try expectEqual(try store.cards(), [expectedCard], "the v1 card survives migration")

        let expectedSession = SessionRecord(
            id: "v1-session",
            kind: .preset,
            ownerId: "v1-card",
            title: "V1 card",
            shell: "/bin/zsh",
            workingDirectory: nil,
            startedAt: Date(timeIntervalSince1970: 1_800_700_100),
            endedAt: Date(timeIntervalSince1970: 1_800_700_200),
            termination: .exited,
            lastCommandExitStatus: 0,
            lastCommandFailed: false,
            lastCommandStatusUnknown: false,
            launchFailed: true,
            unexpectedExit: true,
            lastCommandText: "echo v1"
        )
        try expectEqual(try store.session(id: "v1-session"), expectedSession, "the v1 session survives migration with every field")
        try expectEqual(try store.session(id: "v1-session")?.unexpectedExit, true, "unexpectedExit is not shifted by the new column")
        try expectEqual(try store.session(id: "v1-session")?.launchFailed, true, "launchFailed is not shifted by the new column")
        try expectEqual(try store.session(id: "v1-session")?.lastCommandText, "echo v1", "lastCommandText is not shifted by the new column")
        try expectEqual(try store.session(id: "v1-session")?.lastCommandStatusUnknown, false, "the migrated column defaults to false")
        let migratedEvents = try store.events(sessionId: "v1-session")
        try expectEqual(migratedEvents.count, 2, "the v1 events survive migration")
        try expectEqual(Array(migratedEvents[0].data), [0x68, 0x69], "the v1 event payload survives byte for byte")
        try expectEqual(migratedEvents[1].cols, 100, "the v1 resize event survives")

        // Writes keep working after the migration, including the freshly added column.
        var updated = expectedSession
        updated.endedAt = Date(timeIntervalSince1970: 1_800_700_300)
        updated.lastCommandStatusUnknown = true
        updated.unexpectedExit = false
        try store.save(updated)
        try expectEqual(try store.session(id: "v1-session")?.lastCommandStatusUnknown, true, "the migrated column is writable")
        try expectEqual(try store.session(id: "v1-session")?.unexpectedExit, false, "the migrated column write does not disturb unexpectedExit")
        try expectEqual(try store.session(id: "v1-session")?.endedAt, Date(timeIntervalSince1970: 1_800_700_300), "the updated endedAt round trips")
        try store.save(PresetCard(id: "v1-card-2", title: "Added", command: "echo added"))
        try expectEqual(try store.cards().map(\.id).sorted(), ["v1-card", "v1-card-2"], "cards are writable after migration")
    }

    register("store.preset-card-round-trip") {
        let (store, root) = try makeStore("store-card")
        defer { TempSpace.clean(root) }

        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = created.addingTimeInterval(3600)
        let card = PresetCard(
            id: "card-1",
            title: "Deploy",
            command: "echo hello",
            shellOverride: "bash",
            workingDirectory: "/tmp",
            environment: ["FOO": "bar", "EMBEDDED": "a=b", "EMPTY": "", "HASH": "#x"],
            autoRun: true,
            createdAt: created,
            updatedAt: updated
        )
        try store.save(card)
        var loaded = try store.cards()
        try expectEqual(loaded.count, 1, "one card saved")
        try expectEqual(loaded.first, card, "preset card round trip (environment + autoRun included)")
        try expectEqual(loaded.first?.environment["EMBEDDED"], "a=b", "embedded = survives the JSON-free encoding")
        try expectEqual(loaded.first?.autoRun, true, "autoRun")

        // Saving again updates in place, it does not duplicate.
        var edited = card
        edited.title = "Deploy v2"
        edited.autoRun = false
        edited.environment = ["ONLY": "one"]
        edited.updatedAt = updated.addingTimeInterval(60)
        try store.save(edited)
        loaded = try store.cards()
        try expectEqual(loaded.count, 1, "update must not insert a second row")
        try expectEqual(loaded.first, edited, "updated card round trip")
    }

    register("store.temp-terminal-round-trip") {
        let (store, root) = try makeStore("store-temp")
        defer { TempSpace.clean(root) }

        let created = Date(timeIntervalSince1970: 1_700_100_000)
        let activity = created.addingTimeInterval(120)
        let temp = TempTerminal(id: "temp-1", title: "Scratch", createdAt: created, lastActivityAt: activity)
        try store.save(temp)
        try expectEqual(try store.temps(), [temp], "temp terminal round trip")

        let touched = activity.addingTimeInterval(500)
        try store.touchTemp(id: "temp-1", at: touched)
        try expectEqual(try store.temps().first?.lastActivityAt, touched, "touchTemp updates the activity clock")
        try expectEqual(try store.temps().first?.title, "Scratch", "touchTemp keeps the title")
    }

    register("store.sessions-newest-first") {
        let (store, root) = try makeStore("store-order")
        defer { TempSpace.clean(root) }

        let base = Date(timeIntervalSince1970: 1_700_200_000)
        let records = [
            SessionRecord(id: "old", kind: .preset, ownerId: "card-1", title: "Old", shell: "/bin/zsh", startedAt: base),
            SessionRecord(id: "newest", kind: .preset, ownerId: "card-1", title: "Newest", shell: "/bin/zsh", startedAt: base.addingTimeInterval(200)),
            SessionRecord(id: "middle", kind: .preset, ownerId: "card-1", title: "Middle", shell: "/bin/zsh", startedAt: base.addingTimeInterval(100)),
            SessionRecord(id: "other-owner", kind: .preset, ownerId: "card-2", title: "Other", shell: "/bin/zsh", startedAt: base.addingTimeInterval(300)),
            SessionRecord(id: "temp-1", kind: .temp, ownerId: "card-1", title: "Temp", shell: "/bin/zsh", startedAt: base.addingTimeInterval(400)),
        ]
        for record in records { try store.save(record) }

        let listed = try store.sessions(kind: .preset, ownerId: "card-1")
        try expectEqual(listed.map(\.id), ["newest", "middle", "old"], "preset sessions newest first, other owners excluded")
        // Full field equality also covers the `unexpected_exit` / `last_command_text` columns.
        try expectEqual(listed, [records[1], records[2], records[0]], "sessions(kind:ownerId:) round trips every field")
        try expectEqual(try store.latestSession(kind: .preset, ownerId: "card-1")?.id, "newest", "latestSession")
        try expectEqual(try store.session(id: "middle")?.id, "middle", "session(id:)")
        try expectEqual(try store.sessions(kind: .temp, ownerId: "card-1").map(\.id), ["temp-1"], "temp sessions")
        try expectEqual(try store.unfinishedSessions().map(\.id), ["old", "middle", "newest", "other-owner", "temp-1"], "unfinished sessions oldest first")
    }

    register("store.session-record-round-trip") {
        let (store, root) = try makeStore("store-session-round-trip")
        defer { TempSpace.clean(root) }

        let base = Date(timeIntervalSince1970: 1_700_250_000)
        // A clean-ish finished session that ended unexpectedly: every flag must survive.
        let finished = SessionRecord(
            id: "finished-boom",
            kind: .preset,
            ownerId: "card-rt",
            title: "Boom",
            shell: "/bin/zsh",
            workingDirectory: "/tmp",
            startedAt: base,
            endedAt: base.addingTimeInterval(10),
            termination: .exited,
            lastCommandExitStatus: 3,
            lastCommandFailed: true,
            launchFailed: true,
            unexpectedExit: true,
            lastCommandText: "echo boom"
        )
        // The regression case for the old column-offset bug: `lastCommandText` is exactly
        // "1", so decoding `unexpectedExit` from the text column would read `true`.
        let running = SessionRecord(
            id: "running-numeric-text",
            kind: .preset,
            ownerId: "card-rt",
            title: "Numeric",
            shell: "/bin/zsh",
            workingDirectory: nil,
            startedAt: base.addingTimeInterval(50),
            endedAt: nil,
            termination: nil,
            lastCommandExitStatus: nil,
            lastCommandFailed: false,
            launchFailed: false,
            unexpectedExit: false,
            lastCommandText: "1"
        )
        // The v2 "command result unknown" marker must round trip independently of the other
        // flags: a column-offset slip would read it from `launch_failed` (false here) while
        // pushing `launchFailed`/`unexpectedExit`/`lastCommandText` out of place.
        let statusUnknown = SessionRecord(
            id: "status-unknown",
            kind: .temp,
            ownerId: "temp-rt",
            title: "Unknown status",
            shell: "/bin/zsh",
            workingDirectory: nil,
            startedAt: base.addingTimeInterval(80),
            endedAt: base.addingTimeInterval(90),
            termination: .exited,
            lastCommandExitStatus: nil,
            lastCommandFailed: false,
            lastCommandStatusUnknown: true,
            launchFailed: false,
            unexpectedExit: false,
            lastCommandText: "echo unknown"
        )
        try store.save(finished)
        try store.save(running)
        try store.save(statusUnknown)

        // Full `==` is safe here because every seeded date is a whole epoch second, which a
        // `timeIntervalSince1970` round trip preserves exactly. Live-clock dates (`Date()`)
        // must not be compared that way — see `differingSessionFields`.
        try expectEqual(try store.session(id: "finished-boom"), finished, "session(id:) round trips a finished, unexpected-exit record")
        try expectEqual(try store.session(id: "running-numeric-text"), running, "session(id:) round trips a running record whose lastCommandText is \"1\"")
        try expectEqual(try store.session(id: "status-unknown"), statusUnknown, "session(id:) round trips the command-status-unknown marker")
        try expectEqual(try store.session(id: "status-unknown")?.lastCommandStatusUnknown, true, "lastCommandStatusUnknown survives")
        try expectEqual(try store.session(id: "status-unknown")?.launchFailed, false, "launchFailed must not be read from the status-unknown column")
        try expectEqual(try store.session(id: "status-unknown")?.unexpectedExit, false, "unexpectedExit must not be shifted by the new column")
        try expectEqual(try store.session(id: "status-unknown")?.lastCommandText, "echo unknown", "lastCommandText must not fall off the end of the SELECT")
        try expectEqual(try store.session(id: "finished-boom")?.unexpectedExit, true, "unexpectedExit == true survives")
        try expectEqual(try store.session(id: "running-numeric-text")?.unexpectedExit, false, "unexpectedExit must not be read from lastCommandText")
        try expectEqual(try store.session(id: "running-numeric-text")?.lastCommandText, "1", "lastCommandText survives verbatim")
        try expectEqual(try store.session(id: "finished-boom")?.launchFailed, true, "launchFailed survives")
        try expectEqual(try store.session(id: "finished-boom")?.termination, .exited, "termination survives")
        try expectEqual(try store.session(id: "finished-boom")?.endedAt, base.addingTimeInterval(10), "endedAt survives")
        try expectEqual(try store.session(id: "finished-boom")?.lastCommandExitStatus, 3, "lastCommandExitStatus survives")
        try expectEqual(try store.session(id: "finished-boom")?.workingDirectory, "/tmp", "workingDirectory survives")

        try expectEqual(try store.sessions(kind: .preset, ownerId: "card-rt"), [running, finished], "sessions() returns newest first with every field")
        try expectEqual(try store.unfinishedSessions(), [running], "unfinishedSessions() returns only the open session, with every field")
        try expectEqual(try store.latestSession(kind: .preset, ownerId: "card-rt"), running, "latestSession matches")

        // Updating the open session closes it and moves it out of unfinishedSessions().
        var closed = running
        closed.endedAt = base.addingTimeInterval(120)
        closed.termination = .normal
        try store.save(closed)
        try expectEqual(try store.unfinishedSessions(), [], "closed session leaves unfinishedSessions()")
        try expectEqual(try store.session(id: "running-numeric-text")?.endedAt, base.addingTimeInterval(120), "update writes endedAt")
        try expectEqual(try store.session(id: "running-numeric-text")?.termination, .normal, "update writes termination")
    }

    register("store.session-insert-is-visible") {
        let (store, root) = try makeStore("store-session-visibility")
        defer { TempSpace.clean(root) }

        let base = Date(timeIntervalSince1970: 1_700_260_000)
        let record = SessionRecord(
            id: "visible",
            kind: .preset,
            ownerId: "card-visible",
            title: "Visible",
            shell: "/bin/zsh",
            startedAt: base,
            lastCommandText: "echo visible"
        )
        try store.save(record)

        // A silently dropped INSERT (e.g. the old 13-placeholder statement) would fail here.
        try expectEqual(try store.session(id: "visible"), record, "a saved session must be readable by id")
        try expectEqual(try store.unfinishedSessions(), [record], "a saved session must appear in unfinishedSessions()")
        try expectEqual(try store.sessions(kind: .preset, ownerId: "card-visible"), [record], "a saved session must appear in sessions(kind:ownerId:)")
        try expect(store.session(id: "missing") == nil, "unknown session ids read back as nil")

        // Closing the session must also be visible: an insert failure cannot pass silently.
        var closed = record
        closed.endedAt = base.addingTimeInterval(30)
        closed.termination = .normal
        closed.unexpectedExit = false
        try store.save(closed)
        try expectEqual(try store.session(id: "visible"), closed, "the update is visible by id")
        try expectEqual(try store.unfinishedSessions(), [], "the closed session is gone from unfinishedSessions()")
    }

    register("store.events-round-trip") {
        let (store, root) = try makeStore("store-events")
        defer { TempSpace.clean(root) }

        let sessionId = "session-events"
        try expectEqual(try store.nextSequence(sessionId: sessionId), 0, "first sequence is 0")
        let payload: [UInt8] = [0x00, 0x01, 0x1B, 0x5B, 0x1F, 0xFF, 0x0A, 0x07]
        let events = [
            SessionEvent(sessionId: sessionId, sequence: 0, timestamp: Date(timeIntervalSince1970: 1_700_300_000), kind: .output, data: Data(payload)),
            SessionEvent(sessionId: sessionId, sequence: 1, timestamp: Date(timeIntervalSince1970: 1_700_300_001), kind: .resize, cols: 120, rows: 42),
            SessionEvent(sessionId: sessionId, sequence: 2, timestamp: Date(timeIntervalSince1970: 1_700_300_002), kind: .output, data: Data([0x41, 0x42])),
        ]
        try store.append(events)
        try expectEqual(try store.events(sessionId: sessionId), events, "events round trip (bytes, order, sizes)")
        try expectEqual(try store.nextSequence(sessionId: sessionId), 3, "nextSequence advances")

        // Appending again continues in order and never rewrites earlier bytes.
        try store.append([SessionEvent(sessionId: sessionId, sequence: 3, timestamp: Date(timeIntervalSince1970: 1_700_300_003), kind: .output, data: Data([0x43]))])
        let all = try store.events(sessionId: sessionId)
        try expectEqual(all.map(\.sequence), [0, 1, 2, 3], "sequence order preserved")
        try expectEqual(Array(all[0].data), payload, "first event bytes preserved")
        try expectEqual(try store.nextSequence(sessionId: sessionId), 4, "nextSequence after second append")

        // A different session has its own sequence space.
        try expectEqual(try store.nextSequence(sessionId: "other"), 0, "sequence spaces are per session")
        try expectEqual(try store.events(sessionId: "other"), [], "no events for an unknown session")
    }

    register("store.history-usage-and-clear") {
        let (store, root) = try makeStore("store-usage")
        defer { TempSpace.clean(root) }

        let base = Date(timeIntervalSince1970: 1_700_400_000)
        try store.save(SessionRecord(id: "done", kind: .preset, ownerId: "card-1", title: "Done", shell: "/bin/zsh", startedAt: base, endedAt: base.addingTimeInterval(10), termination: .normal))
        try store.save(SessionRecord(id: "live", kind: .preset, ownerId: "card-1", title: "Live", shell: "/bin/zsh", startedAt: base))
        try store.append([
            SessionEvent(sessionId: "done", sequence: 0, kind: .output, data: Data(repeating: 0x61, count: 8)),
            SessionEvent(sessionId: "done", sequence: 1, kind: .resize, cols: 80, rows: 24),
            SessionEvent(sessionId: "live", sequence: 0, kind: .output, data: Data(repeating: 0x62, count: 5)),
        ])

        let usage = try store.historyUsage()
        try expectEqual(usage.eventBytes, 13, "historyUsage sums event byte counts")
        try expectEqual(usage.finishedSessions, 1, "finished session count")
        try expectEqual(usage.runningSessions, 1, "running session count")

        let freed = try store.clearFinishedHistory()
        try expectEqual(freed, 8, "clearFinishedHistory reports freed bytes")
        try expectEqual(try store.events(sessionId: "done"), [], "finished history deleted")
        try expectEqual(try store.events(sessionId: "live").count, 1, "running history kept")
        let after = try store.historyUsage()
        try expectEqual(after.eventBytes, 5, "usage after clearing")
        try expectEqual(after.finishedSessions, 0, "finished count after clearing")
        try expectEqual(after.runningSessions, 1, "running count after clearing")
    }

    register("store.delete-card-cascades") {
        let (store, root) = try makeStore("store-delete-card")
        defer { TempSpace.clean(root) }

        let card = PresetCard(id: "card-del", title: "Delete me", command: "echo byebye")
        try store.save(card)
        let base = Date(timeIntervalSince1970: 1_700_500_000)
        try store.save(SessionRecord(id: "s1", kind: .preset, ownerId: "card-del", title: card.title, shell: "/bin/zsh", startedAt: base, endedAt: base.addingTimeInterval(1), termination: .normal))
        try store.save(SessionRecord(id: "s2", kind: .preset, ownerId: "card-del", title: card.title, shell: "/bin/zsh", startedAt: base.addingTimeInterval(5)))
        // A different card's session must survive.
        try store.save(SessionRecord(id: "keep", kind: .preset, ownerId: "card-keep", title: "Keep", shell: "/bin/zsh", startedAt: base))
        try store.append([
            SessionEvent(sessionId: "s1", sequence: 0, kind: .output, data: Data([0x31])),
            SessionEvent(sessionId: "s2", sequence: 0, kind: .output, data: Data([0x32])),
            SessionEvent(sessionId: "keep", sequence: 0, kind: .output, data: Data([0x33])),
        ])

        try store.deleteCard(id: "card-del")
        try expectEqual(try store.cards(), [], "card removed")
        try expectEqual(try store.sessions(kind: .preset, ownerId: "card-del"), [], "card sessions removed")
        try expectEqual(try store.events(sessionId: "s1"), [], "session s1 events removed")
        try expectEqual(try store.events(sessionId: "s2"), [], "session s2 events removed")
        try expectEqual(try store.events(sessionId: "keep").count, 1, "unrelated card history kept")
        try expectEqual(try store.sessions(kind: .preset, ownerId: "card-keep").count, 1, "unrelated card session kept")
    }

    register("store.delete-temp-cascades") {
        let (store, root) = try makeStore("store-delete-temp")
        defer { TempSpace.clean(root) }

        let temp = TempTerminal(id: "temp-del", title: "Scratch")
        try store.save(temp)
        let base = Date(timeIntervalSince1970: 1_700_600_000)
        try store.save(SessionRecord(id: "ts1", kind: .temp, ownerId: "temp-del", title: temp.title, shell: "/bin/zsh", startedAt: base))
        try store.append([SessionEvent(sessionId: "ts1", sequence: 0, kind: .output, data: Data([0x7A]))])

        try store.deleteTemp(id: "temp-del")
        try expectEqual(try store.temps(), [], "temp removed")
        try expectEqual(try store.sessions(kind: .temp, ownerId: "temp-del"), [], "temp sessions removed")
        try expectEqual(try store.events(sessionId: "ts1"), [], "temp events removed")
    }

    register("store.delete-session-cascades") {
        let (store, root) = try makeStore("store-delete-session")
        defer { TempSpace.clean(root) }

        let base = Date(timeIntervalSince1970: 1_700_700_000)
        try store.save(SessionRecord(id: "only", kind: .preset, ownerId: "card-x", title: "Only", shell: "/bin/zsh", startedAt: base))
        try store.append([SessionEvent(sessionId: "only", sequence: 0, kind: .output, data: Data([0x6F]))])
        try store.deleteSession(id: "only")
        try expect(store.sessionRowMissing("only"), "session row removed")
        try expectEqual(try store.events(sessionId: "only"), [], "session events removed")
    }

    register("store.write-failure-is-reported") {
        let (store, root) = try makeStore("store-write-failure")
        // `root` is the store directory itself; restore permissions before anything tries to
        // clean it up (defers run last-in-first-out, so the restore below runs first).
        defer { TempSpace.clean(root) }

        // Seeded rows that must survive the outage. Whole-second dates keep `==` exact (see
        // `differingSessionFields` for why live-clock dates would not).
        let card = PresetCard(
            id: "wf-card",
            title: "Write failure",
            command: "echo wf",
            shellOverride: nil,
            workingDirectory: nil,
            environment: ["A": "1"],
            autoRun: true,
            createdAt: Date(timeIntervalSince1970: 1_800_500_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_500_000)
        )
        try store.save(card)
        let temp = TempTerminal(
            id: "wf-temp",
            title: "Write failure temp",
            createdAt: Date(timeIntervalSince1970: 1_800_500_000),
            lastActivityAt: Date(timeIntervalSince1970: 1_800_500_000)
        )
        try store.save(temp)
        let sessionId = "wf-session"
        let seededEvent = SessionEvent(
            sessionId: sessionId,
            sequence: 0,
            timestamp: Date(timeIntervalSince1970: 1_800_500_100),
            kind: .output,
            data: Data([0x41, 0x00, 0xFF])
        )
        try store.append([seededEvent])

        let injection = try injectStoreWriteFailure(store, directory: root)
        defer { injection.restore() }

        // Probe first: if the injection had no effect, skip instead of reporting a false PASS.
        // The probe must be a *real* modification (a new row): an `ON CONFLICT DO UPDATE`
        // that writes identical values does not journal and therefore still succeeds in a
        // read-only directory.
        var writesBlocked = false
        var probeError = "none"
        do {
            try store.append([SessionEvent(sessionId: "wf-probe", sequence: 0, kind: .output, data: Data([0x50]))])
        } catch {
            writesBlocked = true
            probeError = "\(error)"
        }
        guard writesBlocked else {
            try skipCheck("write-failure injection had no effect here (\(injection.mechanism)): a real write still succeeds [probe=\(probeError)]")
        }

        // Every write must now fail. `save` is asserted with a *changed* card for the same
        // no-op-journaling reason as above.
        var changedCard = card
        changedCard.title = "Write failure (changed)"
        let saveError = try expectThrows("save(card) while the store is read-only") { try store.save(changedCard) }
        let appendError = try expectThrows("append(events) while the store is read-only") {
            try store.append([SessionEvent(sessionId: sessionId, sequence: 1, timestamp: Date(), kind: .output, data: Data([0x42]))])
        }
        let touchError = try expectThrows("touchTemp while the store is read-only") {
            try store.touchTemp(id: temp.id, at: Date(timeIntervalSince1970: 1_800_500_200))
        }
        try expect(looksLikeWriteFailure(saveError), "save failure should describe the disk problem, got: \(saveError)")
        try expect(looksLikeWriteFailure(appendError), "append failure should describe the disk problem, got: \(appendError)")
        try expect(looksLikeWriteFailure(touchError), "touchTemp failure should describe the disk problem, got: \(touchError)")

        // Restore, checkpoint, and a normal write must work again.
        injection.restore()
        _ = store.diskUsageBytes()
        let recovered = PresetCard(
            id: "wf-card-recovered",
            title: "Recovered",
            command: "echo ok",
            createdAt: Date(timeIntervalSince1970: 1_800_500_400),
            updatedAt: Date(timeIntervalSince1970: 1_800_500_400)
        )
        try store.save(recovered)
        try store.append([SessionEvent(
            sessionId: sessionId,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1_800_500_200),
            kind: .output,
            data: Data([0x42])
        )])
        try store.touchTemp(id: temp.id, at: Date(timeIntervalSince1970: 1_800_500_300))

        // Rows written before the outage are intact.
        try expectEqual(try store.cards().map(\.id).sorted(), ["wf-card", "wf-card-recovered"], "both cards are readable after recovery")
        try expectEqual(try store.cards().first { $0.id == "wf-card" }, card, "the pre-outage card round trips")
        try expectEqual(try store.events(sessionId: sessionId).first, seededEvent, "the pre-outage event survives byte for byte")
        try expectEqual(try store.events(sessionId: sessionId).count, 2, "the post-recovery event was appended")
        try expectEqual(try store.temps().count, 1, "the temp row survives")
        try expectEqual(try store.temps().first?.lastActivityAt, Date(timeIntervalSince1970: 1_800_500_300), "touchTemp works after recovery")
        try expectEqual(try store.temps().first?.title, temp.title, "the surviving temp row kept its title")
    }
}

private extension TerminalDeckStore {
    /// Convenience used by a check: the row must be gone.
    func sessionRowMissing(_ id: String) -> Bool {
        (try? database.query("SELECT 1 FROM sessions WHERE id = ?;", [.text(id)]) { $0.int(0) }.isEmpty) ?? false
    }
}

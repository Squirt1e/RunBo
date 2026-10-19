import Foundation
import Core

/// Stand-in for a card: the grouping rules only ever read an id and a tag reference, so the
/// checks exercise them without constructing real cards or touching a store.
private struct GroupedRow: Equatable {
    let id: String
    let tagId: String?
}

func registerCardTagChecks() {
    // MARK: - Naming rules

    register("tags.normalizes-names") {
        try expectEqual(TagVocabulary.normalized("  工作  "), "工作", "leading and trailing space is trimmed")
        try expectEqual(TagVocabulary.normalized("工作   组"), "工作 组", "runs of whitespace collapse to one space")
        try expectEqual(TagVocabulary.normalized("工作\t组"), "工作 组", "a tab counts as whitespace")
        try expectEqual(TagVocabulary.normalized("   "), "", "whitespace-only normalizes to empty")

        // Matching is deliberately looser than normalization: case, width and inner spaces
        // must all land on the same tag, otherwise the vocabulary grows look-alike blocks.
        try expectEqual(TagVocabulary.matchKey("工作"), TagVocabulary.matchKey(" 工作 "), "surrounding space does not change the key")
        try expectEqual(TagVocabulary.matchKey("工作 组"), TagVocabulary.matchKey("工作组"), "inner space does not change the key")
        try expectEqual(TagVocabulary.matchKey("Work"), TagVocabulary.matchKey("work"), "case does not change the key")
        try expectEqual(TagVocabulary.matchKey("ＷＯＲＫ"), TagVocabulary.matchKey("work"), "full width does not change the key")
        try expect(TagVocabulary.matchKey("工作") != TagVocabulary.matchKey("工作组"), "different names keep different keys")
        try expectEqual(TagVocabulary.matchKey("   "), "", "a blank name has an empty key")
    }

    register("tags.reuses-existing-name") {
        let tags = [
            CardTag(id: "t1", name: "工作", sortOrder: 0),
            CardTag(id: "t2", name: "数据库", sortOrder: 1),
        ]
        try expectEqual(TagVocabulary.match(" 工作 ", in: tags)?.id, "t1", "a padded name finds the existing tag")
        try expectEqual(TagVocabulary.match("工作", in: tags)?.id, "t1", "a look-alike name finds the existing tag")
        try expectEqual(TagVocabulary.match("work", in: tags)?.id, nil, "an unrelated name matches nothing")
        try expectEqual(TagVocabulary.match("   ", in: tags)?.id, nil, "a blank name matches nothing")

        // Validation is what the rename path uses: same name, same tag = allowed.
        try expectEqual(try TagVocabulary.validate("工作", in: tags, excluding: "t1"), "工作", "a tag may keep its own name")
        let clash = try expectThrows("renaming t2 to t1's name") {
            try TagVocabulary.validate("工作", in: tags, excluding: "t2")
        }
        try expectEqual(clash as? TagNameError, .duplicate(existing: "工作"), "a clash reports the existing tag")
        let empty = try expectThrows("validating a blank name") {
            try TagVocabulary.validate("   ", in: tags)
        }
        try expectEqual(empty as? TagNameError, .empty, "a blank name is rejected as empty")
    }

    register("tags.order-is-dense-and-movable") {
        let tags = [
            CardTag(id: "a", name: "A", sortOrder: 0),
            CardTag(id: "b", name: "B", sortOrder: 1),
            CardTag(id: "c", name: "C", sortOrder: 2),
        ]
        try expectEqual(TagVocabulary.nextSortOrder(in: tags), 3, "a new tag goes after every existing one")
        try expectEqual(TagVocabulary.nextSortOrder(in: []), 0, "the first tag starts at zero")

        let moved = try expectUnwrap(TagVocabulary.moved(tags, id: "c", by: -1), "moving C up")
        try expectEqual(moved.map(\.id), ["a", "c", "b"], "C swapped with B")
        try expectEqual(moved.map(\.sortOrder), [0, 1, 2], "sort orders are renumbered densely")
        try expectEqual(TagVocabulary.moved(tags, id: "a", by: -1), nil, "the first tag cannot move up")
        try expectEqual(TagVocabulary.moved(tags, id: "c", by: 1), nil, "the last tag cannot move down")
        try expectEqual(TagVocabulary.moved(tags, id: "nope", by: 1), nil, "an unknown id moves nothing")
        let down = try expectUnwrap(TagVocabulary.moved(tags, id: "a", by: 2), "dragging A to the end")
        try expectEqual(down.map(\.id), ["b", "c", "a"], "crossed tags retain their order")
        let up = try expectUnwrap(TagVocabulary.moved(tags, id: "c", by: -2), "dragging C to the start")
        try expectEqual(up.map(\.id), ["c", "a", "b"], "dragging up inserts rather than swaps")
        try expectEqual(up.map(\.sortOrder), [0, 1, 2], "multi-row moves remain dense")
        try expectEqual(TagVocabulary.moved(tags, id: "b", by: 0), nil, "releasing in place is a no-op")
        try expectEqual(TagVocabulary.moved(tags, id: "a", by: 3), nil, "an out-of-range drag moves nothing")
    }

    register("tags.colour-is-stable-and-not-hasher-based") {
        // A colour must survive a relaunch, so it comes from a written-out FNV-1a over the
        // match key rather than Swift's per-process-seeded `Hasher`.
        try expectEqual(TagVocabulary.toneIndex(for: "工作"), TagVocabulary.toneIndex(for: " 工作 "), "padding does not change the tone")
        try expectEqual(TagVocabulary.toneIndex(for: "Work"), TagVocabulary.toneIndex(for: "work"), "case does not change the tone")
        for name in ["工作", "数据库", "运维", "日常", "稍后", "客户", "发布", "logs"] {
            let tone = TagVocabulary.toneIndex(for: name)
            try expect(tone >= 0 && tone < TagVocabulary.toneCount, "\(name) maps inside the palette, got \(tone)")
        }
        // Pinned: if someone swaps the hash the palette silently reshuffles for every user.
        try expectEqual(TagVocabulary.toneIndex(for: "工作"), 5, "工作 keeps its pinned tone")
        try expectEqual(TagVocabulary.toneIndex(for: "数据库"), 1, "数据库 keeps its pinned tone")
    }

    // MARK: - Grouping

    register("tags.groups-cards-and-keeps-untagged-last") {
        let tags = [
            CardTag(id: "t1", name: "工作", sortOrder: 0),
            CardTag(id: "t2", name: "数据库", sortOrder: 1),
            CardTag(id: "t3", name: "空标签", sortOrder: 2),
        ]
        let rows = [
            GroupedRow(id: "a", tagId: "t2"),
            GroupedRow(id: "b", tagId: nil),
            GroupedRow(id: "c", tagId: "t1"),
            GroupedRow(id: "d", tagId: "t2"),
            GroupedRow(id: "e", tagId: nil),
        ]
        let sections = CardGrouping.sections(items: rows, tags: tags, tagId: \.tagId)
        try expectEqual(sections.map(\.name), ["工作", "数据库", "未加标签"], "blocks follow vocabulary order, untagged last")
        try expectEqual(sections.map { $0.items.map(\.id) }, [["c"], ["a", "d"], ["b", "e"]], "order inside a block is preserved")
        try expectEqual(sections.last?.isUntagged, true, "the last block is the untagged one")
        try expectEqual(sections.first?.isUntagged, false, "a tagged block is not the untagged one")
        try expectEqual(sections.map(\.id), ["t1", "t2", ""], "the untagged block keys on an empty id")
    }

    register("tags.empty-blocks-are-hidden") {
        let tags = [CardTag(id: "t1", name: "工作", sortOrder: 0)]

        // No cards at all: no group headers should be shown.
        let none = CardGrouping.sections(items: [GroupedRow](), tags: tags, tagId: \.tagId)
        try expectEqual(none.count, 0, "with no cards no blocks remain")

        // Every card tagged: the empty untagged block is omitted.
        let all = CardGrouping.sections(items: [GroupedRow(id: "a", tagId: "t1")], tags: tags, tagId: \.tagId)
        try expectEqual(all.map(\.name), ["工作"], "the untagged block is hidden when nothing is untagged")
        try expectEqual(all.first?.items.map(\.id), ["a"], "the tagged card remains visible")

        // A tag with no cards produces no block — a block disappears with its last card.
        let empty = CardGrouping.sections(
            items: [GroupedRow(id: "a", tagId: "t1")],
            tags: tags + [CardTag(id: "t9", name: "没人用", sortOrder: 1)],
            tagId: \.tagId
        )
        try expectEqual(empty.map(\.name), ["工作"], "a tag with no cards is not rendered")
    }

    register("tags.dangling-reference-falls-back-to-untagged") {
        // Defensive: a card pointing at a tag that is gone must never disappear from the list.
        let rows = [GroupedRow(id: "a", tagId: "missing"), GroupedRow(id: "b", tagId: nil)]
        let sections = CardGrouping.sections(items: rows, tags: [], tagId: \.tagId)
        try expectEqual(sections.count, 1, "no vocabulary means one block")
        try expectEqual(sections[0].items.map(\.id), ["a", "b"], "the dangling card falls into the untagged block")
    }

    register("tags.usage-counts-include-zero") {
        let rows = [GroupedRow(id: "a", tagId: "t1"), GroupedRow(id: "b", tagId: "t1"), GroupedRow(id: "c", tagId: nil)]
        let counts = CardGrouping.usageCounts(items: rows, tagId: \.tagId)
        try expectEqual(counts["t1"], 2, "t1 counts both its cards")
        try expectEqual(counts["t2"], nil, "an unused tag has no entry (the management list shows zero itself)")
    }

    // MARK: - Store

    register("store.tags-round-trip") {
        let (store, root) = try makeStore("store-tags")
        defer { TempSpace.clean(root) }

        try expectEqual(try store.tags(), [], "a fresh store has no tags")
        let work = CardTag(id: "t1", name: "工作", sortOrder: 0, createdAt: Date(timeIntervalSince1970: 1_800_800_000))
        let db = CardTag(id: "t2", name: "数据库", sortOrder: 1, createdAt: Date(timeIntervalSince1970: 1_800_800_100))
        try store.save(work)
        try store.save(db)
        try expectEqual(try store.tags(), [work, db], "tags round trip in block order")

        try store.renameTag(id: "t1", to: "项目")
        try expectEqual(try store.tags().first?.name, "项目", "rename changes the name only")
        try expectEqual(try store.tags().first?.id, "t1", "rename keeps the id")
        try expectEqual(try store.tags().count, 2, "rename adds nothing")

        try store.save(TagVocabulary.renumber([db, work]))
        try expectEqual(try store.tags().map(\.id), ["t2", "t1"], "a reorder round trips")

        try store.deleteTag(id: "t1")
        try expectEqual(try store.tags().map(\.id), ["t2"], "delete removes exactly that tag")

        // A second connection must read the same vocabulary.
        let reopened = try DataStore(directory: root)
        try expectEqual(try reopened.tags().map(\.name), ["数据库"], "the vocabulary survives reopening")
    }

    register("store.filing-cards-under-tags") {
        let (store, root) = try makeStore("store-tag-filing")
        defer { TempSpace.clean(root) }

        let work = CardTag(id: "t1", name: "工作", sortOrder: 0)
        try store.save(work)

        let card = PresetCard(id: "c1", title: "Card", command: "echo c",
                              createdAt: Date(timeIntervalSince1970: 1_800_810_000),
                              updatedAt: Date(timeIntervalSince1970: 1_800_810_000))
        let temp = TempTerminal(id: "m1", title: "Term", createdAt: Date(timeIntervalSince1970: 1_800_810_000),
                                lastActivityAt: Date(timeIntervalSince1970: 1_800_810_000))
        try store.save(card)
        try store.save(temp)

        try expectEqual(try store.cards().first?.tagId, nil, "a card starts untagged")
        try expectEqual(try store.temps().first?.tagId, nil, "a terminal starts untagged")

        try store.setTag("t1", kind: .preset, ownerId: "c1")
        try store.setTag("t1", kind: .temp, ownerId: "m1")
        try expectEqual(try store.cards().first?.tagId, "t1", "the card is filed")
        try expectEqual(try store.temps().first?.tagId, "t1", "the terminal is filed")
        try expectEqual(try store.tagUsageCounts(), ["t1": 2], "usage counts both kinds of card")

        // Saving an unrelated field must not silently drop the tag reference.
        var edited = try expectUnwrap(try store.cards().first, "the saved card")
        edited.title = "Card renamed"
        try store.save(edited)
        try expectEqual(try store.cards().first?.tagId, "t1", "a plain save keeps the tag")
        try expectEqual(try store.cards().first?.title, "Card renamed", "and still writes the edit")

        try store.setTag(nil, kind: .preset, ownerId: "c1")
        try expectEqual(try store.cards().first?.tagId, nil, "clearing the tag works")
        try expectEqual(try store.tagUsageCounts(), ["t1": 1], "the cleared card is no longer counted")
    }

    register("store.deleting-a-tag-returns-its-cards") {
        let (store, root) = try makeStore("store-tag-delete")
        defer { TempSpace.clean(root) }

        try store.save(CardTag(id: "t1", name: "工作", sortOrder: 0))
        let card = PresetCard(id: "c1", title: "Card", command: "echo c",
                              createdAt: Date(timeIntervalSince1970: 1_800_820_000),
                              updatedAt: Date(timeIntervalSince1970: 1_800_820_000), tagId: "t1")
        let temp = TempTerminal(id: "m1", title: "Term", createdAt: Date(timeIntervalSince1970: 1_800_820_000),
                                lastActivityAt: Date(timeIntervalSince1970: 1_800_820_000), tagId: "t1")
        try store.save(card)
        try store.save(temp)
        // A session under the card: deleting a tag must not touch history either.
        try store.save(SessionRecord(id: "s1", kind: .preset, ownerId: "c1", title: "Card",
                                     shell: "/bin/zsh", startedAt: Date(timeIntervalSince1970: 1_800_820_100)))

        try store.deleteTag(id: "t1")

        // The whole point of `ON DELETE SET NULL`: the tag goes, the cards stay.
        try expectEqual(try store.cards().map(\.id), ["c1"], "the card survives its tag")
        try expectEqual(try store.cards().first?.tagId, nil, "and falls back to untagged")
        try expectEqual(try store.temps().map(\.id), ["m1"], "the terminal survives its tag")
        try expectEqual(try store.temps().first?.tagId, nil, "and falls back to untagged")
        try expectEqual(try store.tags(), [], "the tag is gone")
        try expectEqual(try store.session(id: "s1")?.ownerId, "c1", "history is untouched")
    }

    register("store.migrates-v2-database-without-tags") {
        let root = try TempSpace.make("store-v2-tags-migration")
        defer { TempSpace.clean(root) }
        let databaseURL = StoragePaths.databaseURL(in: root)

        // Hand-build a v2-shaped database: no `tags` table, no `tag_id` columns anywhere.
        do {
            let database = try Database(path: databaseURL.path)
            try database.execute("""
            CREATE TABLE schema_version (version INTEGER NOT NULL);
            CREATE TABLE preset_cards (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, command TEXT NOT NULL,
                shell_override TEXT, working_directory TEXT, environment TEXT NOT NULL DEFAULT '',
                auto_run INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            CREATE TABLE temp_terminals (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at REAL NOT NULL, last_activity_at REAL NOT NULL
            );
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, owner_id TEXT NOT NULL, title TEXT NOT NULL,
                shell TEXT NOT NULL, working_directory TEXT, started_at REAL NOT NULL, ended_at REAL,
                termination TEXT, last_command_exit_status INTEGER, last_command_failed INTEGER NOT NULL DEFAULT 0,
                last_command_status_unknown INTEGER NOT NULL DEFAULT 0, launch_failed INTEGER NOT NULL DEFAULT 0,
                unexpected_exit INTEGER NOT NULL DEFAULT 0, last_command_text TEXT
            );
            CREATE TABLE session_events (
                session_id TEXT NOT NULL, sequence INTEGER NOT NULL, timestamp REAL NOT NULL, kind TEXT NOT NULL,
                data BLOB, cols INTEGER NOT NULL DEFAULT 0, rows INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (session_id, sequence)
            ) WITHOUT ROWID;
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
            try database.run("INSERT INTO schema_version (version) VALUES (2);")
            try database.run("""
            INSERT INTO preset_cards (id, title, command, shell_override, working_directory, environment, auto_run, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.text("v2-card"), .text("V2 card"), .text("echo v2"), .null, .null,
                  .text(""), .integer(0), .real(1_800_830_000), .real(1_800_830_000)])
            try database.run("INSERT INTO temp_terminals (id, title, created_at, last_activity_at) VALUES (?, ?, ?, ?);",
                             [.text("v2-temp"), .text("V2 term"), .real(1_800_830_000), .real(1_800_830_000)])
            try database.run("""
            INSERT INTO sessions (id, kind, owner_id, title, shell, working_directory, started_at, ended_at,
                termination, last_command_exit_status, last_command_failed, last_command_status_unknown,
                launch_failed, unexpected_exit, last_command_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.text("v2-session"), .text("preset"), .text("v2-card"), .text("V2 card"), .text("/bin/zsh"),
                  .null, .real(1_800_830_100), .real(1_800_830_200), .text("normal"),
                  .integer(0), .integer(0), .integer(0), .integer(0), .integer(0), .text("echo v2")])
            try database.run("INSERT INTO session_events (session_id, sequence, timestamp, kind, data, cols, rows) VALUES (?, ?, ?, ?, ?, ?, ?);",
                             [.text("v2-session"), .integer(0), .real(1_800_830_110), .text("output"), .blob(Data([0x76, 0x32])), .integer(0), .integer(0)])
        }

        let store = try DataStore(directory: root)
        try expectEqual(try storeSchemaVersion(store), DataStore.schemaVersion, "opening a v2 database bumps schema_version")
        try expect(try storeTableNames(store).contains("tags"), "the migration creates the tags table")
        try expect(try storeColumns(store, table: "preset_cards").contains("tag_id"), "preset_cards gains tag_id")
        try expect(try storeColumns(store, table: "temp_terminals").contains("tag_id"), "temp_terminals gains tag_id")

        // Everything that existed before the migration is still there, and every row is
        // untagged — which is exactly "old data lands in 未加标签".
        try expectEqual(try store.cards().map(\.id), ["v2-card"], "the v2 card survives")
        try expectEqual(try store.cards().first?.tagId, nil, "the v2 card is untagged")
        try expectEqual(try store.temps().map(\.id), ["v2-temp"], "the v2 terminal survives")
        try expectEqual(try store.temps().first?.tagId, nil, "the v2 terminal is untagged")
        try expectEqual(try store.session(id: "v2-session")?.lastCommandText, "echo v2", "history survives")
        try expectEqual(try store.events(sessionId: "v2-session").first?.data, Data([0x76, 0x32]), "events survive byte for byte")
        try expectEqual(try store.tags(), [], "migration invents no tags")

        // The migrated columns are real foreign keys, not just text columns.
        try store.save(CardTag(id: "t1", name: "工作", sortOrder: 0))
        try store.setTag("t1", kind: .preset, ownerId: "v2-card")
        try expectEqual(try store.cards().first?.tagId, "t1", "the migrated column is writable")
        try store.deleteTag(id: "t1")
        try expectEqual(try store.cards().first?.tagId, nil, "ON DELETE SET NULL works on the migrated columns")
        try expectEqual(try store.cards().count, 1, "and the card is still there")

        // Writing a card through the public API keeps working after the migration.
        var card = try expectUnwrap(try store.cards().first, "the migrated card")
        card.title = "V2 card edited"
        try store.save(card)
        try expectEqual(try store.cards().first?.title, "V2 card edited", "the migrated card is writable")
    }

    register("store.migration-keeps-every-field") {
        // The same v2 -> v3 migration, but with every column populated. Reading a card back
        // is index-based, so a column added in the wrong place would show up here as a
        // shifted field rather than as a missing one.
        let root = try TempSpace.make("store-v2-full-migration")
        defer { TempSpace.clean(root) }
        let databaseURL = StoragePaths.databaseURL(in: root)

        // Fixed, exactly representable dates: `Date(timeIntervalSince1970:)` round trips
        // through the REAL column bit-for-bit at whole seconds.
        let created = Date(timeIntervalSince1970: 1_800_900_000)
        let updated = Date(timeIntervalSince1970: 1_800_900_500)
        let activity = Date(timeIntervalSince1970: 1_800_900_900)

        do {
            let database = try Database(path: databaseURL.path)
            try database.execute("""
            CREATE TABLE schema_version (version INTEGER NOT NULL);
            CREATE TABLE preset_cards (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, command TEXT NOT NULL,
                shell_override TEXT, working_directory TEXT, environment TEXT NOT NULL DEFAULT '',
                auto_run INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            CREATE TABLE temp_terminals (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at REAL NOT NULL, last_activity_at REAL NOT NULL
            );
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, kind TEXT NOT NULL, owner_id TEXT NOT NULL, title TEXT NOT NULL,
                shell TEXT NOT NULL, working_directory TEXT, started_at REAL NOT NULL, ended_at REAL,
                termination TEXT, last_command_exit_status INTEGER, last_command_failed INTEGER NOT NULL DEFAULT 0,
                last_command_status_unknown INTEGER NOT NULL DEFAULT 0, launch_failed INTEGER NOT NULL DEFAULT 0,
                unexpected_exit INTEGER NOT NULL DEFAULT 0, last_command_text TEXT
            );
            CREATE TABLE session_events (
                session_id TEXT NOT NULL, sequence INTEGER NOT NULL, timestamp REAL NOT NULL, kind TEXT NOT NULL,
                data BLOB, cols INTEGER NOT NULL DEFAULT 0, rows INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (session_id, sequence)
            ) WITHOUT ROWID;
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
            try database.run("INSERT INTO schema_version (version) VALUES (2);")
            // Every column non-default: a shifted index cannot pass by luck.
            try database.run("""
            INSERT INTO preset_cards (id, title, command, shell_override, working_directory, environment, auto_run, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.text("full-card"), .text("Full card"), .text("echo full"), .text("/bin/bash"),
                  .text("/tmp"), .text("A=1\nB=two"), .integer(1), .date(created), .date(updated)])
            try database.run("INSERT INTO temp_terminals (id, title, created_at, last_activity_at) VALUES (?, ?, ?, ?);",
                             [.text("full-temp"), .text("Full term"), .date(created), .date(activity)])
            try database.run("""
            INSERT INTO sessions (id, kind, owner_id, title, shell, working_directory, started_at, ended_at,
                termination, last_command_exit_status, last_command_failed, last_command_status_unknown,
                launch_failed, unexpected_exit, last_command_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, [.text("full-session"), .text("preset"), .text("full-card"), .text("Full card"),
                  .text("/bin/bash"), .text("/tmp"), .date(created), .date(updated), .text("forced"),
                  .integer(7), .integer(1), .integer(1), .integer(0), .integer(1), .text("echo full")])
            try database.run("INSERT INTO session_events (session_id, sequence, timestamp, kind, data, cols, rows) VALUES (?, ?, ?, ?, ?, ?, ?);",
                             [.text("full-session"), .integer(0), .date(activity), .text("output"), .blob(Data([0xAB, 0x00, 0xCD])), .integer(0), .integer(0)])
            try database.run("INSERT INTO session_events (session_id, sequence, timestamp, kind, data, cols, rows) VALUES (?, ?, ?, ?, ?, ?, ?);",
                             [.text("full-session"), .integer(1), .date(activity), .text("resize"), .blob(Data()), .integer(120), .integer(40)])
        }

        let store = try DataStore(directory: root)

        try expectEqual(try store.cards(), [PresetCard(
            id: "full-card", title: "Full card", command: "echo full", shellOverride: "/bin/bash",
            workingDirectory: "/tmp", environment: ["A": "1", "B": "two"], autoRun: true,
            createdAt: created, updatedAt: updated, tagId: nil
        )], "every card field survives the migration")

        try expectEqual(try store.temps(), [TempTerminal(
            id: "full-temp", title: "Full term", createdAt: created, lastActivityAt: activity, tagId: nil
        )], "every terminal field survives the migration")

        let expectedSession = SessionRecord(
            id: "full-session", kind: .preset, ownerId: "full-card", title: "Full card",
            shell: "/bin/bash", workingDirectory: "/tmp", startedAt: created, endedAt: updated,
            termination: .forced, lastCommandExitStatus: 7, lastCommandFailed: true,
            lastCommandStatusUnknown: true, launchFailed: false, unexpectedExit: true,
            lastCommandText: "echo full"
        )
        let stored = try expectUnwrap(try store.session(id: "full-session"), "the migrated session")
        try expectEqual(differingSessionFields(stored, expectedSession), [], "every session field survives the migration")

        let events = try store.events(sessionId: "full-session")
        try expectEqual(events.count, 2, "both events survive")
        try expectEqual(events.first?.data, Data([0xAB, 0x00, 0xCD]), "the event payload survives byte for byte")
        try expectEqual(events.last?.cols, 120, "the resize event survives")
        try expectEqual(events.last?.rows, 40, "the resize rows survive")

        // And the migrated database is fully usable: file, rename, delete.
        try store.save(CardTag(id: "t1", name: "工作", sortOrder: 0))
        try store.setTag("t1", kind: .preset, ownerId: "full-card")
        try store.setTag("t1", kind: .temp, ownerId: "full-temp")
        let sections = CardGrouping.sections(items: try store.cards(), tags: try store.tags()) { $0.tagId }
        try expectEqual(sections.map(\.name), ["工作"], "a migrated card groups under its new tag without an empty untagged block")
        try expectEqual(sections.first?.items.map(\.id), ["full-card"], "and it is the card that was filed")
        try store.deleteTag(id: "t1")
        try expectEqual(try store.cards().count, 1, "deleting the tag leaves the card")
        try expectEqual(try store.cards().first?.tagId, nil, "and untags it")
    }
}

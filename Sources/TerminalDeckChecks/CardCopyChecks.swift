import Foundation
import TerminalDeckKit

/// Old terminal copies remain readable/cleanable, but cannot be created through the copy API.
private func saveLegacyTerminalCopy(_ store: TerminalDeckStore, sourceID: String = "t", runID: String = "old",
                                    configuration: TerminalLaunchConfiguration = TerminalLaunchConfiguration(shell: "zsh")) throws -> OwnerKey {
    let terminal = TempTerminal(title: "Legacy · 副本 1",
                                copy: CardCopy(sourceID: sourceID, number: 1, anchorID: sourceID, runID: runID),
                                launchConfiguration: configuration)
    try store.save(terminal)
    return OwnerKey(kind: .temp, ownerId: terminal.id)
}

func registerCardCopyChecks() {
    register("copies.terminals-cannot-create-copies") {
        let (store, root) = try makeStore("copy-terminal-rejected")
        defer { TempSpace.clean(root) }
        let terminal = TempTerminal(id: "t", title: "Shell")
        try store.save(terminal)
        let before = try store.temps()
        let key = OwnerKey(kind: .temp, ownerId: terminal.id)
        let error = try expectThrows("terminal copies are unsupported") {
            try store.createCopy(of: key, runID: "r", defaultShell: "zsh")
        }
        try expectEqual(String(describing: error), CardCopyError.unsupportedKind.description, "explicit unsupported-kind error")
        try expectEqual(try store.temps(), before, "rejected request does not create or change a terminal")
        try expectEqual(try store.string(forKey: "copy_number_temp_t"), nil, "rejected request does not consume numbering")
        try expectEqual(try store.string(forKey: CardCopyLayout.terminalOrderKey), nil, "terminal order remains unchanged")
        let legacy = try saveLegacyTerminalCopy(store)
        try store.retainCopy(legacy)
        _ = try expectThrows("legacy retained terminals cannot create copies either") {
            try store.createCopy(of: legacy, runID: "r", defaultShell: "zsh")
        }
    }

    register("copies.configuration-only-and-independent") {
        let (store, root) = try makeStore("copy-config")
        defer { TempSpace.clean(root) }
        let tag = CardTag(name: "工作", sortOrder: 0)
        try store.save(tag)
        let original = PresetCard(id: "source", title: "编译", command: "echo 原卡", shellOverride: "bash",
                                  workingDirectory: "/tmp", environment: ["TEST": "a=b"], autoRun: true, tagId: tag.id)
        try store.save(original)
        try store.save(SessionRecord(id: "old-history", kind: .preset, ownerId: original.id, title: "旧名称", shell: "/bin/bash"))
        let key = try store.createCopy(of: OwnerKey(kind: .preset, ownerId: original.id), runID: "run-A", defaultShell: "zsh")
        var copy = try expectUnwrap(try store.cards().first { $0.id == key.ownerId }, "copy")
        try expectEqual(copy.title, "编译", "the copy keeps the card's own name; the UI marks it 分身")
        try expectEqual(copy.copy?.number, 1, "numbering survives in metadata, not in the title")
        try expectEqual(copy.command, original.command, "command copied")
        try expectEqual(copy.shellOverride, original.shellOverride, "shell copied")
        try expectEqual(copy.environment, original.environment, "explicit environment copied")
        try expectEqual(copy.workingDirectory, original.workingDirectory, "directory copied")
        try expectEqual(copy.tagId, original.tagId, "tag copied")
        try expectEqual(copy.autoRun, false, "no inherited auto-run")
        try expectEqual(copy.copy?.runID, "run-A", "run identity")
        try expectEqual(try store.sessions(kind: .preset, ownerId: copy.id), [], "history not copied")
        copy.command = "echo 副本"
        try store.save(copy)
        try expectEqual(try store.cards().first { $0.id == original.id }?.command, original.command, "independent edits")
        try store.deleteCard(id: original.id)
        try expectEqual(try store.cards().map(\.id), [copy.id], "source deletion does not cascade")
        try store.retainCopy(key)
        try expectEqual(try store.cards().first?.copy?.runID, nil, "orphan copy can still be retained")
    }

    register("copies.repeated-nested-and-monotonic") {
        let (store, root) = try makeStore("copy-number")
        defer { TempSpace.clean(root) }
        try store.save(PresetCard(id: "s", title: "Build", command: "true"))
        let source = OwnerKey(kind: .preset, ownerId: "s")
        let a = try store.createCopy(of: source, runID: "r", defaultShell: "zsh")
        let b = try store.createCopy(of: source, runID: "r", defaultShell: "zsh")
        let c = try store.createCopy(of: a, runID: "r", defaultShell: "zsh")
        try expectEqual(try store.cards().map(\.id), [source.ownerId, b.ownerId, a.ownerId, c.ownerId], "adjacent insertions")
        try expectEqual(try store.cards().last?.title, "Build", "every copy shares the source title; no suffix chain")
        try expectEqual(try store.cards().last?.copy?.sourceID, "s", "provenance is not a deletion chain")
        _ = try store.purgeStaleCopies()
        let d = try store.createCopy(of: source, runID: "new", defaultShell: "zsh")
        try expectEqual(try store.cards().first { $0.id == d.ownerId }?.title, "Build", "titles stay clean after cleanup")
        try expectEqual(try store.cards().first { $0.id == d.ownerId }?.copy?.number, 4, "number never collides after cleanup")
    }

    register("copies.legacy-suffix-is-dropped") {
        let (store, root) = try makeStore("copy-legacy-title")
        defer { TempSpace.clean(root) }
        // 旧库里的标题带着「· 副本 N」；序号现在归元数据，标题在建分身时顺手回到原名。
        try store.save(PresetCard(id: "legacy", title: "Build · 副本 1", command: "true"))
        let key = try store.createCopy(of: OwnerKey(kind: .preset, ownerId: "legacy"), runID: "r", defaultShell: "zsh")
        try expectEqual(try store.cards().first { $0.id == key.ownerId }?.title, "Build", "legacy suffix stripped")
        try expectEqual(TerminalDeckStore.baseCopyTitle("Build"), "Build", "an ordinary name is untouched")
        // 用户自己起的「… 副本 2」这种名字只在建分身时被认作旧标记，不做别的改写。
        try expectEqual(TerminalDeckStore.baseCopyTitle("副本 2 说明"), "副本 2 说明", "only the trailing marker counts")
    }

    register("copies.retain-same-id-history-and-relaunch") {
        let (store, root) = try makeStore("copy-retain")
        defer { TempSpace.clean(root) }
        try store.save(PresetCard(id: "s", title: "Build", command: "true"))
        let key = try store.createCopy(of: OwnerKey(kind: .preset, ownerId: "s"), runID: "old", defaultShell: "zsh")
        try store.save(SessionRecord(id: "owned", kind: .preset, ownerId: key.ownerId, title: "Copy", shell: "/bin/zsh"))
        try store.append([SessionEvent(sessionId: "owned", sequence: 0, kind: .output, data: Data("visible".utf8))])
        var expected = try expectUnwrap(try store.cards().first { $0.id == key.ownerId }, "copy before retention")
        expected.copy = nil
        try store.retainCopy(key)
        let after = try expectUnwrap(try store.cards().first { $0.id == key.ownerId }, "retained")
        try expectEqual(after, expected, "retention clears all copy identity but preserves ID and configuration")
        let ordinaryRows = try store.database.query("""
        SELECT COUNT(*) FROM preset_cards WHERE id = ? AND copy_source_id IS NULL
            AND copy_number = 0 AND copy_anchor_id IS NULL AND clone_run_id IS NULL;
        """, [.text(key.ownerId)]) { $0.int(0) }
        try expectEqual(ordinaryRows, [1], "retention clears persisted provenance and layout bindings")
        try expectEqual(try store.cards().count, 2, "retain never makes an extra card")
        try expectEqual(try store.events(sessionId: "owned").count, 1, "current history remains")
        _ = try expectThrows("ordinary card cannot be dismissed as a clone") { try store.removeCopy(key) }
        let reopened = try TerminalDeckStore(directory: root)
        try expectEqual(try reopened.purgeStaleCopies(keeping: "new"), [], "retained excluded from relaunch cleanup")
        try expectEqual(try reopened.cards().count, 2, "retained survives relaunch")
    }

    register("copies.cross-menu-crash-cleanup-and-order") {
        let (store, root) = try makeStore("copy-purge")
        defer { TempSpace.clean(root) }
        try store.save(PresetCard(id: "s", title: "Build", command: "true"))
        try store.save(TempTerminal(id: "t", title: "Shell"))
        let a = try store.createCopy(of: OwnerKey(kind: .preset, ownerId: "s"), runID: "old", defaultShell: "zsh")
        let b = try saveLegacyTerminalCopy(store)
        let current = try store.createCopy(of: OwnerKey(kind: .preset, ownerId: "s"), runID: "current", defaultShell: "zsh")
        for (n, key) in [a, b].enumerated() {
            let id = "history-\(n)"
            try store.save(SessionRecord(id: id, kind: key.kind, ownerId: key.ownerId, title: "Copy", shell: "/bin/zsh"))
            try store.append([SessionEvent(sessionId: id, sequence: 0, kind: .output, data: Data([1, 2]))])
        }
        let reopened = try TerminalDeckStore(directory: root)
        try expectEqual(Set(try reopened.purgeStaleCopies(keeping: "current")), [a, b], "cross-menu stale cleanup")
        try expectEqual(try reopened.cards().map(\.id), ["s", current.ownerId], "current run retained")
        try expectEqual(try reopened.temps().map(\.id), ["t"], "ordinary terminal untouched")
        try expectEqual(try reopened.historyUsage().eventBytes, 0, "associated history cleared")
        try expectEqual(try reopened.unfinishedSessions(), [], "session metadata cleared")
        let order = try reopened.string(forKey: PresetCardReordering.storageKey) ?? ""
        try expect(!order.contains(a.ownerId), "no stale order reference")
        try expectEqual(try reopened.purgeStaleCopies(keeping: "current"), [], "cleanup is idempotent")
    }

    register("copies.creation-retention-removal-rollback") {
        let (store, root) = try makeStore("copy-rollback")
        defer { TempSpace.clean(root) }
        try store.save(PresetCard(id: "s", title: "Build", command: "true"))
        let source = OwnerKey(kind: .preset, ownerId: "s")
        try store.database.execute("""
        CREATE TRIGGER reject_copy_order BEFORE INSERT ON settings WHEN NEW.key = 'preset_card_order'
        BEGIN SELECT RAISE(ABORT, 'injected order write failure'); END;
        """)
        _ = try expectThrows("creation transaction") { try store.createCopy(of: source, runID: "r", defaultShell: "zsh") }
        try expectEqual(try store.cards().map(\.id), ["s"], "no half-created copy")
        try store.database.execute("DROP TRIGGER reject_copy_order;")
        let key = try store.createCopy(of: source, runID: "r", defaultShell: "zsh")
        try expectEqual(try store.cards().last?.copy?.number, 1, "counter rolled back")
        try store.database.execute("""
        CREATE TRIGGER reject_retention BEFORE UPDATE ON preset_cards WHEN NEW.clone_run_id IS NULL
        BEGIN SELECT RAISE(ABORT, 'injected retention failure'); END;
        """)
        _ = try expectThrows("retain failure") { try store.retainCopy(key) }
        try expectEqual(try store.cards().last?.copy?.runID, "r", "failed retain stays disposable")
        try store.database.execute("DROP TRIGGER reject_retention;")
        try store.save(SessionRecord(id: "h", kind: .preset, ownerId: key.ownerId, title: "Copy", shell: "/bin/zsh"))
        try store.append([SessionEvent(sessionId: "h", sequence: 0, kind: .output, data: Data([1]))])
        try store.database.execute("""
        CREATE TRIGGER reject_removal BEFORE DELETE ON preset_cards WHEN OLD.clone_run_id IS NOT NULL
        BEGIN SELECT RAISE(ABORT, 'injected removal failure'); END;
        """)
        _ = try expectThrows("delete failure") { try store.removeCopy(key) }
        try expectEqual(try store.events(sessionId: "h").count, 1, "failed removal restores events")
        try expect(try store.session(id: "h") != nil, "failed removal restores session")
        try expectEqual(try store.cards().count, 2, "failed removal leaves card retryable")
    }

    register("copies.legacy-terminal-launch-config-and-retention-clock") {
        let (store, root) = try makeStore("copy-terminal")
        defer { TempSpace.clean(root) }
        let old = Date(timeIntervalSince1970: 1)
        try store.save(TempTerminal(id: "t", title: "Shell", createdAt: old, lastActivityAt: old))
        try store.save(SessionRecord(id: "last", kind: .temp, ownerId: "t", title: "Shell", shell: "/bin/bash",
                                     workingDirectory: "/tmp", endedAt: old, lastCommandText: "do-not-copy-input"))
        let key = try saveLegacyTerminalCopy(store, runID: "r",
                                             configuration: TerminalLaunchConfiguration(shell: "/bin/bash", workingDirectory: "/tmp"))
        let copied = try expectUnwrap(try store.temps().first { $0.id == key.ownerId }, "legacy terminal copy")
        try expectEqual(copied.launchConfiguration?.shell, "/bin/bash", "legacy startup shell remains readable")
        try expectEqual(copied.launchConfiguration?.workingDirectory, "/tmp", "legacy startup directory remains readable")
        try expectEqual(try store.sessions(kind: .temp, ownerId: copied.id), [], "no copied terminal input/history")
        try expectEqual(RetentionPolicy.expiredTempIDs(temps: try store.temps(), latestSessions: [:]), ["t"], "only ordinary terminal expires")
        try store.retainCopy(key)
        let reopened = try TerminalDeckStore(directory: root)
        _ = try reopened.purgeStaleCopies()
        let retained = try expectUnwrap(try reopened.temps().first { $0.id == key.ownerId }, "retained terminal")
        try expectEqual(retained.launchConfiguration, copied.launchConfiguration, "launch configuration survives reopen")
        try expectEqual(retained.copy?.runID, nil, "ordinary retained identity")
        try expectEqual(RetentionPolicy.expiredTempIDs(temps: [retained], latestSessions: [:], now: .distantFuture), [], "retained terminal never 24h-expires")
    }

    register("copies.independent-order-retention-and-drag") {
        let (store, root) = try makeStore("copy-layout")
        defer { TempSpace.clean(root) }
        try store.save(PresetCard(id: "a", title: "A", command: "true"))
        try store.save(PresetCard(id: "b", title: "B", command: "true"))
        let c = try store.createCopy(of: OwnerKey(kind: .preset, ownerId: "a"), runID: "r", defaultShell: "zsh")
        let d = try store.createCopy(of: c, runID: "r", defaultShell: "zsh")
        let order = ["a", c.ownerId, d.ownerId, "b"]
        try expectEqual(try store.cards().map(\.id), order, "copies join the existing sequence, not a source stack")
        try expect(try store.cards().allSatisfy { $0.copy?.anchorID == nil }, "new copies never carry layout bindings")
        try store.retainCopy(c)
        try expectEqual(try store.cards().map(\.id), order, "identity changes do not rewrite the saved sequence")
        try expectEqual(try store.cards().first { $0.id == c.ownerId }?.copy, nil, "retained card is an independent individual")
        let e = try store.createCopy(of: c, runID: "r", defaultShell: "zsh")
        let independentCopy = try expectUnwrap(try store.cards().first { $0.id == e.ownerId }?.copy, "new copy identity")
        try expectEqual(independentCopy.sourceID, c.ownerId, "a retained card is its own source, not its former source")
        try expectEqual(independentCopy.number, 1, "retained cards own their independent numbering")
        _ = try store.movePresetCard(id: c.ownerId, to: CardDropDestination(tagId: nil))
        try expectEqual(try store.cards().map(\.id), ["a", e.ownerId, d.ownerId, "b", c.ownerId],
                        "moving one card never drags its former copies")
        try expectEqual(try store.cards().first { $0.id == d.ownerId }?.copy?.runID, "r", "movement is not retention")
        _ = try store.purgeStaleCopies()
        try expectEqual(try store.cards().map(\.id), ["a", "b", c.ownerId], "cleanup excludes the independent retained card")
    }

    register("copies.legacy-retained-cards-have-no-hidden-identity") {
        let (store, root) = try makeStore("copy-legacy-retained")
        defer { TempSpace.clean(root) }
        try store.save(CardTag(id: "work", name: "工作"))
        try store.save(PresetCard(id: "source", title: "Original", command: "true"))
        var legacy = PresetCard(id: "kept", title: "Agents Usage", command: "printf OWN", shellOverride: "bash",
                                workingDirectory: root.path, environment: ["OWN": "yes"],
                                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2), tagId: "work",
                                copy: CardCopy(sourceID: "source", number: 8, anchorID: "source", runID: nil))
        try store.save(legacy)
        try store.save(PresetCard(id: "active", title: "Active", command: "true",
                                 copy: CardCopy(sourceID: "source", number: 9, anchorID: "kept", runID: "current")))
        let configuration = TerminalLaunchConfiguration(shell: "bash", workingDirectory: root.path, environment: ["OWN": "yes"])
        try store.save(TempTerminal(id: "legacy-terminal", title: "Legacy", createdAt: .distantPast, lastActivityAt: .distantPast,
                                    copy: CardCopy(sourceID: "old-terminal", number: 1, anchorID: "old-terminal", runID: nil),
                                    launchConfiguration: configuration))
        let session = SessionRecord(id: "kept-history", kind: .preset, ownerId: "kept", title: legacy.title, shell: "/bin/bash")
        try store.save(session)
        let events = [SessionEvent(sessionId: session.id, sequence: 0, kind: .output, data: Data("saved output".utf8))]
        try store.append(events)
        let storedSession = try store.session(id: session.id)
        let storedEvents = try store.events(sessionId: session.id)
        let order = try store.cards().map(\.id)
        let reopened = try TerminalDeckStore(directory: root)
        let kept = try expectUnwrap(try reopened.cards().first { $0.id == legacy.id }, "legacy retained card")
        legacy.copy = nil
        try expectEqual(kept, legacy, "old retained metadata is ignored without changing configuration")
        try expectEqual(try reopened.cards().map(\.id), order, "compatibility decoding preserves saved order")
        try expectEqual(try reopened.cards().first { $0.id == "active" }?.copy?.anchorID, nil,
                        "active legacy copies no longer carry layout bindings either")
        try expectEqual(try reopened.cards().first { $0.id == "active" }?.copy?.runID, "current",
                        "active legacy copies still retain their cleanup identity")
        let terminal = try expectUnwrap(try reopened.temps().first, "legacy retained terminal")
        try expectEqual(terminal.copy, nil, "old retained terminals are independent too")
        try expectEqual(terminal.launchConfiguration, configuration, "terminal startup configuration remains intact")
        try expectEqual(RetentionPolicy.expiredTempIDs(temps: [terminal], latestSessions: [:], now: .distantFuture), [],
                        "legacy retained launch cards never acquire ad-hoc expiry")
        let newCopy = try reopened.createCopy(of: OwnerKey(kind: .preset, ownerId: kept.id), runID: "current", defaultShell: "zsh")
        try expectEqual(try reopened.cards().first { $0.id == newCopy.ownerId }?.copy?.sourceID, kept.id,
                        "copies of old retained cards do not inherit the former source")
        try reopened.deleteCard(id: "source")
        try expectEqual(try reopened.cards().first { $0.id == kept.id }, kept, "former source deletion cannot change retained cards")
        try expectEqual(try reopened.session(id: session.id), storedSession, "legacy session ID and record stay intact")
        try expectEqual(try reopened.events(sessionId: session.id), storedEvents, "legacy output stays intact")
        try expectEqual(try reopened.purgeStaleCopies(keeping: "current"), [], "ordinary cards are excluded from stale-copy cleanup")
        try reopened.save(kept)
        let cleanRows = try reopened.database.query("""
        SELECT COUNT(*) FROM preset_cards WHERE id = 'kept' AND copy_source_id IS NULL
            AND copy_number = 0 AND copy_anchor_id IS NULL AND clone_run_id IS NULL;
        """) { $0.int(0) }
        try expectEqual(cleanRows, [1], "the next ordinary save removes legacy metadata on disk")
    }

    register("copies.tag-change-detaches-layout-not-identity") {
        let (store, root) = try makeStore("copy-tag")
        defer { TempSpace.clean(root) }
        try store.save(CardTag(id: "work", name: "工作"))
        try store.save(PresetCard(id: "s", title: "Build", command: "true"))
        let a = try store.createCopy(of: OwnerKey(kind: .preset, ownerId: "s"), runID: "r", defaultShell: "zsh")
        let b = try store.createCopy(of: a, runID: "r", defaultShell: "zsh")
        try store.setTag("work", kind: .preset, ownerId: a.ownerId)
        let values = try store.cards()
        try expectEqual(values.first { $0.id == a.ownerId }?.tagId, "work", "selected card changes group")
        try expectEqual(values.first { $0.id == a.ownerId }?.copy?.anchorID, nil, "new group detaches card")
        try expectEqual(values.first { $0.id == b.ownerId }?.copy?.anchorID, nil, "child never follows tag change")
        try expectEqual(values.first { $0.id == b.ownerId }?.tagId, nil, "child retains its own group")
        try expectEqual(values.first { $0.id == a.ownerId }?.copy?.runID, "r", "tag change is not retention")
    }

    register("copies.startup-purge-is-atomic-on-failure") {
        let (store, root) = try makeStore("copy-purge-rollback")
        defer { TempSpace.clean(root) }
        try store.save(PresetCard(id: "s", title: "Build", command: "true"))
        try store.save(TempTerminal(id: "t", title: "Terminal"))
        let a = try store.createCopy(of: OwnerKey(kind: .preset, ownerId: "s"), runID: "old", defaultShell: "zsh")
        let b = try saveLegacyTerminalCopy(store)
        try store.database.execute("""
        CREATE TRIGGER reject_purge BEFORE DELETE ON temp_terminals WHEN OLD.clone_run_id IS NOT NULL
        BEGIN SELECT RAISE(ABORT, 'injected purge failure'); END;
        """)
        _ = try expectThrows("startup purge failure") { try store.purgeStaleCopies(keeping: "new") }
        try expect(try store.cards().contains { $0.id == a.ownerId }, "earlier preset deletion rolled back")
        try expect(try store.temps().contains { $0.id == b.ownerId }, "terminal still available for retry")
        try store.database.execute("DROP TRIGGER reject_purge;")
        try expectEqual(Set(try store.purgeStaleCopies(keeping: "new")), [a, b], "retry clears both menus")
    }

    register("copies.v3-to-v4-preserves-existing-data") {
        let root = try TempSpace.make("copy-migration")
        defer { TempSpace.clean(root) }
        do {
            let db = try Database(path: DeckPaths.databaseURL(in: root).path)
            try db.execute("""
            CREATE TABLE schema_version(version INTEGER NOT NULL);
            INSERT INTO schema_version VALUES (3);
            CREATE TABLE tags(id TEXT PRIMARY KEY, name TEXT NOT NULL, sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL);
            CREATE TABLE preset_cards(id TEXT PRIMARY KEY, title TEXT NOT NULL, command TEXT NOT NULL, shell_override TEXT,
                working_directory TEXT, environment TEXT NOT NULL DEFAULT '', auto_run INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, tag_id TEXT REFERENCES tags(id) ON DELETE SET NULL);
            CREATE TABLE temp_terminals(id TEXT PRIMARY KEY, title TEXT NOT NULL, created_at REAL NOT NULL,
                last_activity_at REAL NOT NULL, tag_id TEXT REFERENCES tags(id) ON DELETE SET NULL);
            CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO tags VALUES ('tag', '工作', 0, 1);
            INSERT INTO preset_cards VALUES ('a', '老卡', 'echo test', 'bash', '/tmp', 'KEY=value', 1, 1, 2, 'tag');
            INSERT INTO temp_terminals VALUES ('t', '旧终端', 1, 2, 'tag');
            """)
        }
        let store = try TerminalDeckStore(directory: root)
        try expectEqual(try storeSchemaVersion(store), 4, "v4 recorded")
        let card = try expectUnwrap(try store.cards().first, "migrated card")
        try expectEqual(card.title, "老卡", "old title preserved")
        try expectEqual(card.command, "echo test", "old command preserved")
        try expectEqual(card.environment, ["KEY": "value"], "old environment preserved")
        try expectEqual(card.autoRun, true, "old auto-run unchanged")
        try expectEqual(card.tagId, "tag", "old tag unchanged")
        try expectEqual(card.copy, nil, "old card is never treated as disposable")
        try expectEqual(try store.temps().first?.launchConfiguration, nil, "old terminal lifecycle unchanged")
        let reopened = try TerminalDeckStore(directory: root)
        try expectEqual(try reopened.cards().count, 1, "v4 migration idempotent")
    }

    register("copies.real-pty-targeted-removal-and-late-output") {
        let (store, root) = try makeStore("copy-pty")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let recorder = EngineRecorder()
        let engine = SessionEngine(store: store, shimRoot: root.appendingPathComponent("shims"), delegate: recorder,
                                   baseEnvironment: hermeticBaseEnvironment(home: home))
        defer { engine.endAllSessions(timeout: 1) }
        try store.save(PresetCard(id: "s", title: "Original", command: "echo original"))
        let key = try store.createCopy(of: OwnerKey(kind: .preset, ownerId: "s"), runID: "r", defaultShell: "zsh")
        let kept = try store.createCopy(of: OwnerKey(kind: .preset, ownerId: "s"), runID: "r", defaultShell: "zsh")
        let original = try engine.start(kind: .preset, ownerId: "s", title: "Original", shell: "zsh", command: "echo ORIGINAL_OK", workingDirectory: home.path, environment: [:])
        let retainedRuntime = try engine.start(kind: .preset, ownerId: kept.ownerId, title: "Retained", shell: "zsh", command: "echo RETAINED_OK", workingDirectory: home.path, environment: [:])
        try store.retainCopy(kept)
        try expectEqual(engine.runtime(for: kept)?.sessionId, retainedRuntime.sessionId, "retain does not restart PTY")
        let copy = try engine.start(kind: .preset, ownerId: key.ownerId, title: "Copy", shell: "zsh", command: "trap '' HUP; echo COPY_READY; while :; do echo copy_tick; sleep 0.03; done", workingDirectory: home.path, environment: [:])
        try expect(waitForMain(timeout: 15) { recorder.outputText(sessionId: copy.sessionId).contains("COPY_READY") }, "copy started")
        try expectEqual(engine.prepareForRemoval([key], timeout: 0.15), [key], "force fallback finishes only target")
        try store.removeCopy(key)
        engine.forgetRemovedOwner(key)
        engine.resize(sessionId: copy.sessionId, cols: 80, rows: 24)
        pumpMainRunLoop(0.3)
        try expectEqual(engine.isQuitting, false, "global clone cleanup is not App quit")
        try expectEqual(engine.runtime(for: OwnerKey(kind: .preset, ownerId: "s"))?.sessionId, original.sessionId, "original terminal untouched")
        try expectEqual(engine.runtime(for: kept)?.sessionId, retainedRuntime.sessionId, "retained terminal untouched")
        try expectEqual(try store.sessions(kind: .preset, ownerId: key.ownerId), [], "no session resurrection")
        try expectEqual(try store.events(sessionId: copy.sessionId), [], "no late output/resize resurrection")
        try expectEqual(engine.runtime(sessionId: copy.sessionId), nil, "removed runtime forgotten")
    }

    register("copies.real-pty-legacy-retained-terminal-relaunch-and-immediate-removal") {
        let (store, root) = try makeStore("copy-terminal-pty")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        try store.save(TempTerminal(id: "t", title: "Shell", launchConfiguration: TerminalLaunchConfiguration(shell: "bash", workingDirectory: home.path, environment: ["COPY_TEST": "kept"])))
        let retainedKey = try saveLegacyTerminalCopy(store, runID: "r",
                                                     configuration: TerminalLaunchConfiguration(shell: "bash", workingDirectory: home.path,
                                                                                                environment: ["COPY_TEST": "kept"]))
        try store.retainCopy(retainedKey)
        let reopened = try TerminalDeckStore(directory: root)
        _ = try reopened.purgeStaleCopies(keeping: "new")
        let retained = try expectUnwrap(try reopened.temps().first { $0.id == retainedKey.ownerId }, "reopened launch card")
        let config = try expectUnwrap(retained.launchConfiguration, "config")
        let recorder = EngineRecorder()
        let engine = SessionEngine(store: reopened, shimRoot: root.appendingPathComponent("shims"), delegate: recorder,
                                   baseEnvironment: hermeticBaseEnvironment(home: home))
        defer { engine.endAllSessions(timeout: 1) }
        let live = try engine.start(kind: .temp, ownerId: retained.id, title: retained.title, shell: config.shell,
                                    command: nil, workingDirectory: config.workingDirectory, environment: config.environment)
        try expect(waitForMain(timeout: 15) { engine.runtime(for: retainedKey)?.isReachable == true }, "retained terminal starts fresh")
        engine.send(text: "printf 'VALUE=%s\\n' \"$COPY_TEST\"\n", to: live.sessionId)
        try expect(waitForMain(timeout: 5) { recorder.outputText(sessionId: live.sessionId).contains("VALUE=kept") }, "explicit launch environment restored")
        let transient = try saveLegacyTerminalCopy(reopened, sourceID: retainedKey.ownerId, runID: "new", configuration: config)
        let immediate = try engine.start(kind: .temp, ownerId: transient.ownerId, title: "Starting", shell: "zsh", command: nil, workingDirectory: home.path, environment: [:])
        try expectEqual(engine.prepareForRemoval([transient], timeout: 0.1), [transient], "startup-phase terminal can be removed")
        try reopened.removeCopy(transient)
        engine.forgetRemovedOwner(transient)
        pumpMainRunLoop(0.2)
        try expectEqual(try reopened.events(sessionId: immediate.sessionId), [], "no startup output resurrection")
        try expectEqual(engine.runtime(for: retainedKey)?.sessionId, live.sessionId, "retained terminal continues")
    }
}

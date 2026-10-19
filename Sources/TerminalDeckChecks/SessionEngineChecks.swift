import Foundation
import TerminalDeckKit

/// Records every delegate callback. `SessionEngine` delivers delegate calls on the main
/// queue, so the checks pump the main run loop while waiting.
final class EngineRecorder: SessionEngineDelegate {
    private let lock = NSLock()
    private var outputs: [String: [UInt8]] = [:]
    private var runtimes: [SessionRuntime] = []
    private var finishes: [SessionRecord] = []
    private var recordFailures: [String] = []

    func engine(_ engine: SessionEngine, didProduceOutput sessionId: String, bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        outputs[sessionId, default: []].append(contentsOf: bytes)
    }

    func engine(_ engine: SessionEngine, didUpdate runtime: SessionRuntime) {
        lock.lock(); defer { lock.unlock() }
        runtimes.append(runtime)
    }

    func engine(_ engine: SessionEngine, didFinish session: SessionRecord) {
        lock.lock(); defer { lock.unlock() }
        finishes.append(session)
    }

    func engine(_ engine: SessionEngine, didFailToRecord message: String) {
        lock.lock(); defer { lock.unlock() }
        recordFailures.append(message)
    }

    func output(sessionId: String) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return outputs[sessionId] ?? []
    }

    func outputText(sessionId: String) -> String { String(decoding: output(sessionId: sessionId), as: UTF8.self) }

    func finish(sessionId: String) -> SessionRecord? {
        lock.lock(); defer { lock.unlock() }
        return finishes.first { $0.id == sessionId }
    }

    var finishedCount: Int { lock.lock(); defer { lock.unlock() }; return finishes.count }
    var runtimeStatuses: [SessionStatus] { lock.lock(); defer { lock.unlock() }; return runtimes.map(\.status) }
    func labels(sessionId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return runtimes.filter { $0.sessionId == sessionId }.map(\.presentation.label)
    }
    var failures: [String] { lock.lock(); defer { lock.unlock() }; return recordFailures }
}

func registerSessionEngineChecks() {
    register("engine.preset-session-end-to-end") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("engine-e2e")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let workdir = try TempSpace.subdirectory(root, "work")
        try TempSpace.write("echo TD_ENGINE_HOME_RC_OK\n", to: home.appendingPathComponent(".zshrc"))

        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)
        let recorder = EngineRecorder()
        // The engine's injectable environment replaces `setenv`: the session must run
        // against this scratch HOME, never the developer's real dot-files.
        let engine = SessionEngine(
            store: store,
            shimRoot: shimRoot,
            delegate: recorder,
            baseEnvironment: hermeticBaseEnvironment(home: home)
        )
        defer { engine.endAllSessions(reason: .appQuit, timeout: 2.5) }

        let cardId = "engine-card-\(UUID().uuidString)"
        try store.save(PresetCard(id: cardId, title: "Engine card", command: "echo ENGINE_OK"))

        let runtime = try engine.start(
            kind: .preset,
            ownerId: cardId,
            title: "Engine card",
            shell: "zsh",
            command: "echo ENGINE_OK",
            workingDirectory: workdir.path,
            environment: [:]
        )
        let sessionId = runtime.sessionId
        try expectEqual(runtime.status, .starting, "a freshly started session is .starting")

        // The delegate receives the visible output produced by the preset command.
        try expect(
            waitForMain(timeout: 20) { recorder.outputText(sessionId: sessionId).contains("ENGINE_OK") },
            "delegate never received ENGINE_OK; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        try expect(
            recorder.outputText(sessionId: sessionId).contains("TD_ENGINE_HOME_RC_OK"),
            "the engine did not load the scratch HOME's .zshrc; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        try expect(
            containsSubsequence(recorder.output(sessionId: sessionId), tdMarkerPrefixBytes) == false,
            "marker bytes leaked into the delegate output"
        )

        // Readiness moves the runtime to .running.
        try expect(
            waitForMain(timeout: 10) { engine.runtime(sessionId: sessionId)?.status == .running },
            "runtime status never became .running; notifications: \(recorder.runtimeStatuses)"
        )

        // Leaving the shell ends the session.
        engine.send(text: "exit\n", to: sessionId)
        try expect(
            waitForMain(timeout: 15) { recorder.finish(sessionId: sessionId) != nil },
            "engine never delivered didFinish; notifications: \(recorder.runtimeStatuses)"
        )
        let record = try expectUnwrap(recorder.finish(sessionId: sessionId), "didFinish record")
        try expect(record.endedAt != nil, "didFinish record must have endedAt != nil")
        try expectEqual(record.kind, .preset, "didFinish record kind")
        try expectEqual(record.ownerId, cardId, "didFinish record owner")
        try expect(record.shell.hasSuffix("/zsh"), "didFinish record shell, got \(record.shell)")
        try expect(FileManager.default.isExecutableFile(atPath: record.shell), "recorded shell must exist")
        try expectEqual(record.termination, .exited, "a user typed `exit` is a clean self-exit")
        try expectEqual(record.launchFailed, false, "no launch failure")
        try expectEqual(record.unexpectedExit, false, "a clean `exit` is not an unexpected exit")
        try expectEqual(record.lastCommandText, "echo ENGINE_OK", "lastCommandText survives")
        try expectEqual(record.lastCommandExitStatus, 0, "the preset command exited 0")
        try expectEqual(record.workingDirectory, workdir.path, "the record keeps the working directory")

        try expect(
            waitForMain(timeout: 5) { engine.runtime(sessionId: sessionId)?.status == .stopped },
            "runtime should settle in .stopped, got \(String(describing: engine.runtime(sessionId: sessionId)?.status))"
        )

        // The finished record goes through the public Store API: a silently dropped
        // INSERT or a column-offset decode bug would fail here.
        try expect(
            waitFor(timeout: 5) { (try? store.session(id: sessionId))?.endedAt != nil },
            "the finished session must be persisted with endedAt != nil"
        )
        let stored = try expectUnwrap(try store.session(id: sessionId), "stored session")
        // Not `expectEqual(stored, record)` here: these dates come from `Date()`, and the
        // synthesized `==` would compare Foundation's internal Date representation, which a
        // `timeIntervalSince1970` round trip does not preserve bit-for-bit (see
        // `differingSessionFields`). This comparison is field-by-field and instant-exact.
        let differing = differingSessionFields(stored, record)
        try expect(differing.isEmpty, "the persisted row differs from the didFinish record in: \(differing)")
        try expectEqual(recorder.failures, [], "the engine must not report a history write failure")
        try expectEqual(stored.id, sessionId, "stored session id")
        try expectEqual(stored.kind, .preset, "stored session kind")
        try expectEqual(stored.ownerId, cardId, "stored session owner")
        try expect(stored.endedAt != nil, "stored session must have endedAt != nil")
        try expectEqual(stored.unexpectedExit, false, "stored unexpectedExit")
        try expectEqual(stored.launchFailed, false, "stored launchFailed")
        try expectEqual(stored.termination, .exited, "stored termination")
        try expectEqual(stored.lastCommandText, "echo ENGINE_OK", "stored lastCommandText")
        try expectEqual(try store.sessions(kind: .preset, ownerId: cardId), [stored], "the card's session list contains the finished record")
        try expectEqual(try store.unfinishedSessions(), [], "nothing is left unfinished")

        // History events were appended for the session.
        try expect(
            waitFor(timeout: 5) { ((try? store.events(sessionId: sessionId))?.isEmpty == false) },
            "store has no history events for the finished session"
        )
        let events = (try? store.events(sessionId: sessionId)) ?? []
        try expect(events.allSatisfy { $0.sessionId == sessionId }, "history events belong to the session")
        try expectEqual(events.map(\.sequence), Array(0..<Int64(events.count)), "history events keep sequence order")
    }

    register("engine.session-uses-injected-home-not-real-dotfiles") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("engine-injected-home")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let token = "TD_INJECTED_RC_\(UUID().uuidString.prefix(8))"
        try TempSpace.write("echo \(token)\n", to: home.appendingPathComponent(".zshrc"))

        let realHome = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        try expect(home.path != realHome, "the injected HOME must differ from the developer's real HOME")

        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let recorder = EngineRecorder()
        let engine = SessionEngine(
            store: store,
            shimRoot: root.appendingPathComponent("shims", isDirectory: true),
            delegate: recorder,
            baseEnvironment: hermeticBaseEnvironment(home: home)
        )
        defer { engine.endAllSessions(reason: .appQuit, timeout: 2.0) }

        // `workingDirectory: nil` and `$TD_REAL_ZDOTDIR` must both resolve to the injected
        // HOME; the developer's real ~/.zshrc must never be the sourced file.
        let runtime = try engine.start(
            kind: .temp,
            ownerId: "temp-injected-home",
            title: "Home probe",
            shell: "zsh",
            command: "echo ZDOTDIR_PROBE=${TD_REAL_ZDOTDIR}",
            workingDirectory: nil,
            environment: [:]
        )
        let sessionId = runtime.sessionId
        try expectEqual(runtime.workingDirectory, home.path, "nil workingDirectory resolves to the injected HOME")
        try expect(
            waitForMain(timeout: 20) { recorder.outputText(sessionId: sessionId).contains(token) },
            "the injected HOME's .zshrc was not sourced; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        try expect(
            waitForMain(timeout: 5) { recorder.outputText(sessionId: sessionId).contains("ZDOTDIR_PROBE=\(home.path)") },
            "TD_REAL_ZDOTDIR is not the injected HOME; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        try expect(
            recorder.outputText(sessionId: sessionId).contains("ZDOTDIR_PROBE=\(realHome)") == false,
            "the session's dot-dir must not be the developer's real HOME"
        )

        engine.send(text: "exit\n", to: sessionId)
        try expect(waitForMain(timeout: 15) { recorder.finish(sessionId: sessionId) != nil }, "no didFinish for the injected-HOME session")
    }

    register("engine.launched-from-own-terminal-still-reads-the-user-config") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("engine-self-hosted")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)
        let token = "TD_SELF_HOSTED_RC_\(UUID().uuidString.prefix(8))"
        try TempSpace.write("echo \(token)\n", to: home.appendingPathComponent(".zshrc"))

        // Starting the app from one of its own terminals hands it that session's markers, and
        // that session's shim directory is deleted as soon as the session ends. Every terminal
        // the app opens afterwards must still find the user's own configuration.
        let dead = shimRoot.appendingPathComponent("dead-session", isDirectory: true)
        let base = hermeticBaseEnvironment(home: home, extra: [
            "ZDOTDIR": dead.path,
            "TD_SHIM_DIR": dead.path,
            "TD_REAL_ZDOTDIR": home.path,
            "HISTFILE": dead.appendingPathComponent(".zsh_history").path,
            "TERM_PROGRAM": "RunBo",
        ])

        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let recorder = EngineRecorder()
        let engine = SessionEngine(store: store, shimRoot: shimRoot, delegate: recorder, baseEnvironment: base)
        defer { engine.endAllSessions(reason: .appQuit, timeout: 2.0) }

        let runtime = try engine.start(
            kind: .temp,
            ownerId: "temp-self-hosted",
            title: "Self hosted probe",
            shell: "zsh",
            command: "echo \(token)_CMD ZDOTDIR=${ZDOTDIR} REAL=${TD_REAL_ZDOTDIR}",
            workingDirectory: nil,
            environment: [:]
        )
        let sessionId = runtime.sessionId
        try expect(
            waitForMain(timeout: 20) { recorder.outputText(sessionId: sessionId).contains(token) },
            "the user's .zshrc was not sourced; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        try expect(
            waitForMain(timeout: 5) { recorder.outputText(sessionId: sessionId).contains("REAL=\(home.path)") },
            "TD_REAL_ZDOTDIR is not the injected HOME; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        try expect(
            recorder.outputText(sessionId: sessionId).contains("ZDOTDIR=\(shimRoot.path)/"),
            "the session's ZDOTDIR must be its own shim directory; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        try expect(
            recorder.outputText(sessionId: sessionId).contains(dead.path) == false,
            "a deleted shim directory must not appear in the session; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )

        // History belongs to the user: `/etc/zshrc` points HISTFILE at `$ZDOTDIR/.zsh_history`
        // while ZDOTDIR is our shim, and the shim directory is deleted when the session ends.
        engine.send(text: "exit\n", to: sessionId)
        try expect(waitForMain(timeout: 15) { recorder.finish(sessionId: sessionId) != nil },
                   "no didFinish for the self-hosted session")
        let history = home.appendingPathComponent(".zsh_history")
        try expect(
            waitFor(timeout: 5) { (try? String(contentsOf: history, encoding: .utf8))?.contains(token + "_CMD") == true },
            "the user's history file never received the session's command"
        )
    }

    register("engine.preset-history-persisted-and-trimmed") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("engine-trim")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let workdir = try TempSpace.subdirectory(root, "work")
        try TempSpace.write("", to: home.appendingPathComponent(".zshrc"))

        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let recorder = EngineRecorder()
        let engine = SessionEngine(
            store: store,
            shimRoot: root.appendingPathComponent("shims", isDirectory: true),
            delegate: recorder,
            baseEnvironment: hermeticBaseEnvironment(home: home)
        )
        defer { engine.endAllSessions(reason: .appQuit, timeout: 2.5) }

        let cardId = "engine-trim-card"
        try store.save(PresetCard(id: cardId, title: "Trim card", command: "echo TRIM_OK"))
        // Seed 11 finished sessions in the past so the new one is the newest, plus one
        // still-running session that trimming must never touch.
        let past = Date().addingTimeInterval(-40 * 24 * 3600)
        for index in 0..<11 {
            let started = past.addingTimeInterval(Double(index) * 60)
            try store.save(SessionRecord(
                id: "old-finished-\(index)",
                kind: .preset,
                ownerId: cardId,
                title: "Trim card",
                shell: "/bin/zsh",
                startedAt: started,
                endedAt: started.addingTimeInterval(30),
                termination: .normal
            ))
        }
        try store.save(SessionRecord(
            id: "live-session",
            kind: .preset,
            ownerId: cardId,
            title: "Trim card",
            shell: "/bin/zsh",
            startedAt: past
        ))
        try expectEqual(try store.sessions(kind: .preset, ownerId: cardId).filter(\.isFinished).count, 11, "11 finished sessions seeded")

        let runtime = try engine.start(
            kind: .preset,
            ownerId: cardId,
            title: "Trim card",
            shell: "zsh",
            command: "echo TRIM_OK",
            workingDirectory: workdir.path,
            environment: [:]
        )
        let sessionId = runtime.sessionId
        try expect(
            waitForMain(timeout: 20) { recorder.outputText(sessionId: sessionId).contains("TRIM_OK") },
            "delegate never received TRIM_OK; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        engine.send(text: "exit\n", to: sessionId)
        try expect(
            waitForMain(timeout: 15) { recorder.finish(sessionId: sessionId) != nil },
            "engine never delivered didFinish"
        )

        // The finished record is persisted through the public Store API.
        try expect(
            waitFor(timeout: 5) { (try? store.session(id: sessionId))?.endedAt != nil },
            "the finished preset record must be persisted with endedAt != nil"
        )
        let stored = try expectUnwrap(try store.session(id: sessionId), "stored session")
        try expectEqual(recorder.failures, [], "the engine must not report a history write failure")
        try expect(stored.endedAt != nil, "stored endedAt != nil")
        try expectEqual(stored.unexpectedExit, false, "a clean `exit` is not an unexpected exit")
        try expectEqual(stored.launchFailed, false, "no launch failure")
        try expectEqual(stored.termination, .exited, "stored termination")
        try expectEqual(stored.kind, .preset, "stored kind")
        try expectEqual(stored.ownerId, cardId, "stored owner")
        try expectEqual(try store.sessions(kind: .preset, ownerId: cardId).contains { $0.id == sessionId }, true, "the card's session list contains the new record")

        // Start-time trimming kept one predecessor beside the new run; finish-time
        // trimming now leaves exactly this run and the previous one.
        try expect(
            waitFor(timeout: 5) {
                ((try? store.sessions(kind: .preset, ownerId: cardId))?.filter(\.isFinished).count ?? -1) == 2
            },
            "history trim must leave exactly 2 finished sessions (this run + previous), got \((try? store.sessions(kind: .preset, ownerId: cardId))?.filter(\.isFinished).count ?? -1)"
        )
        let remaining = try store.sessions(kind: .preset, ownerId: cardId)
        try expectEqual(remaining.filter(\.isFinished).count, 2, "this run and the previous run remain")
        try expect(remaining.filter(\.isFinished).contains { $0.id == sessionId }, "the newest finished session is kept")
        try expect(remaining.filter { !$0.isFinished }.map(\.id) == ["live-session"], "the running session survives trimming")
        try expect(try store.session(id: "old-finished-0") == nil, "older predecessors are removed")
        try expect(try store.session(id: "old-finished-9") == nil, "older predecessors are removed at start time")
        try expect(try store.session(id: "old-finished-10") != nil, "the immediately previous run is kept")
    }

    register("engine.reconcile-leftovers-closes-rows-and-cleans-shims") {
        let root = try TempSpace.make("engine-reconcile")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)
        let engine = SessionEngine(
            store: store,
            shimRoot: shimRoot,
            delegate: nil,
            baseEnvironment: hermeticBaseEnvironment(home: home)
        )

        let started = Date(timeIntervalSince1970: 1_800_300_000)
        try store.save(SessionRecord(
            id: "leftover",
            kind: .preset,
            ownerId: "card-1",
            title: "Leftover",
            shell: "/bin/zsh",
            startedAt: started,
            lastCommandText: "echo leftover"
        ))
        // The shim directory a crashed app would have left behind.
        let leftoverShim = shimRoot.appendingPathComponent("leftover", isDirectory: true)
        try TempSpace.subdirectory(shimRoot, "leftover")
        try TempSpace.write("stale shim", to: leftoverShim.appendingPathComponent(".zshrc"))
        try expect(FileManager.default.fileExists(atPath: leftoverShim.path), "leftover shim exists before reconciling")

        let now = Date(timeIntervalSince1970: 1_800_400_000)
        engine.reconcileLeftovers(now: now)

        // The leftover row is closed out as interrupted...
        let reconciled = try expectUnwrap(try store.session(id: "leftover"), "reconciled session")
        try expectEqual(reconciled.endedAt, now, "leftover ends at the reconciliation time")
        try expectEqual(reconciled.termination, .interrupted, "leftover termination reason")
        try expectEqual(reconciled.lastCommandText, "echo leftover", "leftover row keeps its fields")
        try expectEqual(try store.unfinishedSessions(), [], "no unfinished sessions remain")
        // ...and the stale shim directory is removed.
        try expect(
            FileManager.default.fileExists(atPath: leftoverShim.path) == false,
            "reconcileLeftovers must remove shim directories left behind by a crash"
        )
    }

    register("engine.launch-failure-missing-working-directory") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("engine-launch-failure")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let engine = SessionEngine(
            store: store,
            shimRoot: root.appendingPathComponent("shims", isDirectory: true),
            delegate: nil,
            baseEnvironment: hermeticBaseEnvironment(home: home)
        )
        defer { engine.endAllSessions(reason: .appQuit, timeout: 2.0) }

        let missing = root.appendingPathComponent("no-such-directory").path
        let error = try expectThrows("start with a missing working directory") {
            try engine.start(
                kind: .preset,
                ownerId: "card-bad",
                title: "Bad card",
                shell: "zsh",
                command: "echo nope",
                workingDirectory: missing,
                environment: [:]
            )
        }
        try expect(error is ShellLaunchError, "expected ShellLaunchError, got \(type(of: error))")
        try expect(engine.allRuntimes.isEmpty, "a failed launch must not leave a runtime behind")
        try expectEqual(try store.sessions(kind: .preset, ownerId: "card-bad"), [], "a failed launch must not write a session row")

        // An unsupported shell is surfaced the same way.
        let shellError = try expectThrows("start with an unsupported shell") {
            try engine.start(
                kind: .temp,
                ownerId: "temp-bad",
                title: "Bad shell",
                shell: "fish",
                command: nil,
                workingDirectory: nil,
                environment: [:]
            )
        }
        try expect(shellError is ShellLaunchError, "expected ShellLaunchError for fish, got \(type(of: shellError))")
        try expect(engine.allRuntimes.isEmpty, "no runtime for an unsupported shell")
    }

    register("engine.sweep-expired-temps") {
        let root = try TempSpace.make("engine-sweep")
        defer { TempSpace.clean(root) }
        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let engine = SessionEngine(store: store, shimRoot: root.appendingPathComponent("shims", isDirectory: true), delegate: nil)

        let now = Date(timeIntervalSince1970: 1_800_200_000)
        let stale = TempTerminal(id: "temp-stale", title: "Stale", createdAt: now.addingTimeInterval(-100_000), lastActivityAt: now.addingTimeInterval(-25 * 3600))
        let fresh = TempTerminal(id: "temp-fresh", title: "Fresh", createdAt: now.addingTimeInterval(-100_000), lastActivityAt: now.addingTimeInterval(-3600))
        try store.save(stale)
        try store.save(fresh)
        try store.save(SessionRecord(id: "stale-session", kind: .temp, ownerId: "temp-stale", title: "Stale", shell: "/bin/zsh", startedAt: stale.createdAt, endedAt: stale.createdAt.addingTimeInterval(60), termination: .normal))
        try store.save(SessionRecord(id: "fresh-session", kind: .temp, ownerId: "temp-fresh", title: "Fresh", shell: "/bin/zsh", startedAt: fresh.createdAt, endedAt: fresh.createdAt.addingTimeInterval(60), termination: .normal))
        try store.append([
            SessionEvent(sessionId: "stale-session", sequence: 0, kind: .output, data: Data([0x53])),
            SessionEvent(sessionId: "fresh-session", sequence: 0, kind: .output, data: Data([0x46])),
        ])

        let expired = engine.sweepExpiredTemps(now: now)
        try expectEqual(expired, ["temp-stale"], "only the stale temp expires")
        try expectEqual(try store.temps().map(\.id), ["temp-fresh"], "expired temp row removed")
        try expectEqual(try store.events(sessionId: "stale-session"), [], "expired temp history removed")
        try expectEqual(try store.events(sessionId: "fresh-session").count, 1, "live temp history kept")
        try expectEqual(engine.sweepExpiredTemps(now: now), [], "sweeping again is a no-op")
    }

    register("engine.history-write-failure-keeps-session") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("engine-write-failure")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let workdir = try TempSpace.subdirectory(root, "work")
        try TempSpace.write("", to: home.appendingPathComponent(".zshrc"))
        let storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        let store = try TerminalDeckStore(directory: storeDirectory)
        let recorder = EngineRecorder()
        let engine = SessionEngine(
            store: store,
            shimRoot: root.appendingPathComponent("shims", isDirectory: true),
            delegate: recorder,
            baseEnvironment: hermeticBaseEnvironment(home: home)
        )
        // Declared before the permission-restore defer below, so on the way out the directory
        // is writable again before the engine is torn down.
        defer { engine.endAllSessions(reason: .appQuit, timeout: 2.5) }

        let cardId = "engine-write-failure-card"
        try store.save(PresetCard(id: cardId, title: "Write failure card", command: "echo START_OK"))
        let runtime = try engine.start(
            kind: .preset,
            ownerId: cardId,
            title: "Write failure card",
            shell: "zsh",
            command: "echo START_OK",
            workingDirectory: workdir.path,
            environment: [:]
        )
        let sessionId = runtime.sessionId
        try expect(
            waitForMain(timeout: 20) { recorder.outputText(sessionId: sessionId).contains("START_OK") },
            "the session never produced its first output; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        try expect(
            waitForMain(timeout: 10) { engine.runtime(sessionId: sessionId)?.status == .running },
            "the session never reached .running"
        )
        try expectEqual(recorder.failures, [], "no history failure before the injection")
        // Let the prompt/echo output drain so the injection does not race a live write.
        pumpMainRunLoop(0.5)

        let injection = try injectStoreWriteFailure(store, directory: storeDirectory)
        defer { injection.restore() } // later than the engine defer, so it runs first

        // Drive output; the PTY path is independent of the database, so output must keep
        // flowing even while every history write fails.
        engine.send(text: "echo WRITE_FAIL_PROBE\n", to: sessionId)
        try expect(
            waitForMain(timeout: 15) { recorder.outputText(sessionId: sessionId).contains("WRITE_FAIL_PROBE") },
            "the session stopped producing output during the write failure; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        guard waitForMain(timeout: 10, { recorder.failures.isEmpty == false }) else {
            try skipCheck("write-failure injection had no effect here (\(injection.mechanism)): no didFailToRecord arrived after output was recorded while the store was read-only")
        }
        let firstReport = recorder.failures
        try expectEqual(firstReport.count, 1, "the first write failure must be reported exactly once, got: \(firstReport)")
        try expect(looksLikeWriteFailure(firstReport[0]), "the reported message should describe the disk problem, got: \(firstReport[0])")

        // More failing writes must not produce more reports: the engine coalesces them.
        engine.send(text: "echo WRITE_FAIL_PROBE_2\n", to: sessionId)
        try expect(
            waitForMain(timeout: 15) { recorder.outputText(sessionId: sessionId).contains("WRITE_FAIL_PROBE_2") },
            "the session stopped producing output after repeated write failures; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        pumpMainRunLoop(1.0)
        try expectEqual(recorder.failures, firstReport, "didFailToRecord must be coalesced to one report per engine")

        // The session is untouched: same status, still usable.
        let liveBySession = try expectUnwrap(engine.runtime(sessionId: sessionId), "runtime(sessionId:) after the write failure")
        let liveByKey = try expectUnwrap(engine.runtime(for: runtime.key), "runtime(for:) after the write failure")
        try expectEqual(liveBySession.status, .running, "the session must stay .running after a history write failure")
        try expectEqual(liveByKey.status, .running, "the owner-key lookup must still find the running session")
        try expectEqual(liveBySession.isReady, true, "the session stays ready")
        try expectEqual(liveBySession.launchFailureMessage, nil, "a write failure is not a launch failure")
        try expectEqual(liveBySession.needsForceTermination, false, "a write failure must not request a forced stop")
        try expectEqual(engine.runningCount, 1, "the engine still counts the session as running")
        engine.send(text: "echo STILL_ALIVE\n", to: sessionId)
        try expect(
            waitForMain(timeout: 15) { recorder.outputText(sessionId: sessionId).contains("STILL_ALIVE") },
            "input stopped reaching the shell during the write failure"
        )

        // Restore the directory: the engine must be able to finish the session and persist it.
        injection.restore()
        _ = store.diskUsageBytes()
        engine.send(text: "exit\n", to: sessionId)
        try expect(
            waitForMain(timeout: 15) { recorder.finish(sessionId: sessionId) != nil },
            "the engine never delivered didFinish after the write failure was cleared"
        )
        try expect(
            waitFor(timeout: 5) { (try? store.session(id: sessionId))?.endedAt != nil },
            "the finished session row was not persisted after recovery"
        )
        let stored = try expectUnwrap(try store.session(id: sessionId), "stored session after recovery")
        try expect(stored.endedAt != nil, "stored endedAt != nil after recovery")
        try expectEqual(stored.kind, .preset, "stored kind after recovery")
        try expectEqual(stored.ownerId, cardId, "stored owner after recovery")
        try expectEqual(try store.sessions(kind: .preset, ownerId: cardId).contains { $0.id == sessionId }, true, "the card's session list contains the recovered record")
    }

    /// A temporary terminal is counted by connection, not by what it is running, and none
    /// of its command results may move the card. This is the end-to-end counterpart of the
    /// pure `presentation.*` checks: it drives a real shell.
    register("engine.temp-terminal-stays-online-through-commands") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("engine-temp-online")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let workdir = try TempSpace.subdirectory(root, "work")
        try TempSpace.write("", to: home.appendingPathComponent(".zshrc"))
        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let recorder = EngineRecorder()
        let engine = SessionEngine(
            store: store,
            shimRoot: root.appendingPathComponent("shims", isDirectory: true),
            delegate: recorder,
            baseEnvironment: hermeticBaseEnvironment(home: home)
        )
        defer { engine.endAllSessions(reason: .appQuit, timeout: 2.5) }

        let tempId = "engine-temp-\(UUID().uuidString)"
        // A temporary terminal has no preset command: the user types everything.
        let runtime = try engine.start(
            kind: .temp,
            ownerId: tempId,
            title: "Temp",
            shell: "zsh",
            command: nil,
            workingDirectory: workdir.path,
            environment: [:]
        )
        let sessionId = runtime.sessionId

        // 1. The shell reaches its first prompt: online, and counted as such.
        try expect(
            waitForMain(timeout: 20) { (try? engine.runtime(sessionId: sessionId))??.isReady == true },
            "the shell never reported ready"
        )
        try expect(
            waitForMain(timeout: 10) { (try? engine.runtime(sessionId: sessionId))??.presentation.label == "在线" },
            "a ready terminal must read 在线"
        )
        try expectEqual(engine.onlineCount(for: .temp), 1, "an online terminal is counted")

        // 2. A long command: the connection state stays put and a chip appears beside it.
        engine.send(text: "sleep 2\n", to: sessionId)
        try expect(
            waitForMain(timeout: 10) { (try? engine.runtime(sessionId: sessionId))??.isCommandRunning == true },
            "the command never went in flight"
        )
        let busy = try expectUnwrap(engine.runtime(sessionId: sessionId), "runtime while the command runs")
        try expectEqual(busy.presentation.label, "在线", "a running command must not take the state over")
        try expectEqual(busy.presentation.tone, .running, "the terminal card stays on the connection colour")
        try expectEqual(busy.presentation.badge, "执行中", "the running command shows as a chip")
        try expectEqual(engine.onlineCount(for: .temp), 1, "a busy terminal is still online")
        try expectEqual(engine.executingCount(for: .temp), 0, "a terminal never contributes to the task count")

        try expect(
            waitForMain(timeout: 20) { (try? engine.runtime(sessionId: sessionId))??.isCommandRunning == false },
            "the command never finished"
        )

        // 3. A failed command: the exit status is recorded, the card does not move.
        engine.send(text: "ls /runbo-no-such-directory\n", to: sessionId)
        try expect(
            waitForMain(timeout: 20) { (try? engine.runtime(sessionId: sessionId))??.lastCommandFailed == true },
            "the failing command was not attributed to the terminal"
        )
        let failed = try expectUnwrap(engine.runtime(sessionId: sessionId), "runtime after the failed command")
        try expectEqual(failed.lastCommandExitStatus, 1, "the failure is still recorded for the record")
        try expectEqual(failed.presentation.label, "在线", "a failed command leaves the terminal online")
        try expectEqual(failed.presentation.tone, .running, "a failed command must not turn the card red")
        try expectEqual(failed.presentation.badge, nil, "no result chip on a terminal card")
        try expectEqual(engine.onlineCount(for: .temp), 1, "the terminal is still online after a failure")

        // 4. The user closes it: no longer counted, and 未运行 rather than a failure.
        engine.endAllSessions(reason: .appQuit, timeout: 2.5)
        try expect(
            waitForMain(timeout: 15) { recorder.finish(sessionId: sessionId) != nil },
            "the engine never reported the terminal as finished"
        )
        try expectEqual(engine.onlineCount(for: .temp), 0, "a closed terminal is no longer online")
    }

    /// Even a fast command follows 正在启动 → 执行中 → 成功, without a 运行中 step.
    register("engine.fast-command-follows-task-flow") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("engine-fast-command")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let workdir = try TempSpace.subdirectory(root, "work")
        try TempSpace.write("", to: home.appendingPathComponent(".zshrc"))
        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let recorder = EngineRecorder()
        let engine = SessionEngine(
            store: store,
            shimRoot: root.appendingPathComponent("shims", isDirectory: true),
            delegate: recorder,
            baseEnvironment: hermeticBaseEnvironment(home: home)
        )
        defer { engine.endAllSessions(reason: .appQuit, timeout: 2.5) }

        let cardId = "engine-fast-command-card"
        try store.save(PresetCard(id: cardId, title: "Fast", command: "echo FAST_OK"))
        let runtime = try engine.start(
            kind: .preset,
            ownerId: cardId,
            title: "Fast",
            shell: "zsh",
            command: "echo FAST_OK",
            workingDirectory: workdir.path,
            environment: [:]
        )
        let sessionId = runtime.sessionId
        try expect(
            waitForMain(timeout: 20) { recorder.outputText(sessionId: sessionId).contains("FAST_OK") },
            "the fast command never produced output"
        )
        try expect(
            waitForMain(timeout: 15) { (try? engine.runtime(sessionId: sessionId))??.presentation.label == "成功" },
            "the fast command must end in 成功"
        )
        let labels = recorder.labels(sessionId: sessionId)
        try expect(labels.contains("运行中") == false, "shortcut cards must not show 运行中, saw: \(labels)")
        guard let executingIndex = labels.firstIndex(of: "执行中"),
              let successIndex = labels.lastIndex(of: "成功") else {
            throw CheckFailure("the fast command must show 执行中 and 成功, saw: \(labels)")
        }
        try expect(executingIndex < successIndex, "执行中 must precede 成功, saw: \(labels)")
    }

    /// The card describes the task: 正在启动 → 执行中 → 成功. A command that takes a
    /// moment must show 执行中 while it runs and 成功 once it exits with status 0.
    register("engine.command-in-flight-then-success") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("engine-in-flight")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let workdir = try TempSpace.subdirectory(root, "work")
        try TempSpace.write("", to: home.appendingPathComponent(".zshrc"))
        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let recorder = EngineRecorder()
        let engine = SessionEngine(
            store: store,
            shimRoot: root.appendingPathComponent("shims", isDirectory: true),
            delegate: recorder,
            baseEnvironment: hermeticBaseEnvironment(home: home)
        )
        defer { engine.endAllSessions(reason: .appQuit, timeout: 2.5) }

        let presetCommand = "sleep 2; echo IN_FLIGHT_DONE"
        let cardId = "engine-in-flight-card"
        try store.save(PresetCard(id: cardId, title: "In flight", command: presetCommand))
        let runtime = try engine.start(
            kind: .preset,
            ownerId: cardId,
            title: "In flight",
            shell: "zsh",
            command: presetCommand,
            workingDirectory: workdir.path,
            environment: [:]
        )
        let sessionId = runtime.sessionId
        try expect(
            waitForMain(timeout: 20) { (try? engine.runtime(sessionId: sessionId))??.isCommandRunning == true },
            "the submitted command must be in flight"
        )
        let running = try expectUnwrap(engine.runtime(sessionId: sessionId), "runtime while the command runs")
        try expectEqual(running.presentation.label, "执行中", "a running command shows 执行中")
        try expect(recorder.labels(sessionId: sessionId).contains("运行中") == false, "shortcut cards skip 运行中")
        try expectEqual(running.presentation.tone, .executing, "执行中 has its own visual state")
        try expectEqual(engine.executingCount(for: .preset), 1, "an executing command contributes one session")
        try expectEqual(engine.executingCount(for: .temp), 0, "the other menu keeps its own count")
        try expect(
            waitForMain(timeout: 20) { recorder.outputText(sessionId: sessionId).contains("IN_FLIGHT_DONE") },
            "the command never produced its output"
        )
        try expect(
            waitForMain(timeout: 15) {
                guard let current = (try? engine.runtime(sessionId: sessionId)) ?? nil else { return false }
                return current.isCommandRunning == false && current.presentation.label == "成功"
            },
            "after a successful command the card must show 成功"
        )
        let succeeded = try expectUnwrap(engine.runtime(sessionId: sessionId), "runtime after success")
        try expectEqual(succeeded.lastCommandFailed, false, "the command succeeded")
        try expectEqual(succeeded.lastCommandExitStatus, 0, "exit status 0")
        try expectEqual(succeeded.presentation.tone, .running, "成功 stays green")
        try expectEqual(engine.executingCount(for: .preset), 0, "a completed command is not counted while its shell stays alive")
    }

    /// A line that fails inside zsh's own expansion (for example a glob that matches
    /// nothing) never runs `preexec`, but it still reports a failure through `precmd`.
    /// That failure has to reach the card, otherwise the deck says "运行中" while the
    /// terminal shows an error.
    register("engine.expansion-failure-is-reported") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("engine-expansion-failure")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let workdir = try TempSpace.subdirectory(root, "work")
        try TempSpace.write("", to: home.appendingPathComponent(".zshrc"))
        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let recorder = EngineRecorder()
        let engine = SessionEngine(
            store: store,
            shimRoot: root.appendingPathComponent("shims", isDirectory: true),
            delegate: recorder,
            baseEnvironment: hermeticBaseEnvironment(home: home)
        )
        defer { engine.endAllSessions(reason: .appQuit, timeout: 2.5) }

        // An unquoted glob with no match aborts the line before it ever executes.
        let presetCommand = "echo *.runbo-no-such-file-xyz"
        let cardId = "engine-expansion-failure-card"
        try store.save(PresetCard(id: cardId, title: "Expansion failure", command: presetCommand))
        let runtime = try engine.start(
            kind: .preset,
            ownerId: cardId,
            title: "Expansion failure",
            shell: "zsh",
            command: presetCommand,
            workingDirectory: workdir.path,
            environment: [:]
        )
        let sessionId = runtime.sessionId
        try expect(
            waitForMain(timeout: 20) { recorder.outputText(sessionId: sessionId).contains("no matches found") },
            "the shell never reported the unmatched glob; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        try expect(
            waitForMain(timeout: 10) { (try? engine.runtime(sessionId: sessionId))??.lastCommandFailed == true },
            "a command that failed during expansion must mark the session as failed"
        )
        let failed = try expectUnwrap(engine.runtime(sessionId: sessionId), "runtime after the expansion failure")
        try expectEqual(failed.status, .running, "the shell is still alive, so the session stays running")
        try expectEqual(failed.lastCommandExitStatus, 1, "the exit status of the failed command line")
        try expectEqual(failed.presentation.label, "失败", "the card shows the failure as its main state")
        try expectEqual(failed.presentation.tone, .failed, "a failed command turns the card red")
        try expectEqual(engine.executingCount(for: .preset), 0, "a failed command is not counted while its shell stays alive")
        try expectEqual(failed.presentation.badge, nil, "no separate badge is needed once the state is 失败")

        // The recorded history keeps the same result.
        engine.send(text: "exit\n", to: sessionId)
        try expect(
            waitForMain(timeout: 15) { recorder.finish(sessionId: sessionId) != nil },
            "engine never delivered didFinish after the expansion failure"
        )
        try expect(
            waitFor(timeout: 5) { (try? store.session(id: sessionId))?.endedAt != nil },
            "the finished record was not persisted"
        )
        let stored = try expectUnwrap(try store.session(id: sessionId), "stored session")
        try expectEqual(stored.lastCommandFailed, true, "the stored record keeps the failure")
        try expectEqual(stored.lastCommandExitStatus, 1, "the stored record keeps the exit status")
    }

    register("engine.command-status-unknown-is-not-a-failure") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("engine-status-unknown")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let workdir = try TempSpace.subdirectory(root, "work")
        try TempSpace.write("", to: home.appendingPathComponent(".zshrc"))
        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let recorder = EngineRecorder()
        let engine = SessionEngine(
            store: store,
            shimRoot: root.appendingPathComponent("shims", isDirectory: true),
            delegate: recorder,
            baseEnvironment: hermeticBaseEnvironment(home: home)
        )
        defer { engine.endAllSessions(reason: .appQuit, timeout: 2.5) }

        let cardId = "engine-status-unknown-card"
        try store.save(PresetCard(id: cardId, title: "Status unknown", command: "echo FIRST_OK"))
        let runtime = try engine.start(
            kind: .preset,
            ownerId: cardId,
            title: "Status unknown",
            shell: "zsh",
            command: "echo FIRST_OK",
            workingDirectory: workdir.path,
            environment: [:]
        )
        let sessionId = runtime.sessionId
        try expect(
            waitForMain(timeout: 20) { recorder.outputText(sessionId: sessionId).contains("FIRST_OK") },
            "the session never ran its first command; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        try expect(
            waitForMain(timeout: 10) { engine.runtime(sessionId: sessionId)?.status == .running },
            "the session never reached .running"
        )
        // Baseline: the first command reported a real status.
        try expectEqual(engine.runtime(sessionId: sessionId)?.lastCommandStatusUnknown, false, "baseline result is known")
        try expectEqual(engine.runtime(sessionId: sessionId)?.lastCommandFailed, false, "baseline is not a failure")

        // The marker job below stays alive on purpose, and zsh refuses the first `exit` while
        // a background job is running (CHECK_JOBS), which would re-draw the prompt, run precmd
        // and clear the flag before we could persist it. Turning the option off up front keeps
        // the exit path usable without an intervening prompt hook.
        engine.send(text: "unsetopt check_jobs\n", to: sessionId)
        try expect(
            waitForMain(timeout: 10) { engine.runtime(sessionId: sessionId)?.status == .running },
            "the session stopped running while disabling CHECK_JOBS"
        )
        pumpMainRunLoop(0.4)

        // Inject `cmdend;?` from *inside* the shell, 2 seconds after the typed line's own
        // prompt hook already reported cmdend;0, so it arrives as the newest command result.
        sendUnknownStatusMarker(engine, sessionId: sessionId)
        try expect(
            waitForMain(timeout: 15) { engine.runtime(sessionId: sessionId)?.lastCommandStatusUnknown == true },
            "the cmdend;? marker never reached the runtime; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        let unknown = try expectUnwrap(engine.runtime(sessionId: sessionId), "runtime with an unknown command result")
        try expectEqual(unknown.status, .running, "an unknown result must not stop the session")
        try expectEqual(unknown.lastCommandFailed, false, "an unknown result must never be reported as a failure")
        try expectEqual(unknown.lastCommandExitStatus, nil, "an unknown result carries no exit status")
        try expectEqual(unknown.isCommandRunning, false, "the command is no longer in flight")
        try expectEqual(unknown.presentation.label, "结果未知", "an unreadable result is its own task state")
        try expectEqual(unknown.presentation.tone, .running, "不把未知当成失败，仍是可用的绿色")
        try expectEqual(unknown.presentation.badge, nil, "the state itself carries the meaning, no badge")
        try expect(
            containsSubsequence(recorder.output(sessionId: sessionId), tdMarkerPrefixBytes) == false,
            "the injected marker bytes leaked into the delivered visible output"
        )

        // A following successful command replaces the unknown result.
        engine.send(text: "echo KNOWN_AGAIN\n", to: sessionId)
        try expect(
            waitForMain(timeout: 15) { engine.runtime(sessionId: sessionId)?.lastCommandStatusUnknown == false },
            "a successful command must clear the unknown flag"
        )
        try expectEqual(engine.runtime(sessionId: sessionId)?.lastCommandFailed, false, "a successful command is not a failure")
        try expectEqual(engine.runtime(sessionId: sessionId)?.lastCommandExitStatus, 0, "the exit status is known again")

        // Re-arm the unknown result and exit while it is current: the persisted record must
        // carry the flag rather than silently turning it into a failure.
        sendUnknownStatusMarker(engine, sessionId: sessionId)
        try expect(
            waitForMain(timeout: 15) { engine.runtime(sessionId: sessionId)?.lastCommandStatusUnknown == true },
            "the second cmdend;? marker never reached the runtime"
        )
        engine.send(text: "exit\n", to: sessionId)
        try expect(
            waitForMain(timeout: 15) { recorder.finish(sessionId: sessionId) != nil },
            "the engine never delivered didFinish; output: \(preview(recorder.outputText(sessionId: sessionId)))"
        )
        let record = try expectUnwrap(recorder.finish(sessionId: sessionId), "didFinish record")
        try expectEqual(record.lastCommandStatusUnknown, true, "the didFinish record carries the unknown marker")
        try expectEqual(record.lastCommandFailed, false, "the unknown marker is not a failure in the record")
        try expectEqual(record.unexpectedExit, false, "an unknown command result is not an unexpected exit")
        try expect(
            waitFor(timeout: 5) { (try? store.session(id: sessionId))?.lastCommandStatusUnknown == true },
            "the persisted record must carry the unknown marker"
        )
        let stored = try expectUnwrap(try store.session(id: sessionId), "stored session")
        try expectEqual(stored.lastCommandStatusUnknown, true, "stored lastCommandStatusUnknown")
        try expectEqual(stored.lastCommandFailed, false, "stored lastCommandFailed")
        try expect(stored.endedAt != nil, "the session was persisted as finished")
    }
}

/// Makes the shell emit `ESC ] 1337 ; TerminalDeck ; cmdend ; ? BEL` *after* its own prompt
/// hook has reported the typed line, so the engine sees an unreadable status as the newest
/// result. The trailing `sleep 30` keeps the background job alive: if it exited, zsh would
/// print a job-completion notice and run `precmd` again, immediately clearing the flag.
private func sendUnknownStatusMarker(_ engine: SessionEngine, sessionId: String) {
    engine.send(text: "(sleep 2; printf '\\033]1337;TerminalDeck;cmdend;?\\007'; sleep 30) &\n", to: sessionId)
}

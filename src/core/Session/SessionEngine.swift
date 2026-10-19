import Foundation

/// Identifies the card or temporary terminal a session belongs to.
public struct OwnerKey: Hashable, Sendable {
    public let kind: SessionKind
    public let ownerId: String

    public init(kind: SessionKind, ownerId: String) {
        self.kind = kind
        self.ownerId = ownerId
    }
}

/// Everything the UI needs to draw one live session.
public struct SessionRuntime: Equatable, Sendable {
    public var sessionId: String
    public var key: OwnerKey
    public var title: String
    public var shell: String
    public var workingDirectory: String?
    public var status: SessionStatus
    public var lastCommandFailed: Bool
    /// The last command ran but the shell could not report its status.
    public var lastCommandStatusUnknown: Bool
    public var lastCommandExitStatus: Int32?
    public var launchFailureMessage: String?
    /// Set when a normal stop was requested but the process is still alive.
    public var needsForceTermination: Bool
    public var startedAt: Date
    /// `true` once the shell reported that its interactive configuration loaded.
    public var isReady: Bool
    /// `true` while a submitted command line is still running in the shell.
    public var isCommandRunning: Bool
    public var lastCommandText: String?

    /// Public so the card-state rules can be asserted directly, without starting a shell.
    public init(
        sessionId: String,
        key: OwnerKey,
        title: String,
        shell: String,
        workingDirectory: String? = nil,
        status: SessionStatus,
        lastCommandFailed: Bool,
        lastCommandStatusUnknown: Bool,
        lastCommandExitStatus: Int32? = nil,
        launchFailureMessage: String? = nil,
        needsForceTermination: Bool,
        startedAt: Date,
        isReady: Bool,
        isCommandRunning: Bool,
        lastCommandText: String? = nil
    ) {
        self.sessionId = sessionId
        self.key = key
        self.title = title
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.status = status
        self.lastCommandFailed = lastCommandFailed
        self.lastCommandStatusUnknown = lastCommandStatusUnknown
        self.lastCommandExitStatus = lastCommandExitStatus
        self.launchFailureMessage = launchFailureMessage
        self.needsForceTermination = needsForceTermination
        self.startedAt = startedAt
        self.isReady = isReady
        self.isCommandRunning = isCommandRunning
        self.lastCommandText = lastCommandText
    }

    /// True when the shell is running and has loaded its interactive configuration, which
    /// is what a temporary terminal's "在线" means. Deliberately independent of any command:
    /// an idle terminal and one running a long build are both reachable.
    public var isReachable: Bool { isReady && status == .running }

    public var presentation: SessionStatusPresentation {
        switch key.kind {
        case .preset: return presetPresentation
        case .temp: return tempPresentation
        }
    }

    /// A preset card describes **this task's** progress: starting, executing, then a result.
    /// The chip carries the results the shell could not decide (失败 / 结果未知).
    private var presetPresentation: SessionStatusPresentation {
        switch status {
        case .starting:
            return SessionStatusPresentation(label: "正在启动", tone: .busy)
        case .running:
            if isCommandRunning {
                return SessionStatusPresentation(label: "执行中", tone: .executing)
            }
            if lastCommandFailed {
                return SessionStatusPresentation(label: "失败", tone: .failed)
            }
            if lastCommandStatusUnknown {
                // "结果未知" is the whole message; a chip repeating "未知" adds nothing.
                return SessionStatusPresentation(label: "结果未知", tone: .running)
            }
            if lastCommandExitStatus != nil {
                return SessionStatusPresentation(label: "成功", tone: .running)
            }
            // The shell is ready but the preset command has not reported yet.
            return SessionStatusPresentation(label: "正在启动", tone: .busy)
        case .stopping:
            guard needsForceTermination else {
                return SessionStatusPresentation(label: "正在终止", tone: .busy)
            }
            return SessionStatusPresentation(label: "正在终止", tone: .busy, badge: "无响应", badgeTone: .failure)
        case .stopped:
            return SessionStatusPresentation(label: "未运行", tone: .idle)
        case .failed:
            if launchFailureMessage != nil {
                return SessionStatusPresentation(label: "启动失败", tone: .failed)
            }
            return SessionStatusPresentation(label: "意外退出", tone: .failed)
        }
    }

    /// A temporary terminal describes **the terminal itself** — whether it is still usable.
    /// Command results do not move this state at all: a failed command leaves the shell
    /// just as usable, so the card stays green. "Something is running" rides along in the
    /// chip instead of taking the state over.
    private var tempPresentation: SessionStatusPresentation {
        let busy = isCommandRunning ? SessionStatusPresentation.BadgeKind.busy : nil
        switch status {
        case .starting:
            return SessionStatusPresentation(label: "正在启动", tone: .busy)
        case .running:
            return SessionStatusPresentation(label: "在线", tone: .running, badge: busy == nil ? nil : "执行中", badgeKind: busy)
        case .stopping:
            guard needsForceTermination else {
                return SessionStatusPresentation(label: "正在结束", tone: .busy)
            }
            return SessionStatusPresentation(label: "正在结束", tone: .busy, badge: "无响应", badgeTone: .failure)
        case .stopped:
            // "未运行" would promise a restart this card cannot offer: a temporary terminal
            // is an ad-hoc interactive shell, and once it ends the card only has 详情 and
            // 删除. The shell being gone is the end of the terminal, so say so.
            return SessionStatusPresentation(label: "已失效", tone: .idle)
        case .failed:
            if launchFailureMessage != nil {
                return SessionStatusPresentation(label: "启动失败", tone: .failed)
            }
            return SessionStatusPresentation(label: "意外退出", tone: .failed)
        }
    }
}

public protocol SessionEngineDelegate: AnyObject {
    /// Visible terminal bytes for a session (markers already stripped).
    func engine(_ engine: SessionEngine, didProduceOutput sessionId: String, bytes: [UInt8])
    /// Runtime state changed (status, command result, force-termination hint...).
    func engine(_ engine: SessionEngine, didUpdate runtime: SessionRuntime)
    /// The session ended and its history is flushed.
    func engine(_ engine: SessionEngine, didFinish session: SessionRecord)
    /// Saving history failed; the session keeps running but the record is incomplete.
    func engine(_ engine: SessionEngine, didFailToRecord message: String)
}

/// Owns PTY sessions, the state machine that maps shell events to card status, and
/// the append-only history writes.
/// Thread safety: all mutable state is guarded by `lock`, and persistence/activity
/// work runs on dedicated serial queues, so the engine is safe to hand to other queues.
public final class SessionEngine: @unchecked Sendable {
    /// How long we wait for the shell's readiness marker before typing the preset
    /// command anyway. The command is buffered by the tty, so this is safe.
    public static let readinessTimeout: TimeInterval = 10
    /// How long a normal stop may take before the UI offers a forced stop.
    public static let normalStopGrace: TimeInterval = 3
    private let store: DataStore
    private let shimRoot: URL
    public weak var delegate: SessionEngineDelegate?

    private let lock = NSRecursiveLock()
    private var sessions: [String: PTYSession] = [:]
    private var runtimesBySession: [String: SessionRuntime] = [:]
    private var recordsBySession: [String: SessionRecord] = [:]
    private var sequenceBySession: [String: Int64] = [:]
    private var pendingOutput: [String: [UInt8]] = [:]
    private var stopRequested: Set<String> = []
    private var forceRequested: Set<String> = []
    private var quitting = false
    private var firstCommandSent: Set<String> = []
    /// Sessions where the user (or the preset command) has submitted at least one line.
    /// Submitting a line is the trigger for attributing `cmdend` results, not the
    /// `preexec` hook: a line that fails during zsh's glob/parse stage never runs
    /// `preexec`, yet it still reports a failure through `precmd`, and that failure must
    /// reach the card. The very first prompt hook arrives before any input, so it is
    /// never mistaken for a command result. The flag stays set for the session so a
    /// late status report (for example an injected or delayed marker) is still applied.
    private var commandExpected: Set<String> = []

    private let persistenceQueue = DispatchQueue(label: "runbo.persistence")
    private let activityQueue = DispatchQueue(label: "runbo.activity")
    private var lastTouch: [String: Date] = [:]
    private var drainTimer: DispatchSourceTimer?
    private var readinessTimers: [String: DispatchSourceTimer] = [:]
    private var stopTimers: [String: DispatchSourceTimer] = [:]
    private var historyFailureReported = false
    private var finalizingSessions: [String: OwnerKey] = [:]
    private var discardedSessions: Set<String> = []

    /// Environment every session starts from (the app's environment by default).
    public var baseEnvironment: [String: String]

    public init(
        store: DataStore,
        shimRoot: URL,
        delegate: SessionEngineDelegate? = nil,
        baseEnvironment: [String: String] = ShellShims.baseEnvironment()
    ) {
        self.store = store
        self.shimRoot = shimRoot
        self.delegate = delegate
        self.baseEnvironment = baseEnvironment
        _ = try? StoragePaths.ensureDirectory(shimRoot)
        startDrainTimer()
    }

    deinit {
        drainTimer?.cancel()
    }

    // MARK: - State access

    public var allRuntimes: [SessionRuntime] {
        lock.lock(); defer { lock.unlock() }
        return Array(runtimesBySession.values)
    }

    public func runtime(for key: OwnerKey) -> SessionRuntime? {
        lock.lock(); defer { lock.unlock() }
        return runtimesBySession.values.first { $0.key == key && $0.status.isAlive }
    }

    /// Live session for an owner, newest first; includes sessions that are stopping.
    public func liveRuntimes(for key: OwnerKey) -> [SessionRuntime] {
        lock.lock(); defer { lock.unlock() }
        return runtimesBySession.values
            .filter { $0.key == key && $0.status.isAlive }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func runtime(sessionId: String) -> SessionRuntime? {
        lock.lock(); defer { lock.unlock() }
        return runtimesBySession[sessionId]
    }

    /// Navigation-only cwd; never changes the card's configured launch directory.
    public func currentWorkingDirectory(sessionId: String) -> String? {
        lock.lock()
        let session = sessions[sessionId]
        lock.unlock()
        return session?.currentWorkingDirectory
    }

    public var runningCount: Int {
        lock.lock(); defer { lock.unlock() }
        return runtimesBySession.values.filter { $0.status == .running || $0.status == .starting }.count
    }

    /// Count sessions whose cards currently show 执行中. Completed commands may
    /// leave an interactive shell alive, but no longer contribute to this count.
    ///
    /// This is the preset menu's meaning: "how many tasks are running right now".
    public func executingCount(for kind: SessionKind) -> Int {
        lock.lock(); defer { lock.unlock() }
        return runtimesBySession.values.filter {
            $0.key.kind == kind && $0.presentation.tone == .executing
        }.count
    }

    /// Count sessions whose shell is online and ready for input, whatever they are doing.
    ///
    /// This is the temporary-terminal menu's meaning: "how many terminals do I still have
    /// open". A terminal running a long command still counts; one the user closed does not.
    public func onlineCount(for kind: SessionKind) -> Int {
        lock.lock(); defer { lock.unlock() }
        return runtimesBySession.values.filter { $0.key.kind == kind && $0.isReachable }.count
    }

    public var isQuitting: Bool {
        lock.lock(); defer { lock.unlock() }
        return quitting
    }

    // MARK: - Starting sessions

    public func start(
        kind: SessionKind,
        ownerId: String,
        title: String,
        shell: String,
        command: String?,
        workingDirectory: String?,
        environment: [String: String]
    ) throws -> SessionRuntime {
        let sessionId = UUID().uuidString
        let plan = try ShellShims.makeLaunchPlan(
            shell: shell,
            firstCommand: command,
            workingDirectory: workingDirectory,
            extraEnvironment: environment,
            shimRoot: shimRoot,
            sessionId: sessionId,
            baseEnvironment: baseEnvironment
        )

        var record = SessionRecord(
            id: sessionId,
            kind: kind,
            ownerId: ownerId,
            title: title,
            shell: plan.executable,
            workingDirectory: plan.workingDirectory,
            startedAt: Date(),
            lastCommandText: command
        )
        do {
            try store.save(record)
        } catch {
            reportHistoryFailure("\(error)")
        }

        var runtime = SessionRuntime(
            sessionId: sessionId,
            key: OwnerKey(kind: kind, ownerId: ownerId),
            title: title,
            shell: plan.executable,
            workingDirectory: plan.workingDirectory,
            status: .starting,
            lastCommandFailed: false,
            lastCommandStatusUnknown: false,
            lastCommandExitStatus: nil,
            launchFailureMessage: nil,
            needsForceTermination: false,
            startedAt: record.startedAt,
            isReady: false,
            isCommandRunning: false,
            lastCommandText: command
        )

        let session = PTYSession(id: sessionId, plan: plan)
        session.onEvent = { [weak self] event in
            self?.handle(event, sessionId: sessionId)
        }

        lock.lock()
        // The previous ended runtime for this owner has already been delivered to the UI
        // (AppModel keeps the latest one per card). Do not let one stopped runtime per run
        // accumulate in the engine for the whole App lifetime.
        let staleRuntimes = runtimesBySession.filter { id, existing in
            id != sessionId && existing.key == runtime.key && !existing.status.isAlive
        }.map(\.key)
        for id in staleRuntimes { runtimesBySession[id] = nil }
        sessions[sessionId] = session
        runtimesBySession[sessionId] = runtime
        recordsBySession[sessionId] = record
        sequenceBySession[sessionId] = (try? store.nextSequence(sessionId: sessionId)) ?? 0
        lock.unlock()

        do {
            try session.start()
        } catch {
            session.close()
            record.launchFailed = true
            record.endedAt = Date()
            record.termination = .launchFailed
            do {
                try store.save(record)
            } catch {
                reportHistoryFailure("\(error)")
            }
            runtime.status = .failed
            runtime.launchFailureMessage = "\(error)"
            lock.lock()
            runtimesBySession[sessionId] = runtime
            lock.unlock()
            notify(runtime)
            throw error
        }

        // The new running session is "this run", so only one finished predecessor may stay.
        do {
            try store.trimHistory(kind: kind, ownerId: ownerId,
                                  limit: max(0, RetentionPolicy.sessionHistoryLimit - 1))
        } catch {
            reportHistoryFailure("\(error)")
        }
        scheduleReadinessTimeout(sessionId: sessionId)
        return runtime
    }

    /// Idempotent start helper used by the workbench and by auto-run at launch.
    @discardableResult
    public func startIfNotRunning(
        kind: SessionKind,
        ownerId: String,
        title: String,
        shell: String,
        command: String?,
        workingDirectory: String?,
        environment: [String: String]
    ) -> SessionRuntime? {
        let key = OwnerKey(kind: kind, ownerId: ownerId)
        if runtime(for: key) != nil { return nil }
        return try? start(
            kind: kind,
            ownerId: ownerId,
            title: title,
            shell: shell,
            command: command,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }

    // MARK: - Input

    public func send(bytes: [UInt8], to sessionId: String) {
        lock.lock()
        let session = sessions[sessionId]
        let runtime = runtimesBySession[sessionId]
        let ownerKey = runtime?.key
        if bytes.contains(0x0A) || bytes.contains(0x0D) {
            // A submitted line always produces a prompt hook, even when it fails before
            // executing, so its status must be attributed to the card.
            commandExpected.insert(sessionId)
        }
        lock.unlock()
        if bytes.contains(0x0A) || bytes.contains(0x0D) {
            markCommandStarted(sessionId: sessionId)
        }
        guard let session, session.isRunning else { return }
        session.write(bytes)
        if let ownerKey { noteActivity(for: ownerKey) }
    }

    public func send(text: String, to sessionId: String) {
        send(bytes: Array(text.utf8), to: sessionId)
    }

    public func resize(sessionId: String, cols: Int, rows: Int) {
        lock.lock()
        let session = sessions[sessionId]
        lock.unlock()
        guard let session else { return }
        session.resize(cols: cols, rows: rows)
        let event = SessionEvent(
            sessionId: sessionId,
            sequence: nextSequence(sessionId),
            kind: .resize,
            cols: cols,
            rows: rows
        )
        record([event])
    }

    // MARK: - Stopping

    public func stop(sessionId: String) {
        lock.lock()
        let session = sessions[sessionId]
        var runtime = runtimesBySession[sessionId]
        stopRequested.insert(sessionId)
        if runtime != nil {
            runtime?.status = .stopping
            runtimesBySession[sessionId] = runtime
        }
        lock.unlock()
        guard let session, session.isRunning, let stopping = runtime else { return }
        notify(stopping)
        session.requestTermination()

        // After the grace period the session is still alive: surface the force action.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + SessionEngine.normalStopGrace)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alive = self.sessions[sessionId]?.isRunning ?? false
            var current = self.runtimesBySession[sessionId]
            self.lock.unlock()
            guard alive, current != nil else { return }
            current?.needsForceTermination = true
            if let current {
                self.lock.lock()
                self.runtimesBySession[sessionId] = current
                self.lock.unlock()
                self.notify(current)
            }
        }
        timer.resume()
        lock.lock()
        stopTimers[sessionId]?.cancel()
        stopTimers[sessionId] = timer
        lock.unlock()
    }

    public func forceStop(sessionId: String) {
        lock.lock()
        let session = sessions[sessionId]
        forceRequested.insert(sessionId)
        stopTimers.removeValue(forKey: sessionId)?.cancel()
        var runtime = runtimesBySession[sessionId]
        lock.unlock()
        guard let session else { return }
        runtime?.needsForceTermination = false
        runtime?.status = .stopping
        if let runtime {
            lock.lock()
            runtimesBySession[sessionId] = runtime
            lock.unlock()
            notify(runtime)
        }
        session.forceTermination()
    }

    /// Stops every session, waiting for the shells to exit, then forcing what is left.
    public func endAllSessions(reason: TerminationReason = .appQuit, timeout: TimeInterval = 2.5) {
        lock.lock()
        quitting = true
        let active = sessions.filter { $0.value.isRunning }
        lock.unlock()
        guard !active.isEmpty else { return }
        for (id, session) in active {
            lock.lock(); stopRequested.insert(id); lock.unlock()
            session.requestTermination()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let stillRunning = sessions.contains { $0.value.isRunning }
            lock.unlock()
            if !stillRunning { break }
            usleep(60_000)
        }
        for (id, session) in active where session.isRunning {
            lock.lock(); forceRequested.insert(id); lock.unlock()
            session.forceTermination()
            session.waitForExit(timeout: 1.0)
        }
        // Flush anything still queued.
        persistenceQueue.sync {}
    }

    /// Targeted removal is not App shutdown. Finish only these owners, then fence history
    /// persistence so late output/resize callbacks cannot recreate deleted session events.
    /// Run off the main thread; delegates may still be queued when this returns.
    public func prepareForRemoval(_ keys: Set<OwnerKey>, timeout: TimeInterval = 3) -> Set<OwnerKey> {
        lock.lock()
        let targets = sessions.filter { id, _ in
            runtimesBySession[id].map { keys.contains($0.key) } ?? false
        }
        lock.unlock()
        for (id, session) in targets where session.isRunning {
            lock.lock(); stopRequested.insert(id); lock.unlock()
            session.requestTermination()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while targets.values.contains(where: { $0.isRunning }), Date() < deadline { usleep(20_000) }
        for (id, session) in targets where session.isRunning {
            lock.lock(); forceRequested.insert(id); lock.unlock()
            session.forceTermination()
        }
        let forcedDeadline = Date().addingTimeInterval(2)
        while targets.values.contains(where: { $0.isRunning }), Date() < forcedDeadline { usleep(20_000) }
        // handleExit removes the PTY before submitting its final write. Wait for that entire
        // finalization, not just isRunning == false, before placing the persistence fence.
        let finalDeadline = Date().addingTimeInterval(2)
        var successful: Set<OwnerKey> = []
        repeat {
            lock.lock()
            successful = keys.filter { key in
                !sessions.contains { id, session in
                    runtimesBySession[id]?.key == key && session.isRunning
                } && !runtimesBySession.values.contains { $0.key == key && $0.status.isAlive }
                    && !finalizingSessions.values.contains(key)
            }
            lock.unlock()
            if successful.count == keys.count { break }
            usleep(20_000)
        } while Date() < finalDeadline
        lock.lock()
        for (id, runtime) in runtimesBySession where successful.contains(runtime.key) {
            discardedSessions.insert(id)
        }
        lock.unlock()
        persistenceQueue.sync {}
        activityQueue.sync {}
        return successful
    }

    public func forgetRemovedOwner(_ key: OwnerKey) {
        lock.lock(); defer { lock.unlock() }
        lastTouch[key.ownerId] = nil
        let ids = runtimesBySession.filter { $0.value.key == key }.map(\.key)
        for id in ids {
            runtimesBySession[id] = nil
            recordsBySession[id] = nil
            sequenceBySession[id] = nil
            pendingOutput[id] = nil
            sessions.removeValue(forKey: id)?.close()
            readinessTimers.removeValue(forKey: id)?.cancel()
            stopTimers.removeValue(forKey: id)?.cancel()
            firstCommandSent.remove(id)
            commandExpected.remove(id)
            stopRequested.remove(id)
            forceRequested.remove(id)
        }
    }

    private func isDiscarded(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return discardedSessions.contains(id)
    }

    // MARK: - Event handling

    private func handle(_ event: PTYSession.Event, sessionId: String) {
        switch event {
        case .output(let bytes):
            lock.lock()
            // The reader thread can deliver a final chunk after the reaper has already
            // finalized the session. Do not recreate history or backlog for it.
            guard sessions[sessionId] != nil else { lock.unlock(); return }
            pendingOutput[sessionId, default: []].append(contentsOf: bytes)
            let runtime = runtimesBySession[sessionId]
            lock.unlock()
            if let runtime { noteActivity(for: runtime.key) }
        case .signal(let signal):
            handle(signal: signal, sessionId: sessionId)
        case .exited(let status, let signal, let wasRunning):
            handleExit(sessionId: sessionId, status: status, signal: signal, wasRunning: wasRunning)
        case .launchFailed(let message):
            fail(sessionId: sessionId, message: message)
        }
    }

    private func handle(signal: SessionSignal, sessionId: String) {
        switch signal {
        case .ready:
            lock.lock()
            var runtime = runtimesBySession[sessionId]
            let session = sessions[sessionId]
            runtime?.isReady = true
            if runtime?.status == .starting { runtime?.status = .running }
            let alreadySent = firstCommandSent.contains(sessionId)
            runtimesBySession[sessionId] = runtime
            lock.unlock()
            if let updated = runtime {
                notify(updated)
            }
            // The preset command is typed once the interactive configuration is loaded.
            // A short settle delay lets the shell draw its first prompt, so the echoed
            // command lands on the prompt line instead of above it; this is a settle
            // window after a real readiness signal, not a guess at startup time.
            if !alreadySent, let command = session?.plan.firstCommand, !command.isEmpty {
                firstCommandSent.insert(sessionId)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let alive = self.sessions[sessionId]?.isRunning ?? false
                    self.lock.unlock()
                    guard alive else { return }
                    self.send(text: command + "\n", to: sessionId)
                }
            }
        case .commandStarted:
            lock.lock()
            commandExpected.insert(sessionId)
            lock.unlock()
            markCommandStarted(sessionId: sessionId)
        case .commandFinished(let exitStatus):
            lock.lock()
            guard var record = recordsBySession[sessionId] else { lock.unlock(); return }
            // Ignore the status reported by the very first prompt before any command ran.
            let sawCommand = commandExpected.contains(sessionId)
            _ = markCommandFinished(sessionId: sessionId)
            if sawCommand {
                record.lastCommandExitStatus = exitStatus
                // An unreadable status must never be reported as a failure.
                record.lastCommandFailed = (exitStatus ?? 0) != 0
                record.lastCommandStatusUnknown = exitStatus == nil
                recordsBySession[sessionId] = record
            }
            var runtime = runtimesBySession[sessionId]
            if sawCommand {
                runtime?.lastCommandExitStatus = exitStatus
                runtime?.lastCommandFailed = (exitStatus ?? 0) != 0
                runtime?.lastCommandStatusUnknown = exitStatus == nil
            }
            runtimesBySession[sessionId] = runtime
            lock.unlock()
            if sawCommand {
                saveInBackground(record)
            }
            if let runtime { notify(runtime) }
        }
    }

    private func handleExit(sessionId: String, status: Int32, signal: Int32?, wasRunning: Bool) {
        lock.lock()
        let record = recordsBySession[sessionId]
        var runtime = runtimesBySession[sessionId]
        let forced = forceRequested.contains(sessionId)
        let requested = stopRequested.contains(sessionId)
        let isQuitting = quitting
        let pending = pendingOutput.removeValue(forKey: sessionId) ?? []
        if let key = runtime?.key { finalizingSessions[sessionId] = key }
        sessions.removeValue(forKey: sessionId)
        runtimesBySession.removeValue(forKey: sessionId)
        readinessTimers.removeValue(forKey: sessionId)?.cancel()
        stopTimers.removeValue(forKey: sessionId)?.cancel()
        commandExpected.remove(sessionId)
        firstCommandSent.remove(sessionId)
        lock.unlock()

        if !pending.isEmpty {
            deliverOutput(sessionId: sessionId, bytes: pending)
        }

        guard var finished = record else {
            lock.lock()
            finalizingSessions[sessionId] = nil
            sequenceBySession[sessionId] = nil
            lock.unlock()
            return
        }
        finished.endedAt = Date()

        if forced {
            finished.termination = .forced
        } else if requested {
            finished.termination = .normal
        } else if isQuitting {
            finished.termination = .appQuit
        } else {
            finished.termination = .exited
        }

        // "Normal stop" = the user asked for it, the app is quitting, or the shell
        // exited cleanly by itself (`exit`). Everything else is a failure.
        let cleanExit = signal == nil && status == 0
        let failedUnexpectedly = !forced && !requested && !isQuitting && !cleanExit
        finished.unexpectedExit = failedUnexpectedly
        if failedUnexpectedly && !wasRunning {
            finished.launchFailed = true
        }
        if failedUnexpectedly {
            runtime?.launchFailureMessage = wasRunning
                ? nil
                : "shell 在交互配置加载完成前退出（退出码 \(status)）"
        }
        if let runtime {
            var updated = runtime
            updated.status = failedUnexpectedly ? .failed : .stopped
            updated.needsForceTermination = false
            finished.lastCommandFailed = updated.lastCommandFailed
            finished.lastCommandStatusUnknown = updated.lastCommandStatusUnknown
            self.lock.lock()
            // Keep the newest final state for tests and the UI, but only one stopped
            // runtime per owner. Older runs are represented by the persisted record.
            let staleRuntimes = runtimesBySession.filter { id, existing in
                id != sessionId && existing.key == updated.key && !existing.status.isAlive
            }.map(\.key)
            for id in staleRuntimes { runtimesBySession[id] = nil }
            runtimesBySession[sessionId] = updated
            self.lock.unlock()
            notify(updated)
        }

        let finalRecord = finished
        persistenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.store.save(finalRecord)
                try self.store.trimHistory(kind: finalRecord.kind, ownerId: finalRecord.ownerId)
            } catch {
                self.reportHistoryFailure("\(error)")
            }
            DispatchQueue.main.async {
                self.delegate?.engine(self, didFinish: finalRecord)
            }
            self.lock.lock()
            self.finalizingSessions[sessionId] = nil
            self.sequenceBySession[sessionId] = nil
            self.lock.unlock()
        }

        ShimsCleanup.markForRemoval(sessionId: sessionId, shimRoot: shimRoot)

        // Keep the finished runtime visible briefly so the card can show the final
        // state; the UI removes it when the next session starts or on refresh.
        lock.lock()
        recordsBySession.removeValue(forKey: sessionId)
        lock.unlock()
    }

    private func fail(sessionId: String, message: String) {
        lock.lock()
        var runtime = runtimesBySession[sessionId]
        runtime?.status = .failed
        runtime?.launchFailureMessage = message
        if let runtime { runtimesBySession[sessionId] = runtime }
        lock.unlock()
        if let runtime { notify(runtime) }
    }

    // MARK: - Command in-flight tracking

    /// Publish 执行中 as soon as a command is submitted, including fast commands.
    private func markCommandStarted(sessionId: String) {
        lock.lock()
        var runtime = runtimesBySession[sessionId]
        if runtime?.isCommandRunning != true {
            runtime?.isCommandRunning = true
            if let runtime { runtimesBySession[sessionId] = runtime }
        } else {
            runtime = nil
        }
        lock.unlock()
        if let runtime { notify(runtime) }
    }

    /// Clears the in-flight state when the shell reports a result.
    @discardableResult
    private func markCommandFinished(sessionId: String) -> SessionRuntime? {
        lock.lock()
        var runtime = runtimesBySession[sessionId]
        runtime?.isCommandRunning = false
        if let runtime { runtimesBySession[sessionId] = runtime }
        lock.unlock()
        return runtime
    }

    // MARK: - Output delivery

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.03, repeating: 0.03, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drainOutput() }
        timer.resume()
        drainTimer = timer
    }

    private func drainOutput() {
        lock.lock()
        let batch = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !batch.isEmpty else { return }
        for (sessionId, bytes) in batch {
            deliverOutput(sessionId: sessionId, bytes: bytes)
        }
    }

    private func deliverOutput(sessionId: String, bytes: [UInt8]) {
        let event = SessionEvent(sessionId: sessionId, sequence: nextSequence(sessionId), kind: .output, data: Data(bytes))
        record([event])
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didProduceOutput: sessionId, bytes: bytes)
        }
    }

    private func nextSequence(_ sessionId: String) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let next = (sequenceBySession[sessionId] ?? 0)
        sequenceBySession[sessionId] = next + 1
        return next
    }

    /// Persists a session row off the main thread, reporting write failures once.
    private func saveInBackground(_ record: SessionRecord) {
        persistenceQueue.async { [weak self] in
            guard let self, !self.isDiscarded(record.id) else { return }
            do {
                try self.store.save(record)
            } catch {
                self.reportHistoryFailure("\(error)")
            }
        }
    }

    private func record(_ events: [SessionEvent]) {
        persistenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.store.append(events.filter { !self.isDiscarded($0.sessionId) })
            } catch {
                self.reportHistoryFailure("\(error)")
            }
        }
    }

    private func reportHistoryFailure(_ message: String) {
        lock.lock()
        let alreadyReported = historyFailureReported
        historyFailureReported = true
        lock.unlock()
        guard !alreadyReported else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didFailToRecord: message)
        }
    }

    // MARK: - Activity tracking (24 hour expiry clock)

    private func noteActivity(for key: OwnerKey) {
        guard key.kind == .temp else { return }
        let now = Date()
        activityQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let last = self.lastTouch[key.ownerId] ?? .distantPast
            let shouldWrite = now.timeIntervalSince(last) > 5
            if shouldWrite { self.lastTouch[key.ownerId] = now }
            self.lock.unlock()
            guard shouldWrite else { return }
            try? self.store.touchTemp(id: key.ownerId, at: now)
        }
    }

    // MARK: - Readiness timeout

    private func scheduleReadinessTimeout(sessionId: String) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + SessionEngine.readinessTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let runtime = self.runtimesBySession[sessionId]
            let session = self.sessions[sessionId]
            let alreadySent = self.firstCommandSent.contains(sessionId)
            self.lock.unlock()
            guard let runtime, runtime.status == .starting || !runtime.isReady else { return }
            guard let session, session.isRunning else { return }
            // Readiness marker never arrived: keep the session usable and note it.
            if let command = session.plan.firstCommand, !command.isEmpty, !alreadySent {
                self.firstCommandSent.insert(sessionId)
                self.send(text: command + "\n", to: sessionId)
            }
            self.lock.lock()
            var updated = self.runtimesBySession[sessionId]
            updated?.status = .running
            if let updated { self.runtimesBySession[sessionId] = updated }
            self.lock.unlock()
            if let updated { self.notify(updated) }
        }
        timer.resume()
        lock.lock()
        readinessTimers[sessionId]?.cancel()
        readinessTimers[sessionId] = timer
        lock.unlock()
    }

    private func notify(_ runtime: SessionRuntime) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didUpdate: runtime)
        }
    }

    // MARK: - Startup reconciliation and cleanup

    /// Sessions left open by a crash are closed out: the app never resumes shells.
    public func reconcileLeftovers(now: Date = Date()) {
        guard let leftovers = try? store.unfinishedSessions() else { return }
        for var record in leftovers {
            record.endedAt = now
            record.termination = .interrupted
            try? store.save(record)
        }
        let active = Set(sessions.keys)
        ShellShims.cleanLeftoverShims(shimRoot: shimRoot, keeping: active)
    }

    /// Deletes temporary terminals whose last input or output is older than 24 hours.
    @discardableResult
    public func sweepExpiredTemps(now: Date = Date()) -> [String] {
        guard let temps = try? store.temps() else { return [] }
        var latest: [String: SessionRecord] = [:]
        for temp in temps {
            if let session = try? store.latestSession(kind: .temp, ownerId: temp.id) {
                latest[temp.id] = session
            }
        }
        // Live sessions are protected regardless of the clock.
        lock.lock()
        for runtime in runtimesBySession.values where runtime.key.kind == .temp && runtime.status.isAlive {
            latest[runtime.key.ownerId] = SessionRecord(
                id: runtime.sessionId,
                kind: .temp,
                ownerId: runtime.key.ownerId,
                title: runtime.title,
                shell: runtime.shell,
                startedAt: runtime.startedAt,
                endedAt: nil
            )
        }
        lock.unlock()

        let expired = RetentionPolicy.expiredTempIDs(temps: temps, latestSessions: latest, now: now)
        for id in expired {
            try? store.deleteTemp(id: id)
            // Drop the activity throttle and any final runtime with the card, so a long
            // session that creates/expires many terminals does not leave owner state behind.
            forgetRemovedOwner(OwnerKey(kind: .temp, ownerId: id))
        }
        return expired
    }
}

/// Small helper so shim cleanup happens off the session threads.
enum ShimsCleanup {
    static func markForRemoval(sessionId: String, shimRoot: URL) {
        DispatchQueue.global(qos: .utility).async {
            ShellShims.removeShim(at: shimRoot.appendingPathComponent(sessionId, isDirectory: true))
        }
    }
}

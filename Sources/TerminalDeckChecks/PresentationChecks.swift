import Foundation
import TerminalDeckKit

/// Helpers for building `SessionRuntime` values without starting a shell, so the state
/// rules of the two card kinds can be asserted directly.
private func makeRuntime(
    kind: SessionKind,
    status: SessionStatus,
    isReady: Bool = true,
    isCommandRunning: Bool = false,
    lastCommandExitStatus: Int32? = nil,
    lastCommandFailed: Bool = false,
    lastCommandStatusUnknown: Bool = false,
    lastCommandText: String? = nil,
    launchFailureMessage: String? = nil,
    needsForceTermination: Bool = false,
    ownerId: String = "owner"
) -> SessionRuntime {
    SessionRuntime(
        sessionId: "session-\(kind.rawValue)",
        key: OwnerKey(kind: kind, ownerId: ownerId),
        title: "Title",
        shell: "/bin/zsh",
        workingDirectory: nil,
        status: status,
        lastCommandFailed: lastCommandFailed,
        lastCommandStatusUnknown: lastCommandStatusUnknown,
        lastCommandExitStatus: lastCommandExitStatus,
        launchFailureMessage: launchFailureMessage,
        needsForceTermination: needsForceTermination,
        startedAt: Date(),
        isReady: isReady,
        isCommandRunning: isCommandRunning,
        lastCommandText: lastCommandText
    )
}

func registerPresentationChecks() {
    // MARK: - Temporary terminal: the primary state is the connection

    register("presentation.temp-shell-reaching-prompt-is-online") {
        let runtime = makeRuntime(kind: .temp, status: .running)
        try expectEqual(runtime.presentation.label, "在线", "a ready idle shell is 在线")
        try expectEqual(runtime.presentation.tone, .running, "在线 is the green state")
        try expectEqual(runtime.presentation.badge, nil, "an idle terminal carries no chip")
        try expect(runtime.isReachable, "a ready running shell is reachable")
    }

    register("presentation.temp-starting-before-ready") {
        let runtime = makeRuntime(kind: .temp, status: .starting, isReady: false)
        try expectEqual(runtime.presentation.label, "正在启动", "the shell is still coming up")
        try expectEqual(runtime.presentation.tone, .busy, "starting is the neutral busy state")
        try expect(runtime.isReachable == false, "a shell that has not reported ready is not reachable")
    }

    /// The core of the change: a command in flight rides beside the connection state.
    register("presentation.temp-running-command-keeps-online-and-adds-chip") {
        let runtime = makeRuntime(kind: .temp, status: .running, isCommandRunning: true)
        try expectEqual(runtime.presentation.label, "在线", "a running command must not take over the state")
        try expectEqual(runtime.presentation.tone, .running, "the card stays on the connection colour")
        try expectEqual(runtime.presentation.badge, "执行中", "the chip reports the running command")
        try expectEqual(runtime.presentation.badgeKind, .busy, "the chip is the busy kind, not an alert")
        try expect(runtime.presentation.isCommandBusy, "the chip is readable as 'a command is running'")
        try expect(runtime.isReachable, "a terminal running a long command is still reachable")
    }

    register("presentation.temp-failed-command-stays-online") {
        let known = makeRuntime(
            kind: .temp,
            status: .running,
            lastCommandExitStatus: 1,
            lastCommandFailed: true
        )
        try expectEqual(known.presentation.label, "在线", "a failed command does not change the connection state")
        try expectEqual(known.presentation.tone, .running, "a failed command must not turn a terminal card red")
        try expectEqual(known.presentation.badge, nil, "no result chip on a terminal card")

        let unknown = makeRuntime(kind: .temp, status: .running, lastCommandStatusUnknown: true)
        try expectEqual(unknown.presentation.label, "在线", "an unreadable status is not a failure either")
        try expectEqual(unknown.presentation.badge, nil, "an unreadable status adds no chip on a terminal card")
    }

    register("presentation.temp-command-success-leaves-no-trace") {
        let runtime = makeRuntime(kind: .temp, status: .running, lastCommandExitStatus: 0)
        try expectEqual(runtime.presentation.label, "在线", "success is not shown on a terminal card")
        try expect(runtime.presentation.badge == nil, "success must not leave a chip behind")
    }

    register("presentation.temp-user-exit-marks-the-terminal-dead") {
        let runtime = makeRuntime(kind: .temp, status: .stopped)
        // A temporary terminal cannot be started again from its card, so a shell that ended
        // is the end of that terminal: 已失效, not the 未运行 that implies "start it again".
        try expectEqual(runtime.presentation.label, "已失效", "an ended terminal reads 已失效")
        try expectEqual(runtime.presentation.tone, .idle, "已失效 is neutral, never red")
        try expect(runtime.isReachable == false, "an ended terminal is not reachable")

        // A preset card keeps 未运行: it has a 启动 button, so "not running" is actionable.
        let preset = makeRuntime(kind: .preset, status: .stopped)
        try expectEqual(preset.presentation.label, "未运行", "a preset card can still be started again")
    }

    register("presentation.temp-crash-and-launch-failure-are-red") {
        let crashed = makeRuntime(kind: .temp, status: .failed)
        try expectEqual(crashed.presentation.label, "意外退出", "a shell that died on its own")
        try expectEqual(crashed.presentation.tone, .failed, "a crash is the red state")

        let notLaunched = makeRuntime(kind: .temp, status: .failed, launchFailureMessage: "no such shell")
        try expectEqual(notLaunched.presentation.label, "启动失败", "a shell that never started")
        try expectEqual(notLaunched.presentation.tone, .failed, "a launch failure is the red state")
    }

    register("presentation.temp-stopping-states") {
        let stopping = makeRuntime(kind: .temp, status: .stopping)
        try expectEqual(stopping.presentation.label, "正在结束", "terminal wording for a requested stop")
        try expectEqual(stopping.presentation.tone, .busy, "stopping is neutral")

        let stuck = makeRuntime(kind: .temp, status: .stopping, needsForceTermination: true)
        try expectEqual(stuck.presentation.badge, "无响应", "a stop that does not take offers the force action")
        try expectEqual(stuck.presentation.badgeTone, .failure, "无响应 keeps the alert chip")
    }

    // MARK: - Preset card: unchanged task semantics

    register("presentation.preset-keeps-task-semantics") {
        let success = makeRuntime(kind: .preset, status: .running, lastCommandExitStatus: 0)
        try expectEqual(success.presentation.label, "成功", "a preset card still reports the task result")
        try expectEqual(success.presentation.badge, nil, "成功 carries no chip")

        let failure = makeRuntime(
            kind: .preset,
            status: .running,
            lastCommandExitStatus: 1,
            lastCommandFailed: true
        )
        try expectEqual(failure.presentation.label, "失败", "a failed task is still the card's main state")
        try expectEqual(failure.presentation.tone, .failed, "a failed task still turns the card red")

        let running = makeRuntime(kind: .preset, status: .running, isCommandRunning: true)
        try expectEqual(running.presentation.label, "执行中", "a running task is the card's main state")
        try expectEqual(running.presentation.tone, .executing, "执行中 keeps its own tone")
        try expect(running.presentation.badge == nil, "执行中 never also shows a busy chip")
    }

    register("presentation.preset-unknown-status-needs-no-chip") {
        let unknown = makeRuntime(kind: .preset, status: .running, lastCommandStatusUnknown: true)
        try expectEqual(unknown.presentation.label, "结果未知", "an unreadable status is reported, not guessed")
        try expectEqual(unknown.presentation.tone, .running, "an unknown result is not an alert")
        try expect(unknown.presentation.badge == nil, "the label already says 未知; a chip would repeat it")
    }

    // MARK: - Counts

    register("presentation.connection-count-ignores-commands") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("presentation-counts")
        defer { TempSpace.clean(root) }
        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let engine = SessionEngine(
            store: store,
            shimRoot: root.appendingPathComponent("shims", isDirectory: true)
        )
        // No sessions at all: both counts are zero and neither menu shows a number.
        try expectEqual(engine.onlineCount(for: .temp), 0, "no terminals are online yet")
        try expectEqual(engine.executingCount(for: .preset), 0, "no tasks are running yet")
        try expectEqual(engine.executingCount(for: .temp), 0, "a terminal never counts as an executing task")
    }
}

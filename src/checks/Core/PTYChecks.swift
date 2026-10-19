import Foundation
import Core

func registerPTYChecks() {
    register("pty.zsh-interactive-integration") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            throw CheckFailure("skipped: /bin/zsh is missing on this machine")
        }
        let root = try TempSpace.make("pty-zsh")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        // Fixture rc: proves the session really loaded *our* HOME and not the developer's.
        try TempSpace.write("echo WB_REAL_ZSHRC_OK\n", to: home.appendingPathComponent(".zshrc"))
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)

        let base = hermeticBaseEnvironment(home: home)
        let sessionId = "pty-zsh-\(UUID().uuidString)"
        let plan = try ShellShims.makeLaunchPlan(
            shell: "zsh",
            firstCommand: "echo WB_MARK_TEST_OK",
            workingDirectory: nil,
            extraEnvironment: [:],
            shimRoot: shimRoot,
            sessionId: sessionId,
            baseEnvironment: base
        )

        let log = PTYEventLog()
        let session = PTYSession(id: sessionId, plan: plan)
        session.onEvent = { log.record($0) }
        let pid = try session.start()
        try expect(pid > 0, "PTYSession.start() returned pid \(pid) (launch failed)")
        defer {
            session.forceTermination()
            _ = session.waitForExit(timeout: 1.5)
            session.close()
        }

        // 1. The shell reports readiness.
        try expect(
            waitFor(timeout: 15) { log.hasSignal { $0 == .ready } },
            "no .ready signal within 15s; output so far: \(preview(log.allOutput))"
        )
        try expect(session.hasReportedReady, "hasReportedReady must be true after .ready")
        try expect(waitFor(timeout: 5) { log.outputText.contains("WB_REAL_ZSHRC_OK") },
                   "the injected HOME's .zshrc was never sourced; output: \(preview(log.allOutput))")

        // `ShellLaunchPlan.firstCommand` is intentionally *not* consumed by PTYSession:
        // PTYSession is transport only, and SessionEngine types the preset command once the
        // shell is ready. This harness therefore types it here itself, which is exactly the
        // path SessionEngine drives (see the engine checks for the end-to-end variant).
        if let firstCommand = plan.firstCommand {
            session.write(firstCommand + "\n")
        }

        // 2. The preset command really ran inside the interactive shell.
        try expect(
            waitFor(timeout: 15) { log.outputText.contains("WB_MARK_TEST_OK") },
            "visible output never contained WB_MARK_TEST_OK; output: \(preview(log.allOutput))"
        )

        // 3. Marker bytes are stripped from everything the terminal would show.
        try expect(
            containsSubsequence(log.allOutput, sessionMarkerPrefixBytes) == false,
            "marker bytes leaked into the visible output: \(preview(log.allOutput))"
        )
        try expect(log.allOutput.contains(0x07) == false, "raw BEL byte leaked into the visible output")

        // 4. The shell stays interactive after the preset command.
        session.write("echo AFTER_INPUT\n")
        try expect(
            waitFor(timeout: 15) { log.outputText.contains("AFTER_INPUT") },
            "no AFTER_INPUT output; shell may not be interactive. output: \(preview(log.allOutput))"
        )

        // 5. A failing command reports a non-zero exit status, and reporting continues.
        session.write("false\necho done\n")
        try expect(
            waitFor(timeout: 15) {
                let statuses = log.commandExitStatuses
                guard let firstNonZero = statuses.firstIndex(where: { ($0 ?? 0) != 0 }) else { return false }
                return statuses[(firstNonZero + 1)...].contains { ($0 ?? 1) == 0 }
            },
            "no non-zero .commandFinished followed by a zero one; statuses: \(log.commandExitStatuses)"
        )
        try expect(
            log.commandExitStatuses.contains { ($0 ?? 0) != 0 },
            "expected a non-zero exit status, got \(log.commandExitStatuses)"
        )
        try expect(
            containsSubsequence(log.allOutput, sessionMarkerPrefixBytes) == false,
            "marker bytes leaked after later commands: \(preview(log.allOutput))"
        )

        // 6. Termination really stops the process.
        session.requestTermination()
        try expect(waitFor(timeout: 5) { log.hasExited }, "no .exited event within 5s of requestTermination()")
        try expect(session.isRunning == false, "isRunning must be false after the shell exited")
    }

    register("pty.bash-interactive-integration") {
        guard FileManager.default.isExecutableFile(atPath: "/bin/bash") else {
            throw CheckFailure("skipped: /bin/bash is missing on this machine")
        }
        let root = try TempSpace.make("pty-bash")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        try TempSpace.write("echo WB_REAL_BASHRC_OK\n", to: home.appendingPathComponent(".bashrc"))
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)

        let base = hermeticBaseEnvironment(home: home)
        let sessionId = "pty-bash-\(UUID().uuidString)"
        // Real /bin/bash, driven through the plan the Kit generates.
        let plan = try ShellShims.makeLaunchPlan(
            shell: "/bin/bash",
            firstCommand: "echo WB_BASH_TEST_OK",
            workingDirectory: nil,
            extraEnvironment: [:],
            shimRoot: shimRoot,
            sessionId: sessionId,
            baseEnvironment: base
        )
        try expectEqual(plan.arguments, ["--rcfile", shimRoot.appendingPathComponent(sessionId).appendingPathComponent(".bashrc").path, "-i"], "bash must get long options before short ones")

        let log = PTYEventLog()
        let session = PTYSession(id: sessionId, plan: plan)
        session.onEvent = { log.record($0) }
        let pid = try session.start()
        try expect(pid > 0, "PTYSession.start() returned pid \(pid) (launch failed)")
        defer {
            session.forceTermination()
            _ = session.waitForExit(timeout: 1.5)
            session.close()
        }

        try expect(
            waitFor(timeout: 15) { log.hasSignal { $0 == .ready } },
            "no bash .ready signal within 15s; output: \(preview(log.allOutput))"
        )
        // PTYSession does not type `plan.firstCommand` (SessionEngine does); type it here.
        if let firstCommand = plan.firstCommand {
            session.write(firstCommand + "\n")
        }
        try expect(
            waitFor(timeout: 15) { log.outputText.contains("WB_BASH_TEST_OK") },
            "bash never ran the first command; output: \(preview(log.allOutput))"
        )
        try expect(
            waitFor(timeout: 5) { log.outputText.contains("WB_REAL_BASHRC_OK") },
            "the injected HOME's .bashrc was never sourced; output: \(preview(log.allOutput))"
        )
        try expect(
            containsSubsequence(log.allOutput, sessionMarkerPrefixBytes) == false,
            "marker bytes leaked into the bash visible output: \(preview(log.allOutput))"
        )

        // A failing command in bash reports a non-zero status and then keeps reporting.
        session.write("false\necho done\n")
        try expect(
            waitFor(timeout: 15) {
                let statuses = log.commandExitStatuses
                guard let firstNonZero = statuses.firstIndex(where: { ($0 ?? 0) != 0 }) else { return false }
                return statuses[(firstNonZero + 1)...].contains { ($0 ?? 1) == 0 }
            },
            "bash: no non-zero .commandFinished followed by a zero one; statuses: \(log.commandExitStatuses)"
        )

        session.requestTermination()
        try expect(waitFor(timeout: 5) { log.hasExited }, "bash did not exit within 5s of requestTermination()")
        try expect(session.isRunning == false, "bash isRunning must be false after exit")
    }
}

import Foundation
import TerminalDeckKit

func registerShellShimChecks() {
    register("shims.shell-locator-resolve") {
        let resolved = ShellLocator.resolve("zsh")
        let path = try expectUnwrap(resolved, "ShellLocator.resolve(\"zsh\")")
        try expect(path.hasPrefix("/"), "resolved path must be absolute, got \(path)")
        try expect(FileManager.default.isExecutableFile(atPath: path), "resolved path must be executable: \(path)")
        try expectEqual((path as NSString).lastPathComponent, "zsh", "resolved executable name")
        try expect(ShellLocator.isSupported("zsh"), "zsh is supported")
        try expect(ShellLocator.isSupported("/bin/bash"), "absolute bash path is supported")
        try expect(ShellLocator.isSupported("fish") == false, "fish is not supported")
        try expect(ShellLocator.resolve("definitely-not-a-shell") == nil, "unknown shell does not resolve")
    }

    register("shims.zsh-launch-plan") {
        let root = try TempSpace.make("shim-zsh")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let realZdotdir = try TempSpace.subdirectory(root, "real-zdotdir")
        // A ZDOTDIR counts as the user's dot-directory only if it can actually configure a
        // shell; an empty directory falls back to HOME (see the fallback check below).
        try TempSpace.write("# real zshrc\n", to: realZdotdir.appendingPathComponent(".zshrc"))
        let workdir = try TempSpace.subdirectory(root, "work")
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)

        let base = hermeticBaseEnvironment(home: home, extra: ["ZDOTDIR": realZdotdir.path])
        let plan = try ShellShims.makeLaunchPlan(
            shell: "zsh",
            firstCommand: "echo TD_FIRST",
            workingDirectory: workdir.path,
            extraEnvironment: ["TD_EXTRA": "1"],
            shimRoot: shimRoot,
            sessionId: "session-a",
            baseEnvironment: base
        )

        let shim = try expectUnwrap(plan.shimDirectory, "plan.shimDirectory")
        try expectEqual(plan.arguments, ["-l", "-i"], "zsh arguments")
        try expectEqual(plan.executable, ShellLocator.resolve("zsh", environment: base), "resolved executable")
        try expect(FileManager.default.isExecutableFile(atPath: plan.executable), "executable exists")
        try expectEqual(plan.environment["ZDOTDIR"], shim.path, "ZDOTDIR points at the shim directory")
        try expectEqual(plan.environment["TD_REAL_ZDOTDIR"], realZdotdir.path, "the real ZDOTDIR is preserved in TD_REAL_ZDOTDIR")
        try expectEqual(plan.environment["TD_SHIM_DIR"], shim.path, "TD_SHIM_DIR points at the shim directory")
        try expectEqual(plan.environment["SHELL"], plan.executable, "SHELL is set to the resolved executable")
        try expectEqual(plan.environment["PWD"], workdir.path, "PWD is set to the working directory")
        try expectEqual(plan.environment["TD_EXTRA"], "1", "card environment is applied")
        try expectEqual(plan.environment["HOME"], home.path, "HOME comes from baseEnvironment")
        try expectEqual(plan.workingDirectory, workdir.path, "working directory")
        try expectEqual(plan.firstCommand, "echo TD_FIRST", "firstCommand")

        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            let url = shim.appendingPathComponent(file)
            try expect(FileManager.default.fileExists(atPath: url.path), "generated shim must contain \(file)")
            let contents = try String(contentsOf: url, encoding: .utf8)
            try expect(contents.contains("TD_SHIM_DIR"), "\(file) must reference TD_SHIM_DIR")
            try expect(contents.contains("TD_REAL_ZDOTDIR"), "\(file) must reference TD_REAL_ZDOTDIR")
        }
        let zshrc = try String(contentsOf: shim.appendingPathComponent(".zshrc"), encoding: .utf8)
        try expect(zshrc.contains("1337;TerminalDeck"), ".zshrc must install the OSC marker hooks")
        try expect(zshrc.contains("ready"), ".zshrc must emit the ready marker")
        try expect(zshrc.contains("cmdend"), ".zshrc must emit cmdend markers")
        try expect(zshrc.contains("precmd_functions"), ".zshrc must install precmd hooks")
        try expect(zshrc.contains("preexec_functions"), ".zshrc must install preexec hooks")
        try expect(zshrc.contains(realZdotdir.path), ".zshrc must fall back to the real ZDOTDIR value")

        // Without ZDOTDIR the user's home directory is the real dot-file directory.
        let plainBase = hermeticBaseEnvironment(home: home)
        let plainPlan = try ShellShims.makeLaunchPlan(
            shell: "zsh",
            firstCommand: nil,
            workingDirectory: nil,
            extraEnvironment: [:],
            shimRoot: shimRoot,
            sessionId: "session-b",
            baseEnvironment: plainBase
        )
        try expectEqual(plainPlan.environment["TD_REAL_ZDOTDIR"], home.path, "without ZDOTDIR the real dot-dir is HOME")
        try expectEqual(plainPlan.firstCommand, nil, "plain session has no first command")
        try expectEqual(plainPlan.workingDirectory, home.path, "nil working directory resolves to the injected HOME")
        try expect(plainPlan.environment["ZDOTDIR"] != plainPlan.environment["TD_REAL_ZDOTDIR"], "ZDOTDIR must be redirected away from the real one")
        // Each session gets its own shim directory.
        try expect(plainPlan.shimDirectory?.path != plan.shimDirectory?.path, "each session gets a fresh shim directory")
    }

    register("shims.own-session-markers-do-not-reach-the-user-config") {
        let root = try TempSpace.make("shim-inherited")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)
        try TempSpace.write("# home zshrc\n", to: home.appendingPathComponent(".zshrc"))
        // The app was launched from one of its own terminals: everything below belongs to a
        // session that has already ended, and whose shim directory the app deleted.
        let dead = shimRoot.appendingPathComponent("dead-session", isDirectory: true)
        let base = hermeticBaseEnvironment(home: home, extra: [
            "ZDOTDIR": dead.path,
            "TD_SHIM_DIR": dead.path,
            "TD_REAL_ZDOTDIR": home.path,
            "HISTFILE": dead.appendingPathComponent(".zsh_history").path,
        ])

        let plan = try ShellShims.makeLaunchPlan(
            shell: "zsh",
            firstCommand: nil,
            workingDirectory: nil,
            extraEnvironment: [:],
            shimRoot: shimRoot,
            sessionId: "session-c",
            baseEnvironment: base
        )
        let shim = try expectUnwrap(plan.shimDirectory, "plan.shimDirectory")
        try expectEqual(plan.environment["TD_REAL_ZDOTDIR"], home.path,
                        "a shim directory must never be taken for the user's dot-directory")
        try expectEqual(plan.environment["ZDOTDIR"], shim.path, "ZDOTDIR is this session's shim")
        try expectEqual(plan.environment["TD_SHIM_DIR"], shim.path, "TD_SHIM_DIR is this session's shim")
        try expectEqual(plan.environment["HISTFILE"], home.appendingPathComponent(".zsh_history").path,
                        "history belongs in the user's home, not in a shim directory")

        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            let contents = try String(contentsOf: shim.appendingPathComponent(file), encoding: .utf8)
            try expect(contents.contains(dead.path) == false, "\(file) must not point at a deleted shim directory")
            try expect(contents.contains(home.path), "\(file) must fall back to the user's home")
        }
        let zshrc = try String(contentsOf: shim.appendingPathComponent(".zshrc"), encoding: .utf8)
        try expect(zshrc.contains("HISTFILE"), ".zshrc must keep history out of the shim directory")
    }

    register("shims.zdotdir-that-cannot-configure-a-shell-falls-back-home") {
        let root = try TempSpace.make("shim-zdotdir-fallback")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)
        let empty = try TempSpace.subdirectory(root, "empty-zdotdir")
        let missing = root.appendingPathComponent("deleted-zdotdir", isDirectory: true)

        for (label, zdotdir) in [("an empty", empty), ("a deleted", missing)] {
            let base = hermeticBaseEnvironment(home: home, extra: ["ZDOTDIR": zdotdir.path])
            let plan = try ShellShims.makeLaunchPlan(
                shell: "zsh",
                firstCommand: nil,
                workingDirectory: nil,
                extraEnvironment: [:],
                shimRoot: shimRoot,
                sessionId: "fallback-\(label)",
                baseEnvironment: base
            )
            try expectEqual(plan.environment["TD_REAL_ZDOTDIR"], home.path,
                            "\(label) ZDOTDIR holds no start-up file, so the home directory is the dot-directory")
        }

        // A ZDOTDIR that does hold start-up files is still honoured: the fallback is a repair,
        // not an override.
        let usable = try TempSpace.subdirectory(root, "usable-zdotdir")
        try TempSpace.write("# zshenv\n", to: usable.appendingPathComponent(".zshenv"))
        let plan = try ShellShims.makeLaunchPlan(
            shell: "zsh",
            firstCommand: nil,
            workingDirectory: nil,
            extraEnvironment: [:],
            shimRoot: shimRoot,
            sessionId: "usable-zdotdir",
            baseEnvironment: hermeticBaseEnvironment(home: home, extra: ["ZDOTDIR": usable.path])
        )
        try expectEqual(plan.environment["TD_REAL_ZDOTDIR"], usable.path, "a usable ZDOTDIR is preserved")

        // A nested launch — the app started from one of its own terminals — knows the directory
        // the parent session used, so a user who keeps their zsh files outside HOME keeps them
        // in the new session too.
        let dead = shimRoot.appendingPathComponent("dead-session", isDirectory: true)
        let nested = try ShellShims.makeLaunchPlan(
            shell: "zsh",
            firstCommand: nil,
            workingDirectory: nil,
            extraEnvironment: [:],
            shimRoot: shimRoot,
            sessionId: "nested-launch",
            baseEnvironment: hermeticBaseEnvironment(home: home, extra: [
                "TD_REAL_ZDOTDIR": usable.path,
                "TD_SHIM_DIR": dead.path,
                "ZDOTDIR": dead.path,
            ])
        )
        try expectEqual(nested.environment["TD_REAL_ZDOTDIR"], usable.path,
                        "a nested launch keeps the dot directory the parent session used")
        try expectEqual(nested.environment["TD_SHIM_DIR"], nested.shimDirectory?.path,
                        "the parent session's shim directory is replaced, not inherited")
    }

    register("shims.bash-launch-plan") {
        let root = try TempSpace.make("shim-bash")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let workdir = try TempSpace.subdirectory(root, "work")
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)
        let base = hermeticBaseEnvironment(home: home)

        let plan = try ShellShims.makeLaunchPlan(
            shell: "bash",
            firstCommand: "echo TD_BASH_FIRST",
            workingDirectory: workdir.path,
            extraEnvironment: [:],
            shimRoot: shimRoot,
            sessionId: "bash-session",
            baseEnvironment: base
        )
        let shim = try expectUnwrap(plan.shimDirectory, "plan.shimDirectory")
        let rcfile = shim.appendingPathComponent(".bashrc").path
        try expectEqual(plan.arguments, ["--rcfile", rcfile, "-i"], "bash arguments (long options first, so /bin/bash accepts them)")
        try expectEqual(plan.executable, ShellLocator.resolve("bash", environment: base), "resolved bash")
        try expect(FileManager.default.fileExists(atPath: rcfile), "generated .bashrc exists")
        try expectEqual(plan.environment["TD_SHIM_DIR"], shim.path, "TD_SHIM_DIR for bash")
        try expectEqual(plan.environment["SHELL"], plan.executable, "SHELL for bash")

        let rc = try String(contentsOfFile: rcfile, encoding: .utf8)
        try expect(rc.contains("1337;TerminalDeck"), ".bashrc must install the OSC marker hooks")
        try expect(rc.contains("PROMPT_COMMAND"), ".bashrc must hook PROMPT_COMMAND")
        try expect(rc.contains("trap 'td_preexec' DEBUG"), ".bashrc must install the DEBUG trap")
    }

    register("shims.rejects-unsupported-shell") {
        let root = try TempSpace.make("shim-unsupported")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let base = hermeticBaseEnvironment(home: home)

        let error = try expectThrows("unsupported shell") {
            try ShellShims.makeLaunchPlan(
                shell: "fish",
                firstCommand: nil,
                workingDirectory: nil,
                extraEnvironment: [:],
                shimRoot: root.appendingPathComponent("shims"),
                sessionId: "fish-session",
                baseEnvironment: base
            )
        }
        try expect(error is ShellLaunchError, "expected ShellLaunchError, got \(type(of: error))")
        let message = (error as? ShellLaunchError)?.message ?? ""
        try expect(message.contains("fish"), "error message should name the shell: \(message)")
    }

    register("shims.rejects-missing-working-directory") {
        let root = try TempSpace.make("shim-bad-cwd")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let base = hermeticBaseEnvironment(home: home)
        let missing = root.appendingPathComponent("does-not-exist/at-all").path

        let error = try expectThrows("missing working directory") {
            try ShellShims.makeLaunchPlan(
                shell: "zsh",
                firstCommand: nil,
                workingDirectory: missing,
                extraEnvironment: [:],
                shimRoot: root.appendingPathComponent("shims"),
                sessionId: "bad-cwd",
                baseEnvironment: base
            )
        }
        try expect(error is ShellLaunchError, "expected ShellLaunchError, got \(type(of: error))")

        // A file (not a directory) is rejected too.
        let file = root.appendingPathComponent("not-a-directory")
        try TempSpace.write("hello", to: file)
        let fileError = try expectThrows("working directory is a file") {
            try ShellShims.makeLaunchPlan(
                shell: "zsh",
                firstCommand: nil,
                workingDirectory: file.path,
                extraEnvironment: [:],
                shimRoot: root.appendingPathComponent("shims"),
                sessionId: "file-cwd",
                baseEnvironment: base
            )
        }
        try expect(fileError is ShellLaunchError, "expected ShellLaunchError for a file working directory")

        // `~` expands against the injected environment's HOME, not the developer's.
        let plan = try ShellShims.makeLaunchPlan(
            shell: "zsh",
            firstCommand: nil,
            workingDirectory: "~",
            extraEnvironment: [:],
            shimRoot: root.appendingPathComponent("shims"),
            sessionId: "tilde",
            baseEnvironment: base
        )
        try expectEqual(plan.workingDirectory, home.path, "~ must expand against the injected HOME")

        // nil/empty working directory resolves to the injected HOME as well.
        let defaultCwd = try ShellShims.makeLaunchPlan(
            shell: "zsh",
            firstCommand: nil,
            workingDirectory: nil,
            extraEnvironment: [:],
            shimRoot: root.appendingPathComponent("shims"),
            sessionId: "default-cwd",
            baseEnvironment: base
        )
        try expectEqual(defaultCwd.workingDirectory, home.path, "nil working directory must resolve to the injected HOME")

        // An injected HOME that does not exist makes `~` unresolvable.
        let ghostHome = root.appendingPathComponent("ghost-home").path
        let ghostBase = hermeticBaseEnvironment(home: URL(fileURLWithPath: ghostHome))
        let ghostError = try expectThrows("~ with a missing injected HOME") {
            try ShellShims.makeLaunchPlan(
                shell: "zsh",
                firstCommand: nil,
                workingDirectory: "~",
                extraEnvironment: [:],
                shimRoot: root.appendingPathComponent("shims"),
                sessionId: "ghost-home",
                baseEnvironment: ghostBase
            )
        }
        try expect(ghostError is ShellLaunchError, "expected ShellLaunchError for a missing injected HOME")
    }

    register("shims.remove-shim-and-cleanup") {
        let root = try TempSpace.make("shim-cleanup")
        defer { TempSpace.clean(root) }
        let home = try TempSpace.subdirectory(root, "home")
        let base = hermeticBaseEnvironment(home: home)
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)
        let plan = try ShellShims.makeLaunchPlan(
            shell: "zsh",
            firstCommand: nil,
            workingDirectory: nil,
            extraEnvironment: [:],
            shimRoot: shimRoot,
            sessionId: "cleanup-a",
            baseEnvironment: base
        )
        _ = try ShellShims.makeLaunchPlan(
            shell: "zsh",
            firstCommand: nil,
            workingDirectory: nil,
            extraEnvironment: [:],
            shimRoot: shimRoot,
            sessionId: "cleanup-b",
            baseEnvironment: base
        )
        let shim = try expectUnwrap(plan.shimDirectory, "plan.shimDirectory")
        try expect(FileManager.default.fileExists(atPath: shim.path), "shim exists after planning")

        ShellShims.cleanLeftoverShims(shimRoot: shimRoot, keeping: ["cleanup-b"])
        try expect(FileManager.default.fileExists(atPath: shim.path) == false, "cleanLeftoverShims removes unkept shims")
        try expect(FileManager.default.fileExists(atPath: shimRoot.appendingPathComponent("cleanup-b").path), "cleanLeftoverShims keeps active shims")

        ShellShims.removeShim(at: shimRoot.appendingPathComponent("cleanup-b"))
        try expect(FileManager.default.fileExists(atPath: shimRoot.appendingPathComponent("cleanup-b").path) == false, "removeShim deletes the directory")
        ShellShims.removeShim(at: nil)
        ShellShims.removeShim(at: shimRoot.appendingPathComponent("never-existed"))
    }
}

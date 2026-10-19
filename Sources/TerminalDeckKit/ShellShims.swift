import Foundation

public enum ShellKind: String, CaseIterable, Sendable {
    case zsh
    case bash

    public var displayName: String { rawValue }
}

/// Failure modes for building a launch plan; surfaced to the UI with a readable reason.
public struct ShellLaunchError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Everything needed to start one shell session.
public struct ShellLaunchPlan: Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String
    public let shimDirectory: URL?
    /// Preset command typed into the interactive shell once it reports ready.
    public let firstCommand: String?
}

public enum ShellLocator {
    /// Resolves a shell name to an absolute executable path, preferring the system
    /// shells that the spec supports (`zsh`, `bash`).
    public static func resolve(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: trimmed) ? trimmed : nil
        }
        let searchPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        for directory in searchPaths where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent(trimmed)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func defaultShell() -> String {
        if let userShell = ProcessInfo.processInfo.environment["SHELL"], isSupported(userShell) {
            return (userShell as NSString).lastPathComponent
        }
        return ShellKind.zsh.rawValue
    }

    public static func isSupported(_ shell: String) -> Bool {
        let name = (shell as NSString).lastPathComponent
        return ShellKind(rawValue: name) != nil
    }
}

/// Builds the session environment and the shell shim that loads the user's real
/// interactive configuration and installs the readiness/command-status hooks.
public enum ShellShims {
    /// Environment variables the shim files read.
    static let shimDirectoryVariable = "TD_SHIM_DIR"
    static let realZdotdirVariable = "TD_REAL_ZDOTDIR"

    /// PATH used when the app is launched from Finder and inherits a minimal environment.
    public static func baseEnvironment(now: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = now
        let fallbackPath = [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        if let existing = environment["PATH"], !existing.isEmpty {
            environment["PATH"] = fallbackPath + ":" + existing
        } else {
            environment["PATH"] = fallbackPath
        }
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["USER"] = environment["USER"] ?? NSUserName()
        environment["LOGNAME"] = environment["LOGNAME"] ?? NSUserName()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "RunBo"
        environment["TERM_PROGRAM_VERSION"] = DeckVersion.current
        if environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment
    }

    /// Expands `~` and returns the directory, verifying it exists.
    public static func resolveWorkingDirectory(_ raw: String?, home: String = NSHomeDirectory()) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return home }
        var path = raw
        if path == "~" { path = home }
        else if path.hasPrefix("~/") { path = home + String(path.dropFirst(1)) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return path
    }

    /// Markers the app sets for its own sessions. They describe a shim directory, never the
    /// user's dot-files, so they must not travel into the next session.
    static let sessionVariables = ["TD_SHIM_DIR", "TD_REAL_ZDOTDIR", "TD_READY_SENT"]

    /// The environment a session starts from, with the app's own markers removed.
    ///
    /// RunBo can be launched from one of its own terminals, and then it inherits
    /// `ZDOTDIR` and `HISTFILE` pointing at that session's shim directory — a directory the app
    /// deletes as soon as the session ends. Left alone, every terminal opened afterwards looks
    /// for the user's `.zshrc` in that dead directory and starts with no configuration at all:
    /// no theme, no aliases, no version manager, and the wrong `PATH`.
    public static func sanitizedBaseEnvironment(_ raw: [String: String], shimRoot: URL) -> [String: String] {
        var environment = raw
        for key in sessionVariables { environment.removeValue(forKey: key) }
        for key in ["ZDOTDIR", "HISTFILE"] {
            guard let value = environment[key], isInsideShimRoot(value, shimRoot: shimRoot) else { continue }
            environment.removeValue(forKey: key)
        }
        return environment
    }

    /// True when `path` is the shim root itself or lies inside it.
    static func isInsideShimRoot(_ path: String, shimRoot: URL) -> Bool {
        let root = shimRoot.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    /// The directory holding the user's own zsh start-up files.
    ///
    /// A shell launched from the user's own environment carries `ZDOTDIR`; a session started by
    /// the app carries `TD_REAL_ZDOTDIR`, the directory that session itself used. Both are
    /// honoured, but only if they can really configure a shell: an existing directory with a
    /// `.zshrc` or a `.zshenv` in it, and never one of our own shim directories. Anything else
    /// falls back to `HOME`, because a shell with no configuration at all — the theme, the
    /// aliases, the version manager all missing — is never what the user asked for.
    static func realDotDirectory(_ environment: [String: String], shimRoot: URL, home: String) -> String {
        for key in [realZdotdirVariable, "ZDOTDIR"] {
            guard let raw = environment[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
            guard isInsideShimRoot(raw, shimRoot: shimRoot) == false else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: raw, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let startUpFiles = [".zshrc", ".zshenv"].map { (raw as NSString).appendingPathComponent($0) }
            guard startUpFiles.contains(where: { FileManager.default.fileExists(atPath: $0) }) else { continue }
            return raw
        }
        return home
    }

    /// Creates the launch plan for a session.
    /// - Parameters:
    ///   - shell: `zsh`/`bash` name or an absolute path.
    ///   - firstCommand: preset command, `nil` for a plain temporary terminal.
    ///   - workingDirectory: raw card value, `nil`/empty means the home directory.
    ///   - extraEnvironment: card level environment variables.
    ///   - shimRoot: directory that holds per-session shim folders.
    ///   - sessionId: used to keep each session's shim separate.
    public static func makeLaunchPlan(
        shell: String,
        firstCommand: String?,
        workingDirectory: String?,
        extraEnvironment: [String: String],
        shimRoot: URL,
        sessionId: String,
        baseEnvironment: [String: String] = ShellShims.baseEnvironment()
    ) throws -> ShellLaunchPlan {
        let name = (shell as NSString).lastPathComponent
        guard let kind = ShellKind(rawValue: name) else {
            throw ShellLaunchError("不支持的 shell：\(shell)（仅支持 zsh 和 bash）")
        }
        // Everything below works from the cleaned environment, so the markers of the session the
        // app itself was launched from cannot reach the session we are about to start. The dot
        // directory is read from the raw environment first: those markers are how a nested
        // launch learns which directory the user's zsh files live in.
        let home = baseEnvironment["HOME"] ?? NSHomeDirectory()
        let dotDirectory = realDotDirectory(baseEnvironment, shimRoot: shimRoot, home: home)
        let base = sanitizedBaseEnvironment(baseEnvironment, shimRoot: shimRoot)
        guard let executable = ShellLocator.resolve(shell, environment: base) else {
            throw ShellLaunchError("找不到 shell 可执行文件：\(shell)")
        }
        guard let directory = resolveWorkingDirectory(workingDirectory, home: home) else {
            throw ShellLaunchError("工作目录不存在：\(workingDirectory ?? "")")
        }

        var environment = base
        for (key, value) in extraEnvironment { environment[key] = value }
        environment["SHELL"] = executable
        environment["PWD"] = directory

        let shimDirectory = try writeShim(kind: kind, shimRoot: shimRoot, sessionId: sessionId, realDotDirectory: dotDirectory)

        var arguments: [String] = []
        switch kind {
        case .zsh:
            // The shim restores the real ZDOTDIR and re-exports itself, so the user's
            // login files are still read while our hooks survive.
            environment[shimDirectoryVariable] = shimDirectory.path
            environment[realZdotdirVariable] = dotDirectory
            environment["ZDOTDIR"] = shimDirectory.path
            environment["HISTFILE"] = environment["HISTFILE"] ?? "\(home)/.zsh_history"
            arguments = ["-l", "-i"]
        case .bash:
            environment[shimDirectoryVariable] = shimDirectory.path
            // bash requires long options before short ones: `-i --rcfile` is
            // rejected with "invalid option".
            arguments = ["--rcfile", shimDirectory.appendingPathComponent(".bashrc").path, "-i"]
        }

        return ShellLaunchPlan(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: directory,
            shimDirectory: shimDirectory,
            firstCommand: firstCommand
        )
    }

    // MARK: - Shim files

    @discardableResult
    static func writeShim(kind: ShellKind, shimRoot: URL, sessionId: String, realDotDirectory: String) throws -> URL {
        try DeckPaths.ensureDirectory(shimRoot)
        let directory = shimRoot.appendingPathComponent(sessionId, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try DeckPaths.ensureDirectory(directory)
        switch kind {
        case .zsh:
            for file in [".zshenv", ".zprofile", ".zlogin"] {
                try write(zshLoader(file: file, realZdotdir: realDotDirectory), to: directory.appendingPathComponent(file))
            }
            try write(zshRc(realZdotdir: realDotDirectory), to: directory.appendingPathComponent(".zshrc"))
        case .bash:
            try write(bashRc, to: directory.appendingPathComponent(".bashrc"))
        }
        return directory
    }

    /// Removes a shim directory after the session ended.
    public static func removeShim(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes shim directories left behind by a crash.
    public static func cleanLeftoverShims(shimRoot: URL, keeping: Set<String> = []) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: shimRoot, includingPropertiesForKeys: nil) else { return }
        for entry in entries where !keeping.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func zshLoader(file: String, realZdotdir: String) -> String {
        """
        # RunBo: load the user's real \(file) and keep this shim active.
        if [ -n "${\(shimDirectoryVariable)-}" ]; then
          export ZDOTDIR="${\(realZdotdirVariable):-\(realZdotdir)}"
          if [ -f "${ZDOTDIR}/\(file)" ]; then
            . "${ZDOTDIR}/\(file)"
          fi
          export ZDOTDIR="${\(shimDirectoryVariable)}"
        fi
        """
    }

    /// zsh hooks. `precmd_functions`/`preexec_functions` are arrays, so our hooks can be
    /// prepended: that keeps the exit status of the command that just ran available as `$?`
    /// while the user's own prompt hooks still run.
    private static func zshRc(realZdotdir: String) -> String {
        """
        # RunBo: load the user's real .zshrc, then install hooks.
        if [ -n "${\(shimDirectoryVariable)-}" ]; then
          export ZDOTDIR="${\(realZdotdirVariable):-\(realZdotdir)}"
          if [ -f "${ZDOTDIR}/.zshrc" ]; then
            . "${ZDOTDIR}/.zshrc"
          fi
          export ZDOTDIR="${\(shimDirectoryVariable)}"
        fi

        # The system rc points HISTFILE at ${ZDOTDIR}/.zsh_history, and at this point ZDOTDIR is
        # this shim directory — which the app deletes when the session ends, taking the history
        # with it. Send history back to the user's own file; this runs after the user's rc, so
        # a HISTFILE chosen there still wins.
        case "${HISTFILE-}" in
          "${\(shimDirectoryVariable)}"/*)
            export HISTFILE="${\(realZdotdirVariable):-\(realZdotdir)}/.zsh_history"
            ;;
        esac

        # --- RunBo session hooks ---
        td_emit() { builtin printf '\\033]1337;TerminalDeck;%s\\007' "$1" }
        td_preexec() { td_emit cmdstart }
        td_precmd() {
          local td_status=$?
          td_emit "cmdend;${td_status:-?}"
        }
        td_ready() {
          if [ -z "${TD_READY_SENT-}" ]; then
            TD_READY_SENT=1
            td_emit ready
          fi
        }
        typeset -ga precmd_functions preexec_functions 2>/dev/null
        precmd_functions=(td_precmd ${precmd_functions:#td_precmd})
        preexec_functions=(td_preexec ${preexec_functions:#td_preexec})
        # Emitted from the last precmd hook so the preset command is typed only once
        # the first prompt has actually been drawn.
        precmd_functions=(${precmd_functions:#td_ready} td_ready)
        """
    }

    /// bash hooks. `PROMPT_COMMAND` runs before every prompt, so our hook goes first to
    /// capture `$?`. A guard flag keeps the DEBUG trap from firing on the user's own
    /// PROMPT_COMMAND entries.
    private static let bashRc = """
    # RunBo: load the user's login + interactive configuration.
    if [ -f /etc/profile ]; then . /etc/profile; fi
    for td_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      if [ -f "$td_profile" ]; then . "$td_profile"; break; fi
    done
    if [ -f /etc/bashrc ]; then . /etc/bashrc; fi
    if [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi

    # --- RunBo session hooks ---
    td_emit() { printf '\\033]1337;TerminalDeck;%s\\007' "$1"; }
    td_preexec() {
      if [ -n "${TD_IN_PROMPT-}" ]; then unset TD_IN_PROMPT; return; fi
      td_emit cmdstart
    }
    td_precmd() {
      local td_status=$?
      td_emit "cmdend;${td_status:-?}"
      TD_IN_PROMPT=1
    }
    td_ready() {
      if [ -z "${TD_READY_SENT-}" ]; then
        TD_READY_SENT=1
        td_emit ready
      fi
    }
    td_prompt_end() { unset TD_IN_PROMPT; }
    trap 'td_preexec' DEBUG
    if declare -p PROMPT_COMMAND 2>/dev/null | grep -q '^declare -a'; then
      PROMPT_COMMAND=(td_precmd "${PROMPT_COMMAND[@]}" td_ready td_prompt_end)
    else
      PROMPT_COMMAND="td_precmd;${PROMPT_COMMAND:+$PROMPT_COMMAND; }td_ready;td_prompt_end"
    fi
    """
}

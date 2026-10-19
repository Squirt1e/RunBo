import Foundation

// MARK: - Ownership

/// Where a session comes from: a saved preset card or an ad-hoc temporary terminal.
public enum SessionKind: String, Codable, Sendable, CaseIterable {
    case preset
    case temp
}

// MARK: - Preset cards

/// A saved command that can be launched as a shell session.
public struct PresetCard: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var command: String
    /// `nil` means "use the default shell from Settings".
    public var shellOverride: String?
    /// `nil` or empty means the user home directory.
    public var workingDirectory: String?
    /// Parsed `KEY=VALUE` pairs applied on top of the user environment.
    public var environment: [String: String]
    public var autoRun: Bool
    public var createdAt: Date
    public var updatedAt: Date
    /// The tag this card is filed under. `nil` means "未加标签".
    /// The tag's *name* is never copied here — see `CardTag` and `TagSection`.
    public var tagId: String?
    public var copy: CardCopy?

    public init(
        id: String = UUID().uuidString,
        title: String,
        command: String,
        shellOverride: String? = nil,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        autoRun: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        tagId: String? = nil,
        copy: CardCopy? = nil
    ) {
        self.id = id
        self.title = title
        self.copy = copy
        self.command = command
        self.shellOverride = shellOverride
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.autoRun = autoRun
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tagId = tagId
    }
}

// MARK: - Temporary terminals

/// An ad-hoc interactive terminal that lives until it is deleted or expires.
public struct TempTerminal: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Date
    /// Last user input or terminal output; drives the 24 hour expiry rule.
    public var lastActivityAt: Date
    /// The tag this terminal is filed under. `nil` means "未加标签".
    public var tagId: String?
    public var copy: CardCopy?
    /// Legacy copied terminals keep restartable launch configuration; ordinary terminals keep their old lifecycle.
    public var launchConfiguration: TerminalLaunchConfiguration?

    public init(
        id: String = UUID().uuidString,
        title: String,
        createdAt: Date = Date(),
        lastActivityAt: Date = Date(),
        tagId: String? = nil,
        copy: CardCopy? = nil,
        launchConfiguration: TerminalLaunchConfiguration? = nil
    ) {
        self.id = id
        self.title = title
        self.copy = copy
        self.launchConfiguration = launchConfiguration
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.tagId = tagId
    }
}

// MARK: - Sessions

/// How a session stopped.
public enum TerminationReason: String, Codable, Sendable {
    /// The user asked to stop it and the shell exited on its own.
    case normal
    /// The user had to force it after it ignored the normal request.
    case forced
    /// The shell exited without the user asking (crash, `exit`, closed stdin...).
    case exited
    /// The shell process could not be started at all.
    case launchFailed
    /// All sessions are stopped when the app quits.
    case appQuit
    /// A session row that was still open when the app started again (crash or power loss).
    case interrupted

    public var isExpected: Bool { self == .normal || self == .appQuit || self == .forced }
}

/// One run of a preset card or temporary terminal.
public struct SessionRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: SessionKind
    public var ownerId: String
    /// Name snapshot taken when the session started, so history keeps the old name.
    public var title: String
    /// Resolved shell executable path, e.g. `/bin/zsh`.
    public var shell: String
    public var workingDirectory: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var termination: TerminationReason?
    /// Exit status of the most recent command, `nil` when the shell never told us.
    public var lastCommandExitStatus: Int32?
    /// `true` when the last command reported a non-zero status.
    public var lastCommandFailed: Bool
    /// `true` when the last command ran but the shell could not report a status.
    /// The design requires showing "结果未知" instead of guessing a failure.
    public var lastCommandStatusUnknown: Bool
    /// `true` when the shell process never started.
    public var launchFailed: Bool
    /// `true` when the shell died on its own with a failure (crash, signal, non-zero exit).
    public var unexpectedExit: Bool
    public var lastCommandText: String?

    public init(
        id: String = UUID().uuidString,
        kind: SessionKind,
        ownerId: String,
        title: String,
        shell: String,
        workingDirectory: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        termination: TerminationReason? = nil,
        lastCommandExitStatus: Int32? = nil,
        lastCommandFailed: Bool = false,
        lastCommandStatusUnknown: Bool = false,
        launchFailed: Bool = false,
        unexpectedExit: Bool = false,
        lastCommandText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.ownerId = ownerId
        self.title = title
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.termination = termination
        self.lastCommandExitStatus = lastCommandExitStatus
        self.lastCommandFailed = lastCommandFailed
        self.lastCommandStatusUnknown = lastCommandStatusUnknown
        self.launchFailed = launchFailed
        self.unexpectedExit = unexpectedExit
        self.lastCommandText = lastCommandText
    }

    public var isFinished: Bool { endedAt != nil }
}

// MARK: - Session events (history)

public enum SessionEventKind: String, Codable, Sendable {
    /// Raw bytes that were visible in the terminal.
    case output
    /// Terminal size change: `cols` x `rows`.
    case resize
}

public struct SessionEvent: Equatable, Sendable {
    public var sessionId: String
    public var sequence: Int64
    public var timestamp: Date
    public var kind: SessionEventKind
    /// Visible terminal bytes for `.output`, empty for `.resize`.
    public var data: Data
    public var cols: Int
    public var rows: Int

    public init(
        sessionId: String,
        sequence: Int64,
        timestamp: Date = Date(),
        kind: SessionEventKind,
        data: Data = Data(),
        cols: Int = 0,
        rows: Int = 0
    ) {
        self.sessionId = sessionId
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.data = data
        self.cols = cols
        self.rows = rows
    }
}

// MARK: - Live session state

/// Lifecycle of a live session as shown on the workbench.
public enum SessionStatus: String, Sendable {
    case starting
    case running
    case stopping
    case stopped
    /// Launch failed or the shell died unexpectedly.
    case failed

    public var isAlive: Bool { self == .starting || self == .running || self == .stopping }
}

/// Status text + colour decision for a card, kept in one place so the UI cannot drift.
///
/// `tone` always describes the card's **primary** state, and it is what the card's fill,
/// border and dot follow. The two card kinds use it for different questions:
///
///   - a preset card describes one task's progress: 执行中 → 成功 / 失败；
///   - a temporary terminal describes the connection: 在线 / 未运行 / 意外退出.
///
/// A second, independent fact — "a command line is currently running" — travels in
/// `badgeKind` so it can appear *beside* the primary state instead of replacing it. That is
/// why a temporary terminal card can read 「在线」＋「执行中」 at the same time.
public struct SessionStatusPresentation: Equatable, Sendable {
    public enum Tone: String, Sendable { case executing, running, idle, failed, busy }

    /// Colour of the short chip that follows the status text. `.failure` is the alert tint
    /// used by 无响应; a chip that merely reports activity uses `badgeKind` instead.
    public enum BadgeTone: String, Sendable { case failure }

    /// What the chip means, which decides how it is drawn. Kept separate from `badgeTone`
    /// (a nuance of the failure tone) so a busy chip is never mistaken for an alert.
    public enum BadgeKind: String, Sendable { case busy }

    public var label: String
    public var tone: Tone
    /// Short suffix such as "无响应". Kept out of `label` so a narrow card can never wrap
    /// the status text.
    public var badge: String?
    public var badgeTone: BadgeTone?
    /// Set when the chip reports a running command rather than a problem.
    public var badgeKind: BadgeKind?

    public init(
        label: String,
        tone: Tone,
        badge: String? = nil,
        badgeTone: BadgeTone? = nil,
        badgeKind: BadgeKind? = nil
    ) {
        self.label = label
        self.tone = tone
        self.badge = badge
        self.badgeTone = badgeTone
        self.badgeKind = badgeKind
    }

    /// True when a command line is running in this session. Always false on a card whose
    /// primary state is "executing": there the tone already says it and a second chip
    /// would repeat it.
    public var isCommandBusy: Bool { badgeKind == .busy }
}

// MARK: - Environment parsing

public enum EnvironmentParser {
    /// Parses the multi-line "KEY=VALUE" text field used by the card editor.
    /// Blank lines and `#` comments are ignored; the first `=` separates key and value.
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    /// Renders a dictionary back into the editor's line based format (sorted, stable).
    public static func render(_ environment: [String: String]) -> String {
        environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: "\n")
    }
}

import CoreGraphics
import Foundation

/// Home actions are navigation only. Starting/stopping a shell is deliberately not an option.
public enum WorkhorseHomeDestination: Equatable, Sendable {
    case detail(OwnerKey)
    case history(OwnerKey, String)
}

public enum WorkhorseHomeAttention: String, Equatable, Sendable {
    case commandFailed, launchFailed, unexpectedExit, unresponsive

    public var label: String {
        switch self {
        case .commandFailed: return "上次执行失败"
        case .launchFailed: return "启动失败"
        case .unexpectedExit: return "意外退出"
        case .unresponsive: return "终止无响应"
        }
    }
}

/// One current owner, never a raw terminal input or an old session's title/configuration.
public struct WorkhorseHomeItem: Identifiable, Equatable, Sendable {
    public var id: OwnerKey { key }
    public let key: OwnerKey
    public let title: String
    /// The saved preset command, or the terminal's shell and working directory.
    public let subtitle: String
    public let startedAt: Date?
    public let presentation: SessionStatusPresentation
    public let isWorking: Bool
    public let isExecuting: Bool
    public let isOnline: Bool
    public let attention: WorkhorseHomeAttention?
    /// Only the latest, finished, stored preset session can offer a history action.
    public let historySessionID: String?

    public var destination: WorkhorseHomeDestination { .detail(key) }
    public var attentionDestination: WorkhorseHomeDestination {
        if let historySessionID { return .history(key, historySessionID) }
        return destination
    }
}

/// A read-only projection. Both layout and tests consume this; no database reads or writes,
/// session starts, or "recently opened" settings are hidden in a view render.
public struct WorkhorseHomeSnapshot: Equatable, Sendable {
    public let items: [WorkhorseHomeItem]
    public let working: [WorkhorseHomeItem]
    public let attention: [WorkhorseHomeItem]
    /// Most recently *started*, excluding items already in the work/attention sections.
    public let recent: [WorkhorseHomeItem]
    public var executingCount: Int { items.filter(\.isExecuting).count }
    public var onlineCount: Int { items.filter(\.isOnline).count }
    public var hasRunHistory: Bool { items.contains { $0.startedAt != nil } }

    public init(cards: [PresetCard], temps: [TempTerminal], runtimes: [SessionRuntime],
                storedSessions: [OwnerKey: SessionRecord], homeDirectory: String = NSHomeDirectory()) {
        // Ignore earlier runs, even if their callbacks arrive late. Stable ties prevent
        // dictionary iteration order from shuffling a home section on every update.
        var latest: [OwnerKey: SessionRuntime] = [:]
        for runtime in runtimes {
            if let previous = latest[runtime.key],
               previous.startedAt > runtime.startedAt
                || (previous.startedAt == runtime.startedAt && previous.sessionId >= runtime.sessionId) { continue }
            latest[runtime.key] = runtime
        }

        func item(key: OwnerKey, title: String, command: String?) -> WorkhorseHomeItem {
            let stored = storedSessions[key].flatMap {
                $0.kind == key.kind && $0.ownerId == key.ownerId ? $0 : nil
            }
            var runtime = latest[key]
            if let record = stored, let live = runtime,
               record.startedAt > live.startedAt
                || (record.id == live.sessionId && record.isFinished && live.status.isAlive) {
                runtime = nil
            }
            let record = runtime == nil || stored?.id == runtime?.sessionId ? stored : nil
            let startedAt = (runtime?.startedAt ?? record?.startedAt).flatMap {
                $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil
            }
            let presentation = runtime?.presentation ?? Self.presentation(of: record, kind: key.kind)
            let working = runtime.map {
                $0.status == .starting || $0.status == .stopping || ($0.status == .running && $0.isCommandRunning)
            } ?? false
            let reason = Self.attention(runtime: runtime, record: record, kind: key.kind)
            let subtitle: String
            if let command {
                subtitle = command
            } else if let shell = runtime?.shell ?? record?.shell {
                let directory = Self.abbreviatedPath(runtime?.workingDirectory ?? record?.workingDirectory,
                                                     homeDirectory: homeDirectory)
                subtitle = URL(fileURLWithPath: shell).lastPathComponent + " · " + directory
            } else {
                subtitle = "尚未启动"
            }
            return WorkhorseHomeItem(
                key: key, title: title, subtitle: subtitle, startedAt: startedAt,
                presentation: presentation, isWorking: working,
                isExecuting: key.kind == .preset && runtime?.presentation.tone == .executing,
                isOnline: key.kind == .temp && runtime?.isReachable == true, attention: reason,
                historySessionID: key.kind == .preset && record?.isFinished == true ? record?.id : nil
            )
        }

        // Iterating current owners, not the runtime/history dictionaries, excludes deleted
        // cards and terminals awaiting their last queued delegate notification.
        items = cards.map { item(key: OwnerKey(kind: .preset, ownerId: $0.id), title: $0.title, command: $0.command) }
            + temps.map { item(key: OwnerKey(kind: .temp, ownerId: $0.id), title: $0.title, command: nil) }
        working = items.filter(\.isWorking).sorted(by: Self.newestFirst)
        attention = items.filter { $0.attention != nil }.sorted(by: Self.newestFirst)
        let visible = Set(working.map(\.key) + attention.map(\.key))
        recent = items.filter { $0.startedAt != nil && !visible.contains($0.key) }.sorted(by: Self.newestFirst)
    }

    private static func newestFirst(_ lhs: WorkhorseHomeItem, _ rhs: WorkhorseHomeItem) -> Bool {
        if lhs.startedAt != rhs.startedAt { return (lhs.startedAt ?? .distantPast) > (rhs.startedAt ?? .distantPast) }
        if lhs.key.kind != rhs.key.kind { return lhs.key.kind.rawValue < rhs.key.kind.rawValue }
        return lhs.key.ownerId < rhs.key.ownerId
    }

    private static func presentation(of record: SessionRecord?, kind: SessionKind) -> SessionStatusPresentation {
        if let record {
            if record.launchFailed { return SessionStatusPresentation(label: "启动失败", tone: .failed) }
            if record.unexpectedExit { return SessionStatusPresentation(label: "意外退出", tone: .failed) }
            if kind == .preset && record.lastCommandFailed && !record.lastCommandStatusUnknown {
                return SessionStatusPresentation(label: "失败", tone: .failed)
            }
        }
        return SessionStatusPresentation(label: kind == .temp ? "已失效" : "未运行", tone: .idle)
    }

    private static func attention(runtime: SessionRuntime?, record: SessionRecord?,
                                  kind: SessionKind) -> WorkhorseHomeAttention? {
        if let runtime {
            if runtime.needsForceTermination && runtime.status == .stopping { return .unresponsive }
            if runtime.status == .failed {
                return runtime.launchFailureMessage == nil ? .unexpectedExit : .launchFailed
            }
            // A new command supersedes its previous result; transitional states are not
            // failures. A failed interactive command never makes a temporary terminal red.
            if runtime.status == .starting || runtime.status == .stopping || runtime.isCommandRunning { return nil }
            return kind == .preset && runtime.lastCommandFailed && !runtime.lastCommandStatusUnknown ? .commandFailed : nil
        }
        guard let record else { return nil }
        if record.launchFailed { return .launchFailed }
        if record.unexpectedExit { return .unexpectedExit }
        return kind == .preset && record.lastCommandFailed && !record.lastCommandStatusUnknown ? .commandFailed : nil
    }

    private static func abbreviatedPath(_ path: String?, homeDirectory: String) -> String {
        guard let path, !path.isEmpty else { return "~" }
        if path == homeDirectory { return "~" }
        if path.hasPrefix(homeDirectory + "/") { return "~" + path.dropFirst(homeDirectory.count) }
        return path
    }
}

/// Widths are for the right-hand content area, not the whole window.
public struct WorkhorseHomeLayout: Equatable, Sendable {
    public let padding: CGFloat
    public let contentWidth: CGFloat
    public let heroHeight: CGFloat
    public var showsEmblem: Bool { contentWidth >= 620 }
    public var splitsSections: Bool { contentWidth >= 1120 }
    public var sectionGap: CGFloat { splitsSections ? 28 : 30 }
    public var sectionPadding: CGFloat { 0 }
    public var workingWidth: CGFloat { splitsSections ? (contentWidth - sectionGap) * 0.6 : contentWidth }
    public var recentWidth: CGFloat { splitsSections ? contentWidth - sectionGap - workingWidth : contentWidth }
    public var workingColumns: Int {
        let available = workingWidth - sectionPadding * 2
        return available >= 1120 ? 3 : (available >= 620 ? 2 : 1)
    }
    public var recentColumns: Int {
        let available = recentWidth - sectionPadding * 2
        return available >= 680 ? 3 : (available >= 560 ? 2 : 1)
    }
    public var workingPreviewLimit: Int { max(2, workingColumns) }
    public var inlineMetrics: Bool { contentWidth >= 640 }
    public var titleSize: CGFloat { min(34, max(26, contentWidth * 0.043)) }
    public var emblemDiameter: CGFloat { max(0, min(112, heroHeight - 32)) }

    /// A single card takes the section width instead of leaving empty grid tracks behind.
    public func workingColumns(itemCount: Int) -> Int { max(1, min(workingColumns, itemCount)) }
    public func recentColumns(itemCount: Int) -> Int { max(1, min(recentColumns, itemCount)) }

    public init(width: CGFloat, height: CGFloat = 860) {
        let width = width.isFinite ? max(0, width) : 804
        let height = height.isFinite ? max(0, height) : 860
        padding = width >= 760 ? min(64, max(44, width * 0.035)) : (width >= 560 ? 28 : min(20, width / 2))
        contentWidth = max(0, width - padding * 2)
        // A signature, not a billboard. Tasks remain above the fold in short windows.
        heroHeight = height < 720 ? 120 : 160
    }
}

public enum WorkhorseHomeFormatting {
    /// The engine exposes session start, not command start: label this "会话时长".
    public static func sessionDuration(since startedAt: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed.isFinite else { return "00:00" }
        // Bound conversion for arbitrary Dates without affecting any real session.
        let seconds = Int(min(max(0, elapsed), 315_360_000))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

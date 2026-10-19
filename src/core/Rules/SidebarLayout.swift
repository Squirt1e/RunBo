import CoreGraphics
import Foundation

/// A layout preference, independent of split mode, terminal expansion and file pinning.
public enum SidebarMode: String, Sendable {
    case pinned, collapsed
    public static let key = "workbench_sidebar_mode"

    /// Existing installations keep their full sidebar until the user opts in.
    public static func stored(_ value: String?) -> Self { Self(rawValue: value ?? "") ?? .pinned }
}

public enum SidebarLayout {
    public static let railWidth: CGFloat = 56
    public static let dividerWidth: CGFloat = 9
    public static let hoverDelay = 0.18
    public static let leaveDelay = 0.28
    public static let tileSize: CGFloat = 32
    public static let ownerWidth: CGFloat = 40
    public static let ownerHeight: CGFloat = 44
    public static let groupWidth: CGFloat = 44
    public static let groupSpacing: CGFloat = 10

    /// A peek must never participate in content allocation (and therefore never resize a PTY).
    public static func reservedWidth(mode: SidebarMode, expandedWidth: CGFloat) -> CGFloat {
        mode == .pinned ? expandedWidth + dividerWidth : railWidth
    }

    /// Derived from the real title; Character boundaries preserve Chinese and emoji graphemes.
    public static func monogram(title: String, terminal: Bool = false) -> String {
        let words = title.split(whereSeparator: \.isWhitespace)
        if terminal, let last = words.last, last.allSatisfy(\.isNumber) { return String(last.prefix(2)) }
        if words.count > 1 { return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
        return String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).uppercased()
    }
}

/// Visual-only mapping of the existing status vocabulary; never infers live process state.
public struct SidebarRailBorder: Equatable, Sendable {
    public static let orbitDuration: TimeInterval = 2.4
    public let kind: StatusDot
    public init(_ kind: StatusDot) { self.kind = kind }

    public var lineWidth: CGFloat {
        switch kind {
        case .executing, .failed: return 2
        case .idle: return 1
        default: return 1.5
        }
    }
    public var isDashed: Bool { kind == .starting || kind == .unresponsive }
    public var showsRunningLight: Bool { kind == .executing || kind == .liveBusy }
}

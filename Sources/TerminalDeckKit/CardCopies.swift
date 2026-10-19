import Foundation

/// Identity of a disposable copy. Retention removes it entirely: the same card becomes an
/// independent ordinary card. No foreign key: removing the source must never remove a copy.
public struct CardCopy: Equatable, Sendable {
    public var sourceID: String
    public var number: Int
    /// Legacy storage compatibility only. Standard cards no longer have layout bindings.
    public var anchorID: String?
    public var runID: String?

    public init(sourceID: String, number: Int, anchorID: String?, runID: String?) {
        self.sourceID = sourceID
        self.number = number
        self.anchorID = anchorID
        self.runID = runID
    }
}

public struct TerminalLaunchConfiguration: Equatable, Sendable {
    public var shell: String
    public var workingDirectory: String?
    public var environment: [String: String]

    public init(shell: String, workingDirectory: String? = nil, environment: [String: String] = [:]) {
        self.shell = shell
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

public enum CardCopyError: Error, CustomStringConvertible {
    case missingSource, notDisposable, unsupportedKind
    public var description: String {
        switch self {
        case .missingSource: return "原卡已不存在，请刷新后重试。"
        case .notDisposable: return "卡片已保留或已解除。"
        case .unsupportedKind: return "仅快捷指令支持创建分身。"
        }
    }
}

public enum CardCopyLayout {
    public static let terminalOrderKey = "terminal_card_order"

    public static func ordered<T: Identifiable>(_ items: [T], stored: String?) -> [T] where T.ID == String {
        guard let stored, let ids = try? JSONDecoder().decode([String].self, from: Data(stored.utf8)) else { return items }
        var ranks: [String: Int] = [:]
        for id in ids where ranks[id] == nil { ranks[id] = ranks.count }
        return items.enumerated().sorted {
            (ranks[$0.element.id] ?? ranks.count + $0.offset) < (ranks[$1.element.id] ?? ranks.count + $1.offset)
        }.map(\.element)
    }
}

extension TerminalDeckStore {
    /// Preset configuration only: no engine calls, no copied history, no implicit launch.
    /// The defaultShell argument is retained for API compatibility; terminals cannot create copies.
    @discardableResult
    public func createCopy(of key: OwnerKey, runID: String, defaultShell _: String) throws -> OwnerKey {
        guard key.kind == .preset else { throw CardCopyError.unsupportedKind }
        return try database.transaction {
            let presets = try cards()
            guard var source = presets.first(where: { $0.id == key.ownerId }) else { throw CardCopyError.missingSource }
            let oldCopy = source.copy
            let sourceID = oldCopy?.sourceID ?? key.ownerId
            let counterKey = "copy_number_\(key.kind.rawValue)_\(sourceID)"
            let number = (Int(try string(forKey: counterKey) ?? "") ?? 0) + 1
            let metadata = CardCopy(sourceID: sourceID, number: number, anchorID: nil, runID: runID)
            // The copy keeps the card's own name. Numbering survives in `CardCopy.number` (唯一编号，
            // 供顺序与清理使用)，界面上只打一枚「分身」标记，不再把序号写进标题。
            let newID = UUID().uuidString
            source.id = newID; source.title = Self.baseCopyTitle(source.title)
            source.createdAt = Date(); source.updatedAt = source.createdAt
            source.autoRun = false; source.copy = metadata
            try save(source)
            var order = presets.map(\.id)
            order.insert(newID, at: (order.firstIndex(of: key.ownerId) ?? order.count-1)+1)
            try setString(PresetCardReordering.storageValue(ids: order), forKey: PresetCardReordering.storageKey)
            try setString(String(number), forKey: counterKey)
            return OwnerKey(kind: .preset, ownerId: newID)
        }
    }

    public func retainCopy(_ key: OwnerKey) throws {
        try database.transaction {
            switch key.kind {
            case .preset:
                guard var card = try cards().first(where: { $0.id == key.ownerId }), card.copy?.runID != nil else {
                    throw CardCopyError.notDisposable
                }
                card.copy = nil
                try save(card)
            case .temp:
                guard var terminal = try temps().first(where: { $0.id == key.ownerId }), terminal.copy?.runID != nil else {
                    throw CardCopyError.notDisposable
                }
                terminal.copy = nil
                try save(terminal)
            }
        }
    }

    /// Caller must finish the owner's PTYs and fence queued history writes before deletion.
    public func removeCopy(_ key: OwnerKey) throws {
        try database.transaction {
            let table = key.kind == .preset ? "preset_cards" : "temp_terminals"
            let disposable = try database.query("SELECT clone_run_id FROM \(table) WHERE id = ?;", [.text(key.ownerId)]) {
                $0.optionalString(0)
            }.first ?? nil
            guard disposable != nil else { throw CardCopyError.notDisposable }
            try removeCopyRows(key)
            try compactCopyOrders()
        }
    }

    /// Runs before loading cards/auto-run. A crash need not have run an exit callback.
    /// nil clears every disposable card (normal quit); a token keeps this run's copies.
    @discardableResult
    public func purgeStaleCopies(keeping runID: String? = nil) throws -> [OwnerKey] {
        try database.transaction {
            var keys: [OwnerKey] = []
            for kind in SessionKind.allCases {
                let table = kind == .preset ? "preset_cards" : "temp_terminals"
                keys += try database.query("SELECT id, clone_run_id FROM \(table) WHERE clone_run_id IS NOT NULL;") {
                    ($0.string(0), $0.string(1))
                }.filter { $0.1 != runID }.map { OwnerKey(kind: kind, ownerId: $0.0) }
            }
            for key in keys { try removeCopyRows(key) }
            if !keys.isEmpty { try compactCopyOrders() }
            return keys
        }
    }

    private func removeCopyRows(_ key: OwnerKey) throws {
        let values: [SQLiteValue] = [.text(key.kind.rawValue), .text(key.ownerId)]
        try database.run("DELETE FROM session_events WHERE session_id IN (SELECT id FROM sessions WHERE kind = ? AND owner_id = ?);", values)
        try database.run("DELETE FROM sessions WHERE kind = ? AND owner_id = ?;", values)
        let table = key.kind == .preset ? "preset_cards" : "temp_terminals"
        try database.run("DELETE FROM \(table) WHERE id = ?;", [.text(key.ownerId)])
        try database.run("UPDATE \(table) SET copy_anchor_id = NULL WHERE copy_anchor_id = ?;", [.text(key.ownerId)])
    }

    private func compactCopyOrders() throws {
        try setString(PresetCardReordering.storageValue(ids: try cards().map(\.id)), forKey: PresetCardReordering.storageKey)
        try setString(PresetCardReordering.storageValue(ids: try temps().map(\.id)), forKey: CardCopyLayout.terminalOrderKey)
    }
}

public extension TerminalDeckStore {
    /// 旧版本给分身写过「原名 · 副本 N」。序号现在只留在 `CardCopy.number`，标题回到原名：
    /// 这一层在每次建分身时顺手剥掉尾巴，老库不需要单独迁移。
    static func baseCopyTitle(_ title: String) -> String {
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return copySuffixExpression.stringByReplacingMatches(in: title, range: range, withTemplate: "")
    }

    /// 只认结尾那一段：「 · 副本 N」或「 · 分身 N」。
    private static let copySuffixExpression = try! NSRegularExpression(pattern: " · (副本|分身) [0-9]+$")
}

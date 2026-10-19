import CoreGraphics
import Foundation

/// A position inside a tag group. A nil tag means 未加标签; a nil anchor means group end.
public struct CardDropDestination: Equatable, Sendable {
    public var tagId: String?
    public var beforeCardID: String?

    public init(tagId: String?, beforeCardID: String? = nil) {
        self.tagId = tagId
        self.beforeCardID = beforeCardID
    }
}

/// Layout-only hit regions: headers use the same destination for both halves, rows insert
/// before/after their midpoint. The placeholder is deliberately excluded by the caller.
public struct CardDropRegion: Equatable {
    public var frame: CGRect
    public var before: CardDropDestination
    public var after: CardDropDestination

    public init(frame: CGRect, before: CardDropDestination, after: CardDropDestination) {
        self.frame = frame
        self.before = before
        self.after = after
    }

    public static func destination(at point: CGPoint, in regions: [CardDropRegion]) -> CardDropDestination? {
        guard let region = regions.first(where: { $0.frame.contains(point) }) else { return nil }
        return point.y < region.frame.midY ? region.before : region.after
    }
}

/// Preview and persistence share one insertion rule. Only a tag reference and the explicit
/// order change — never timestamps, commands, terminal state or session history.
public enum PresetCardReordering {
    public static let storageKey = "preset_card_order"

    public static func moving(_ cards: [PresetCard], id: String,
                              to destination: CardDropDestination) -> [PresetCard]? {
        guard var card = cards.first(where: { $0.id == id }), destination.beforeCardID != id else { return nil }
        var result = cards.filter { $0.id != id }
        let insertion: Int
        if let before = destination.beforeCardID {
            guard let index = result.firstIndex(where: { $0.id == before }),
                  result[index].tagId == destination.tagId else { return nil }
            insertion = index
        } else {
            insertion = result.lastIndex(where: { $0.tagId == destination.tagId }).map { $0 + 1 } ?? result.count
        }
        card.tagId = destination.tagId
        result.insert(card, at: insertion)
        return result
    }

    public static func storageValue(ids: [String]) -> String {
        let data = (try? JSONEncoder().encode(ids)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Keep the existing created-at order until the first move. Ignore deleted/duplicate
    /// references and append new cards, so old settings cannot hide or duplicate a card.
    public static func ordered(_ cards: [PresetCard], stored: String?) -> [PresetCard] {
        guard let stored, let ids = try? JSONDecoder().decode([String].self, from: Data(stored.utf8)) else { return cards }
        var ranks: [String: Int] = [:]
        for id in ids where ranks[id] == nil { ranks[id] = ranks.count }
        return cards.enumerated().sorted { lhs, rhs in
            let left = ranks[lhs.element.id] ?? (ranks.count + lhs.offset)
            let right = ranks[rhs.element.id] ?? (ranks.count + rhs.offset)
            return left < right
        }.map(\.element)
    }
}

public enum CardReorderingError: Error, CustomStringConvertible {
    case staleDestination

    public var description: String { "卡片或目标分组已变化，请重新拖动。" }
}

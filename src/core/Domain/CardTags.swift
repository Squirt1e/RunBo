import Foundation

// MARK: - Tag

/// A named category a card can belong to. Cards hold only a reference to it, so
/// renaming a tag never has to touch the cards themselves.
public struct CardTag: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// Position of this tag's block in the card list. Densely renumbered by
    /// `TagVocabulary.renumber`, so ordering never depends on how often a tag was moved.
    public var sortOrder: Int
    public var createdAt: Date

    public init(id: String = UUID().uuidString, name: String, sortOrder: Int = 0, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// One tag and the cards filed under it. `tag == nil` is the untagged bucket.
///
/// Only `Equatable` so the self-check harness can assert on sections built from a
/// lightweight stand-in item type; the real cards are `Equatable` too.
public struct TagSection<Item>: Identifiable, Equatable where Item: Equatable {
    public var tag: CardTag?
    public var items: [Item]

    public init(tag: CardTag?, items: [Item]) {
        self.tag = tag
        self.items = items
    }

    /// `nil` for the untagged bucket, so it can key a `ForEach` without a fake tag.
    public var id: String { tag?.id ?? "" }
    public var name: String { tag?.name ?? "未加标签" }
    public var isUntagged: Bool { tag == nil }
}

// MARK: - Naming rules

public enum TagNameError: Error, Equatable, CustomStringConvertible {
    case empty
    case duplicate(existing: String)

    public var description: String {
        switch self {
        case .empty: return "标签名不能为空"
        case .duplicate(let existing): return "已有同名标签「\(existing)」"
        }
    }
}

/// The rules that keep one tag from growing three near-copies of itself.
///
/// A tag name is stored trimmed, with runs of whitespace collapsed to one space.
/// Matching a typed name against the existing vocabulary ignores case and
/// surrounding whitespace, which is what makes "工作 ", "工作" and "工作  " all land
/// on the same tag instead of creating three blocks that look identical.
public enum TagVocabulary {
    public static let untaggedTitle = "未加标签"

    /// The form that gets written to disk.
    public static func normalized(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// The form used for comparison only: whitespace collapsed *and* removed, folded
    /// for case and width so "ＷＯＲＫ" and "work" are the same tag.
    public static func matchKey(_ raw: String) -> String {
        normalized(raw)
            .replacingOccurrences(of: " ", with: "")
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    /// The existing tag a typed name resolves to, if any.
    public static func match(_ raw: String, in tags: [CardTag]) -> CardTag? {
        let key = matchKey(raw)
        guard !key.isEmpty else { return nil }
        return tags.first { matchKey($0.name) == key }
    }

    /// Whether `name` may be used by the tag `excluding` (a rename of that tag).
    public static func validate(_ raw: String, in tags: [CardTag], excluding: String? = nil) throws -> String {
        let name = normalized(raw)
        guard !name.isEmpty, !matchKey(name).isEmpty else { throw TagNameError.empty }
        if let clash = tags.first(where: { $0.id != excluding && matchKey($0.name) == matchKey(name) }) {
            throw TagNameError.duplicate(existing: clash.name)
        }
        return name
    }

    /// Where a brand new tag goes: after every existing one.
    public static func nextSortOrder(in tags: [CardTag]) -> Int {
        (tags.map(\.sortOrder).max() ?? -1) + 1
    }

    /// Rewrites sort orders to `0..<n` in their current order, after a move.
    public static func renumber(_ tags: [CardTag]) -> [CardTag] {
        tags.enumerated().map { index, tag in
            var copy = tag
            copy.sortOrder = index
            return copy
        }
    }

    /// Moves one tag by an offset, preserving the relative order of every other tag.
    public static func moved(_ tags: [CardTag], id: String, by offset: Int) -> [CardTag]? {
        var ordered = tags.sorted { $0.sortOrder < $1.sortOrder }
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        let target = index + offset
        guard offset != 0, ordered.indices.contains(target) else { return nil }
        let moved = ordered.remove(at: index)
        ordered.insert(moved, at: target)
        return renumber(ordered)
    }

    // MARK: Colour

    /// Six tones, assigned by the tag's own name so the colour needs no column in the
    /// database and never changes for a given tag.
    public static let toneCount = 6

    /// FNV-1a, written out on purpose: `Hasher` is seeded per process, so a colour taken
    /// from `hashValue` would change every time the app is launched.
    public static func toneIndex(for name: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in matchKey(name).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(toneCount))
    }
}

// MARK: - Grouping

/// Splits a card list into tag blocks. Pure and view-free so the ordering rules can be
/// asserted in the self-check harness instead of only being visible on screen.
public enum CardGrouping {
    /// - Parameters:
    ///   - items: cards in their existing order; the order inside a block is preserved.
    ///   - tags: the tag vocabulary, in block order.
    ///   - tagId: how to read an item's tag reference.
    /// - Returns: one section per tag that has cards, in vocabulary order, then the
    ///   untagged bucket if it has cards — always last when present.
    ///
    /// A tag with no cards produces no section at all, so a block disappears the moment
    /// its last card is deleted or re-tagged. A card pointing at a tag that no longer
    /// exists falls into the untagged bucket rather than vanishing from the list.
    public static func sections<Item>(
        items: [Item],
        tags: [CardTag],
        tagId: (Item) -> String?
    ) -> [TagSection<Item>] {
        var buckets: [String: [Item]] = [:]
        var untagged: [Item] = []
        let known = Set(tags.map(\.id))
        for item in items {
            if let id = tagId(item), known.contains(id) {
                buckets[id, default: []].append(item)
            } else {
                untagged.append(item)
            }
        }
        var sections = tags
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { tag -> TagSection<Item>? in
                guard let bucket = buckets[tag.id], !bucket.isEmpty else { return nil }
                return TagSection(tag: tag, items: bucket)
            }
        if !untagged.isEmpty {
            sections.append(TagSection(tag: nil, items: untagged))
        }
        return sections
    }

    /// How many cards each tag is currently holding. Tags with no cards are included
    /// with a count of zero — the management list shows them so they can be deleted.
    public static func usageCounts<Item>(items: [Item], tagId: (Item) -> String?) -> [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            guard let id = tagId(item) else { continue }
            counts[id, default: 0] += 1
        }
        return counts
    }
}

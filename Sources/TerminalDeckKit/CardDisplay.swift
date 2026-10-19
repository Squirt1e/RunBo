import Foundation

/// How a card list draws its cards.
///
/// Each menu remembers its own choice: the presets list and the temporary-terminal list are
/// handy in different shapes, so the mode is stored per `SessionKind` rather than globally.
public enum CardDisplayMode: String, CaseIterable, Sendable {
    /// A responsive wide card, with the preset command printed on it.
    case wide
    /// Square cards: as many per row as the window fits, title + status + one round button.
    case square

    /// The mode the switcher offers next.
    public var other: CardDisplayMode {
        switch self {
        case .wide: return .square
        case .square: return .wide
        }
    }

    /// Name shown in the card layout switcher.
    public var label: String {
        switch self {
        case .wide: return "详细"
        case .square: return "精简"
        }
    }
}

/// The sizes and rules both card layouts share.
///
/// Pure arithmetic shared by views and the self-check harness. Native frame checks cover
/// the resulting card order and alignment across tag groups.
public enum CardDisplay {
    /// The wide card's height as the running app lays it out, measured from a window capture.
    /// The square card uses it as its side, so both layouts keep the same row rhythm.
    public static let cardHeight: CGFloat = 150
    /// Gutter between cards and between rows, in both layouts.
    public static let spacing: CGFloat = 12
    /// Preferred minimum: wide cards wrap at this width, but can shrink in narrow windows.
    public static let wideColumnMinimum: CGFloat = 320
    /// Sparse groups keep a readable silhouette instead of becoming full-width banners.
    public static let wideColumnMaximum: CGFloat = 480

    /// One settings key per menu, so switching one list leaves the other alone.
    public static let presetsKey = "card_mode_presets"
    public static let tempsKey = "card_mode_temps"

    public static func key(for kind: SessionKind) -> String {
        switch kind {
        case .preset: return presetsKey
        case .temp: return tempsKey
        }
    }

    /// Reads back a stored value. A missing, empty or unrecognised value means the layout the
    /// app has always had — nobody's list changes shape because a setting went missing.
    public static func mode(fromStored value: String?) -> CardDisplayMode {
        guard let value, let mode = CardDisplayMode(rawValue: value) else { return .wide }
        return mode
    }

    /// List tracks depend only on the viewport, never a tag group's item count. Sparse groups
    /// use the same card width and column origins as dense ones, leaving trailing cells empty.
    public static func wideListGrid(in width: CGFloat) -> (columns: Int, cardWidth: CGFloat) {
        // Int.max rounds upward as a CGFloat. Leave headroom for safe conversion and row
        // arithmetic even for unrealistically large finite proposals; real windows never hit it.
        wideGrid(in: width, itemCount: Int.max / 2)
    }

    /// Item-count-based sizing for the home task preview, not tagged card lists. Extra room
    /// remains at the trailing edge; narrow viewports can shrink a single column.
    public static func wideGrid(in width: CGFloat, itemCount: Int) -> (columns: Int, cardWidth: CGFloat) {
        guard width.isFinite, width > 0 else { return (1, wideColumnMinimum) }
        let count = max(1, itemCount)
        let fittingColumns = ((width + spacing) / (wideColumnMinimum + spacing)).rounded(.down)
        let columns = Int(max(1, min(CGFloat(count), fittingColumns)))
        let sharedWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        return (columns, min(wideColumnMaximum, sharedWidth))
    }

    /// How many square cards fit side by side in `width`.
    ///
    /// One under is deliberate: the leftover width stays at the end of the row (or in the
    /// gaps) instead of stretching the cards, which would stop them being square.
    public static func squareColumns(in width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let fit = Int((width + spacing) / (cardHeight + spacing))
        return max(1, fit)
    }
}

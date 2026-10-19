import Foundation

/// Terminal font size: the one appearance setting the app keeps for the terminal itself.
///
/// The range is closed on purpose. Below the minimum the terminal stops being readable, and
/// above the maximum a standard window fits so few columns that most programs reflow badly;
/// both ends are also what the settings row can express with a plus and a minus.
public enum TerminalFontSize {
    public static let minimum: Double = 12
    public static let maximum: Double = 24
    public static let `default`: Double = minimum

    /// The named sizes the settings row offers as one-click choices. They exist so the common
    /// cases never need typing; the row still accepts any whole point in the range, which is
    /// why these are shortcuts rather than the storage format.
    public static let presets: [(name: String, points: Double)] = [
        ("小", 12),
        ("中", 15),
        ("大", 18),
    ]

    /// The named size a number corresponds to, if it is exactly one of them. The settings UI
    /// separately tracks whether that number came from a preset or the custom field.
    public static func preset(for value: Double) -> String? {
        presets.first { $0.points == clamp(value) }?.name
    }

    /// Stored settings are text and can come from an older build or a hand-edited database,
    /// so anything unusable falls back to the default instead of a degenerate view. Values
    /// that are merely out of range snap to the nearest end rather than being refused: a
    /// terminal that is merely too small or too large still works.
    public static func clamp(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return `default` }
        return Swift.min(Swift.max(value, minimum), maximum)
    }

    /// The form stored in the settings table: whole points, as text.
    public static func storageValue(_ value: Double?) -> String {
        String(Int(clamp(value).rounded()))
    }
}

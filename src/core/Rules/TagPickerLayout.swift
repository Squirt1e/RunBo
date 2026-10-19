import Foundation

/// Tag picker placement in the root view's top-left coordinate space, never screen coordinates.
public enum TagPickerLayout {
    public static let width: CGFloat = 262
    public static let gap: CGFloat = 8
    public static let edgeInset: CGFloat = 8

    public static func availableSize(in viewport: CGSize) -> CGSize {
        CGSize(width: max(0, viewport.width - edgeInset * 2),
               height: max(0, viewport.height - edgeInset * 2))
    }

    /// Prefer the card's right side and top edge; only move inward when the app has no room.
    public static func frame(anchor: CGRect, panelSize: CGSize, viewport: CGSize) -> CGRect {
        let available = availableSize(in: viewport)
        let size = CGSize(width: min(max(0, panelSize.width), available.width),
                          height: min(max(0, panelSize.height), available.height))
        let insetX = min(edgeInset, max(0, viewport.width) / 2)
        let insetY = min(edgeInset, max(0, viewport.height) / 2)
        return CGRect(
            x: min(max(insetX, anchor.maxX + gap), viewport.width - insetX - size.width),
            y: min(max(insetY, anchor.minY), viewport.height - insetY - size.height),
            width: size.width,
            height: size.height
        )
    }
}

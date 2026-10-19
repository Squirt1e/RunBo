import Foundation

/// What the terminal panel shows once it is expanded to the whole content area.
///
/// Presentation state, not engine state — but it is worth stating once and asserting: fullscreen
/// belongs to *one* terminal, it drops the page chrome above the panel, and it leaves navigation
/// alone so the user can still move around while a terminal is expanded.
public enum PanelLayout {
    /// The pieces of the detail page / history page that can be shown or hidden around the panel.
    public enum Region: String, CaseIterable {
        /// 返回 detail page or history page.
        case backButton
        /// The detail page's title row: card name and the edit icon.
        case header
        /// The panel itself, including its title bar and the terminal inside it.
        case panel
    }

    /// Chrome that exists only for the normal (not expanded) page.
    public static let pageChrome: Set<Region> = [.backButton, .header]

    /// The panel's own title bar is never hidden: it carries the exit control, so an expanded
    /// panel can always be collapsed again — including with Escape.
    public static func visibleRegions(fullscreen: Bool) -> Set<Region> {
        fullscreen ? [.panel] : Set(Region.allCases)
    }

    /// Fullscreen belongs to a single terminal. The key, rather than a plain flag, is what makes
    /// page switches drop it by construction: any other page compares against a different key,
    /// and the list pages have no key at all.
    public static func isFullscreen(current: OwnerKey?, expanded: OwnerKey?) -> Bool {
        guard let current, let expanded else { return false }
        return current == expanded
    }
}

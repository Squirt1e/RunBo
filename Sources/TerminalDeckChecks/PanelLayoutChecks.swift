import Foundation
import TerminalDeckKit

/// Fullscreen only holds a key, so the rules that matter are the derived ones: which page may
/// expand, what disappears when it does, and what happens on the way out. Those are the parts
/// that a view could get wrong silently, which is why they live here rather than in comments.
func registerPanelLayoutChecks() {
    let terminal = OwnerKey(kind: .temp, ownerId: "temp-1")
    let other = OwnerKey(kind: .temp, ownerId: "temp-2")
    let card = OwnerKey(kind: .preset, ownerId: "card-1")

    register("panel.normal-page-shows-its-chrome") {
        let regions = PanelLayout.visibleRegions(fullscreen: false)
        try expectEqual(regions, Set(PanelLayout.Region.allCases), "a normal page shows every region")
        try expect(regions.contains(.backButton), "the way back is on screen")
        try expect(regions.contains(.header), "the title row is on screen")
        try expect(regions.contains(.panel), "the terminal is on screen")
    }

    register("panel.fullscreen-keeps-only-the-panel") {
        let regions = PanelLayout.visibleRegions(fullscreen: true)
        try expectEqual(regions, [.panel], "fullscreen leaves the terminal alone on the page")
        // The panel bar carries the exit button and Escape, so an expanded panel is never
        // a dead end — that is why the panel itself is never hidden.
        try expect(regions.contains(.panel), "the panel and its title bar stay")
        try expectEqual(regions.intersection(PanelLayout.pageChrome), [], "no page chrome survives")
    }

    register("panel.fullscreen-belongs-to-one-terminal") {
        try expect(
            PanelLayout.isFullscreen(current: terminal, expanded: terminal),
            "the terminal that was expanded is fullscreen"
        )
        try expect(
            PanelLayout.isFullscreen(current: other, expanded: terminal) == false,
            "another terminal's panel is not"
        )
        try expect(
            PanelLayout.isFullscreen(current: nil, expanded: terminal) == false,
            "a list page has no terminal to expand"
        )
        try expect(
            PanelLayout.isFullscreen(current: terminal, expanded: nil) == false,
            "nothing is expanded until the user asks"
        )
    }

    register("panel.leaving-the-page-drops-fullscreen") {
        // Navigation never has to remember to clear the state: the key it compares against
        // simply stops matching. These are the transitions that used to need a reset call.
        try expect(
            PanelLayout.isFullscreen(current: card, expanded: terminal) == false,
            "switching to another card exits fullscreen"
        )
        try expect(
            PanelLayout.isFullscreen(current: nil, expanded: card) == false,
            "returning to a list exits fullscreen"
        )
    }

    register("panel.history-replay-keeps-the-expanded-panel") {
        // History uses the same owner key as the detail page it was opened from, so an
        // expanded panel stays expanded across that step.
        try expect(
            PanelLayout.isFullscreen(current: terminal, expanded: terminal),
            "the replay of the expanded terminal is still fullscreen"
        )
    }
}

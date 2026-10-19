import Foundation
import Core

func registerTagPickerLayoutChecks() {
    register("tag-picker.opens-to-the-right-with-top-edges-aligned") {
        let card = CGRect(x: 248, y: 78, width: 340, height: 150)
        let frame = TagPickerLayout.frame(
            anchor: card,
            panelSize: CGSize(width: 262, height: 240),
            viewport: CGSize(width: 1100, height: 860)
        )
        try expectEqual(frame.minX, card.maxX + TagPickerLayout.gap, "the picker hangs beside its own card")
        try expectEqual(frame.minY, card.minY, "the picker and card share their top edge")
        try expectEqual(frame.size, CGSize(width: 262, height: 240), "roomy windows keep the natural panel size")
    }

    register("tag-picker.split-rows-use-the-same-placement") {
        let row = CGRect(x: 10, y: 160, width: 280, height: 26)
        let frame = TagPickerLayout.frame(
            anchor: row,
            panelSize: CGSize(width: 262, height: 180),
            viewport: CGSize(width: 1100, height: 860)
        )
        try expectEqual(frame.minX, row.maxX + TagPickerLayout.gap, "a sidebar row opens into the content area")
        try expectEqual(frame.minY, row.minY, "short rows still align at the top, not the bottom")
    }

    register("tag-picker.right-edge-clamps-to-the-app-not-the-screen") {
        let frame = TagPickerLayout.frame(
            anchor: CGRect(x: 720, y: 120, width: 340, height: 150),
            panelSize: CGSize(width: 262, height: 240),
            viewport: CGSize(width: 1100, height: 860)
        )
        try expectEqual(frame.maxX, 1100 - TagPickerLayout.edgeInset, "the picker cannot escape the app's right edge")
        try expectEqual(frame.minY, 120, "horizontal clamping does not move the top edge")
    }

    register("tag-picker.clamps-top-and-bottom-edges") {
        let viewport = CGSize(width: 950, height: 600)
        for top in [-100, 0, 80, 550, 800] as [CGFloat] {
            let frame = TagPickerLayout.frame(
                anchor: CGRect(x: 250, y: top, width: 320, height: 150),
                panelSize: CGSize(width: 262, height: 240),
                viewport: viewport
            )
            try expect(frame.minY >= TagPickerLayout.edgeInset, "a scrolled card cannot put the picker above the app")
            try expect(frame.maxY <= viewport.height - TagPickerLayout.edgeInset, "a low card cannot put the picker below the app")
            try expectEqual(frame.minX, 578, "vertical clamping keeps the picker beside the card")
        }
    }

    register("tag-picker.long-lists-and-small-viewports-stay-inside") {
        for viewport in [CGSize(width: 950, height: 600), CGSize(width: 240, height: 180),
                         CGSize(width: 12, height: 12), .zero] {
            let available = TagPickerLayout.availableSize(in: viewport)
            let frame = TagPickerLayout.frame(
                anchor: CGRect(x: 200, y: 400, width: 340, height: 150),
                panelSize: CGSize(width: 262, height: 3000),
                viewport: viewport
            )
            try expectEqual(frame.size, CGSize(width: min(262, available.width), height: available.height),
                            "the list is constrained to the app's available space")
            try expect(frame.minX >= 0 && frame.minY >= 0, "even a tiny viewport has a nonnegative origin")
            try expect(frame.maxX <= viewport.width && frame.maxY <= viewport.height,
                       "an oversized picker never extends outside its viewport")
        }
    }

    register("tag-picker.recomputes-placement-after-a-resize-or-scroll") {
        let panel = CGSize(width: 262, height: 180)
        let original = TagPickerLayout.frame(
            anchor: CGRect(x: 248, y: 180, width: 420, height: 150),
            panelSize: panel, viewport: CGSize(width: 1100, height: 860)
        )
        let moved = TagPickerLayout.frame(
            anchor: CGRect(x: 248, y: 90, width: 320, height: 150),
            panelSize: panel, viewport: CGSize(width: 950, height: 600)
        )
        try expectEqual(original.origin, CGPoint(x: 676, y: 180), "initial card position")
        try expectEqual(moved.origin, CGPoint(x: 576, y: 90), "new card bounds replace the old position")
    }
}

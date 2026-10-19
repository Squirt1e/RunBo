import Foundation
import Core

/// The display mode decides how much of a card a person sees at a glance, so the rules worth
/// pinning down are the ones that would quietly change what they see: a setting that comes back
/// as the wrong shape, a column count that stretches the cards, or one menu's choice leaking
/// into the other.
func registerCardDisplayChecks() {
    register("card-display.mode-round-trips") {
        for mode in CardDisplayMode.allCases {
            try expectEqual(CardDisplay.mode(fromStored: mode.rawValue), mode,
                            "\(mode.rawValue) must come back as itself")
        }
        try expectEqual(CardDisplayMode.allCases.count, 2, "the switcher offers two shapes")
        try expectEqual(CardDisplayMode.wide.other, .square, "wide flips to square")
        try expectEqual(CardDisplayMode.square.other, .wide, "square flips back to wide")
        try expectEqual(CardDisplayMode.wide.label, "详细", "wide layout label")
        try expectEqual(CardDisplayMode.square.label, "精简", "square layout label")
    }

    register("card-display.missing-or-junk-values-fall-back-to-wide") {
        // A list must never change shape because a setting went missing: the original layout is
        // the safe answer for anything we cannot read.
        for value in [nil, "", "  ", "grid", "SQUARE", "wide ", "0"] as [String?] {
            try expectEqual(CardDisplay.mode(fromStored: value), .wide,
                            "\(value ?? "nil") is not a mode")
        }
    }

    register("card-display.each-menu-owns-its-key") {
        // Two menus, two settings: switching one list must not move the other.
        try expect(CardDisplay.key(for: .preset) != CardDisplay.key(for: .temp),
                   "both menus would share one setting")
        try expectEqual(CardDisplay.key(for: .preset), CardDisplay.presetsKey, "presets key")
        try expectEqual(CardDisplay.key(for: .temp), CardDisplay.tempsKey, "temps key")
    }

    register("card-display.wide-cards-wrap-at-the-minimum") {
        let minimum = CardDisplay.wideColumnMinimum
        let twoCards = minimum * 2 + CardDisplay.spacing
        let beforeWrap = CardDisplay.wideGrid(in: twoCards - 1, itemCount: 4)
        try expectEqual(beforeWrap.columns, 1, "one point below the two-card threshold")
        try expectEqual(beforeWrap.cardWidth, CardDisplay.wideColumnMaximum,
                        "a single column stops growing at its readable maximum")

        let atWrap = CardDisplay.wideGrid(in: twoCards, itemCount: 4)
        try expectEqual(atWrap.columns, 2, "two cards fit at their minimum width")
        try expectEqual(atWrap.cardWidth, minimum, "each card starts at its minimum")
        try expectEqual(CardDisplay.wideGrid(in: 692, itemCount: 4).cardWidth, 340,
                        "the narrow window shares spare room between two cards")
    }

    register("card-display.home-wide-cards-use-only-the-columns-they-need") {
        let one = CardDisplay.wideGrid(in: 1_768, itemCount: 1)
        try expectEqual(one.columns, 1, "one card keeps one column in a large window")
        try expectEqual(one.cardWidth, CardDisplay.wideColumnMaximum,
                        "a sparse group never stretches a card into a full-width banner")

        let four = CardDisplay.wideGrid(in: 1_768, itemCount: 4)
        try expectEqual(four.columns, 4, "four cards do not reserve an empty fifth column")
        try expectEqual(four.cardWidth, 433,
                        "cards share spare room below their maximum")

        let five = CardDisplay.wideGrid(in: 1_768, itemCount: 5)
        try expectEqual(five.columns, 5, "a fifth card fits after the window grows")
        try expectEqual(five.cardWidth, 344, "five cards divide the available width")

        for width in [CGFloat.nan, .infinity, -100, 0] {
            let grid = CardDisplay.wideGrid(in: width, itemCount: 4)
            try expectEqual(grid.columns, 1, "invalid widths safely use one column")
            try expectEqual(grid.cardWidth, CardDisplay.wideColumnMinimum, "invalid width fallback")
        }
    }

    register("card-display.wide-groups-cap-card-width-without-overflow") {
        for width in [CGFloat(1), 240, 319, 320, 651, 652, 1_000, 1_519, 1_768, 4_000] {
            for count in [-1, 0, 1, 2, 3, 4, 9] {
                let grid = CardDisplay.wideGrid(in: width, itemCount: count)
                try expect(grid.columns >= 1 && grid.columns <= max(1, count),
                           "no phantom columns for \(count) stacks at \(width)pt")
                let usedWidth = CGFloat(grid.columns) * grid.cardWidth
                    + CGFloat(grid.columns - 1) * CardDisplay.spacing
                try expect(usedWidth <= width + 0.001, "group cannot overflow its available width")
                try expect(grid.cardWidth <= CardDisplay.wideColumnMaximum, "even a single card respects the maximum")
                try expect(abs(usedWidth - width) < 0.001 || grid.cardWidth == CardDisplay.wideColumnMaximum,
                           "unused trailing room is only introduced by the maximum")
                try expect(grid.cardWidth > 0 && grid.cardWidth <= width, "cards stay inside narrow viewports")
                try expect(grid.columns == 1 || grid.cardWidth >= CardDisplay.wideColumnMinimum,
                           "multiple columns must respect the preferred minimum")
            }
        }
    }

    register("card-display.list-tracks-do-not-depend-on-group-size") {
        let screenshot = CardDisplay.wideListGrid(in: 1_426)
        try expectEqual(screenshot.columns, 4, "the screenshot viewport defines four shared tracks")
        try expectEqual(screenshot.cardWidth, 347.5, "Pi, Clash and Scripts all use the same card width")
        let large = CardDisplay.wideListGrid(in: 1_768)
        try expectEqual(large.columns, 5, "sparse groups keep the fifth track empty instead of stretching")
        try expectEqual(large.cardWidth, 344, "group population cannot change track width")
        try expectEqual(CardDisplay.wideGrid(in: 1_768, itemCount: 1).cardWidth, 480,
                        "the independent home preview retains its existing sizing")
    }

    register("card-display.list-tracks-wrap-without-overflow") {
        for width in [CGFloat(1), 240, 319, 320, 651, 652, 983, 984, 1_315, 1_316, 1_426, 1_768, 4_000, .greatestFiniteMagnitude] {
            let grid = CardDisplay.wideListGrid(in: width)
            let usedWidth = CGFloat(grid.columns) * grid.cardWidth + CGFloat(grid.columns - 1) * CardDisplay.spacing
            try expect(grid.columns >= 1, "a list always has at least one track")
            try expect(usedWidth <= width + 0.001, "shared tracks fit inside \(width)pt")
            try expect(grid.cardWidth > 0 && grid.cardWidth <= min(width, CardDisplay.wideColumnMaximum),
                       "shared cards shrink in narrow viewports and respect their cap")
            try expect(grid.columns == 1 || grid.cardWidth >= CardDisplay.wideColumnMinimum,
                       "multiple tracks respect the minimum card width")
        }
        try expectEqual(CardDisplay.wideListGrid(in: 651).columns, 1, "before the two-track threshold")
        try expectEqual(CardDisplay.wideListGrid(in: 652).columns, 2, "at the two-track threshold")
        try expectEqual(CardDisplay.wideListGrid(in: 983).columns, 2, "before the three-track threshold")
        try expectEqual(CardDisplay.wideListGrid(in: 984).columns, 3, "at the three-track threshold")
        for width in [CGFloat.nan, .infinity, -100, 0] {
            let grid = CardDisplay.wideListGrid(in: width)
            try expectEqual(grid.columns, 1, "invalid viewport fallback")
            try expectEqual(grid.cardWidth, CardDisplay.wideColumnMinimum, "invalid card width fallback")
        }
    }

    register("card-display.square-cards-keep-their-size") {
        // The square's side is the wide card's height, so the two layouts share a row rhythm.
        try expectEqual(CardDisplay.cardHeight, 150, "the measured height of a wide card")

        // A row that fits exactly, and one that has room for nothing more.
        let four = CardDisplay.cardHeight * 4 + CardDisplay.spacing * 3
        try expectEqual(CardDisplay.squareColumns(in: four), 4, "four cards fit exactly")
        try expectEqual(CardDisplay.squareColumns(in: four + CardDisplay.spacing + 1), 4,
                        "a hair over four cards' width is still four columns")
        try expectEqual(CardDisplay.squareColumns(in: four + CardDisplay.spacing + CardDisplay.cardHeight), 5,
                        "one more card's worth of room makes five")
    }

    register("card-display.column-count-survives-odd-windows") {
        // A window can be dragged anywhere; none of these may produce zero or a negative count.
        for width in [CGFloat(0), -100, 1, 100, 149, 150, 161, 162, 710, 942, 1200, 4000] {
            let columns = CardDisplay.squareColumns(in: width)
            try expect(columns >= 1, "width \(width) produced \(columns) columns")
            try expect(CGFloat(columns) * CardDisplay.cardHeight
                       + CGFloat(columns - 1) * CardDisplay.spacing <= max(width, CardDisplay.cardHeight),
                       "width \(width) claims \(columns) cards fit, but they do not")
        }
        try expectEqual(CardDisplay.squareColumns(in: 710), 4,
                        "the app's current window fits four square cards")
        try expectEqual(CardDisplay.squareColumns(in: .nan), 1, "NaN must not crash the grid")
        try expectEqual(CardDisplay.squareColumns(in: .infinity), 1, "nor must infinity")
    }
}

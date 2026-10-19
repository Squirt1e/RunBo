import Foundation
import TerminalDeckKit

/// The terminal font size is a settings value that reaches the renderer, so the rules worth
/// pinning down are the ones the UI cannot express: what an untouched or damaged value means.
/// The settings row disables its buttons at the ends of the range, which is why the range
/// itself has to be a fact rather than a convention repeated in the view.
func registerTerminalFontSizeChecks() {
    register("font.default-is-the-smallest-allowed-size") {
        try expectEqual(TerminalFontSize.default, 12, "the default size")
        try expectEqual(TerminalFontSize.minimum, 12, "the smallest size the settings row offers")
        try expectEqual(TerminalFontSize.maximum, 24, "the largest size the settings row offers")
        try expect(
            TerminalFontSize.minimum <= TerminalFontSize.default
                && TerminalFontSize.default <= TerminalFontSize.maximum,
            "the default must sit inside the range"
        )
    }

    register("font.values-inside-the-range-are-kept") {
        for value in [12.0, 13, 18, 23, 24] {
            try expectEqual(TerminalFontSize.clamp(value), value, "size \(value) is allowed")
        }
    }

    register("font.values-below-the-minimum-snap-up") {
        // A terminal at 0 or 6 points is not small, it is unusable, so the floor has to hold.
        try expectEqual(TerminalFontSize.clamp(11.9), 12, "a size just under the minimum")
        try expectEqual(TerminalFontSize.clamp(0), 12, "zero")
        try expectEqual(TerminalFontSize.clamp(-40), 12, "a negative size")
    }

    register("font.values-above-the-maximum-snap-down") {
        // Beyond the top end the window fits too few columns for most programs to lay out.
        try expectEqual(TerminalFontSize.clamp(24.1), 24, "a size just over the maximum")
        try expectEqual(TerminalFontSize.clamp(240), 24, "a far too large size")
    }

    register("font.missing-or-unusable-values-fall-back-to-the-default") {
        // What `AppModel` passes on when the settings row is absent or holds junk.
        try expectEqual(TerminalFontSize.clamp(nil), TerminalFontSize.default, "no stored value")
        try expectEqual(TerminalFontSize.clamp(Double("")), TerminalFontSize.default, "an empty stored value")
        try expectEqual(TerminalFontSize.clamp(Double("abc")), TerminalFontSize.default, "a non-numeric value")
        try expectEqual(TerminalFontSize.clamp(.nan), TerminalFontSize.default, "a NaN value")
        try expectEqual(TerminalFontSize.clamp(.infinity), TerminalFontSize.default, "an infinite value")
    }

    register("font.presets-are-inside-the-range-and-distinct") {
        // The settings row offers these as one-click segments, so every one of them has to be a
        // size the terminal may actually be shown at, and no two may share a name or a size.
        try expectEqual(TerminalFontSize.presets.count, 3, "three named sizes")
        let names = TerminalFontSize.presets.map(\.name)
        let values = TerminalFontSize.presets.map(\.points)
        try expectEqual(Set(names).count, names.count, "preset names are unique")
        try expectEqual(Set(values).count, values.count, "preset sizes are unique")
        for value in values {
            try expect(value >= TerminalFontSize.minimum && value <= TerminalFontSize.maximum,
                       "preset \(value) is inside the range")
            try expectEqual(TerminalFontSize.clamp(value), value, "preset \(value) needs no clamping")
        }
    }

    register("font.a-value-highlights-at-most-one-preset") {
        // Numeric preset lookup is exact. The UI separately remembers whether the user selected
        // this number through a preset or the custom field.
        for preset in TerminalFontSize.presets {
            try expectEqual(TerminalFontSize.preset(for: preset.points), preset.name,
                            "\(preset.points) is the \(preset.name) size")
        }
        for typed in [12.5, 13, 14, 16, 21, 24] {
            let matched = TerminalFontSize.preset(for: typed)
            if let matched {
                let points = TerminalFontSize.presets.first { $0.name == matched }?.points
                try expectEqual(points, TerminalFontSize.clamp(typed),
                                "a highlighted segment must hold the value itself")
            }
        }
        try expectEqual(TerminalFontSize.preset(for: 13), nil, "13 is nobody's preset")
        try expectEqual(TerminalFontSize.preset(for: 24), nil, "the maximum is not a preset either")
    }

    register("font.stored-form-stays-inside-the-range") {
        try expectEqual(TerminalFontSize.storageValue(18), "18", "a whole size is stored as the number")
        try expectEqual(TerminalFontSize.storageValue(18.4), "18", "a fractional size is stored whole")
        try expectEqual(TerminalFontSize.storageValue(nil), "12", "a missing size is stored as the default")
        try expectEqual(TerminalFontSize.storageValue(99), "24", "an oversized value is stored clamped")
        try expectEqual(TerminalFontSize.storageValue(1), "12", "an undersized value is stored clamped")

        // Round-tripping the stored text must land on the very same size, or every launch
        // would drift by a fraction.
        for value in [12.0, 15, 21, 24] {
            try expectEqual(Double(TerminalFontSize.storageValue(value)), value, "round trip of \(value)")
        }
    }
}

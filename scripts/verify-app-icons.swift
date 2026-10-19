import AppKit
@testable import TerminalDeck

@main
struct VerifyAppIcons {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw NSError(domain: "AppIconVerification", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        print("PASS \(message)")
    }

    @MainActor static func bitmap(_ name: String) throws -> NSBitmapImageRep {
        guard let url = AppIcons.resourceBundle.url(forResource: name, withExtension: "png"),
              let image = NSBitmapImageRep(data: try Data(contentsOf: url)) else {
            throw NSError(domain: "AppIconVerification", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Missing PNG: \(name)"])
        }
        return image
    }

    @MainActor static func main() {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            if CommandLine.arguments.contains("--packaged") {
                let expected = Bundle.main.resourceURL!
                    .appendingPathComponent("TerminalDeck_TerminalDeck.bundle")
                try check(AppIcons.resourceBundle.bundleURL.standardizedFileURL == expected.standardizedFileURL,
                          "relocated app loads icons from its own Contents/Resources")
            }
            try check(AppIcons.applicationImage != nil && AppIcons.applicationImage?.isTemplate == false,
                      "application icon loads as original colour artwork")
            let app = try bitmap("AppIcon")
            try check(app.pixelsWide == 1024 && app.pixelsHigh == 1024, "application artwork is 1024px")
            try check(app.colorAt(x: 0, y: 0)?.alphaComponent == 0, "application canvas corners are transparent")
            try check(app.colorSpace.iccProfileData == NSColorSpace.sRGB.iccProfileData,
                      "application artwork is explicitly tagged sRGB")
            // colorAt returns an NSCalibratedRGBColor on some macOS versions;
            // compare encoded samples directly rather than converting that convenience colour.
            var cursor = [Int](repeating: 0, count: app.samplesPerPixel)
            app.getPixel(&cursor, atX: 560, y: 636)
            try check(Array(cursor.prefix(3)) == [238, 161, 110],
                      "approved apricot cursor is present, not an earlier palette")
            var tile = [Int](repeating: 0, count: app.samplesPerPixel)
            app.getPixel(&tile, atX: 140, y: 512)
            try check(tile[0] > 153 && tile[2] > tile[0],
                      "approved pale mist-blue tile is present")

            guard let menu = AppIcons.menuBarImage else {
                throw NSError(domain: "AppIconVerification", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Menu icon failed to load"])
            }
            try check(menu.accessibilityDescription == "RunBo", "menu icon accessibility name is RunBo")
            try check(menu.isTemplate && menu.size == NSSize(width: 22, height: 22),
                      "menu icon is a 22pt system-tinted template")
            try check(Set(menu.representations.map(\.pixelsWide)) == Set([22, 44]),
                      "menu icon contains explicit 1x and Retina 2x representations")
            for (name, size) in [("MenuBarIcon", 22), ("MenuBarIcon@2x", 44)] {
                let image = try bitmap(name)
                try check(image.pixelsWide == size && image.pixelsHigh == size, "\(name) dimensions")
                var visible = 0
                var minX = size, minY = size, maxX = -1, maxY = -1
                for y in 0..<size {
                    for x in 0..<size {
                        let color = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        guard color.alphaComponent > 0.1 else { continue }
                        visible += 1
                        minX = min(minX, x)
                        minY = min(minY, y)
                        maxX = max(maxX, x)
                        maxY = max(maxY, y)
                        try checkBlack(color)
                    }
                }
                try check(visible > size * 3, "\(name) has a non-empty pure-black glyph")
                let glyphWidth = Double(maxX - minX + 1)
                let glyphHeight = Double(maxY - minY + 1)
                let scale = Double(size) / 22
                try check(glyphWidth / glyphHeight >= 1.35 && glyphHeight / scale <= 14,
                          "\(name) keeps a wide, low silhouette instead of a square stack")
                try check(abs(minX - (size - 1 - maxX)) <= 1
                          && abs(minY - (size - 1 - maxY)) <= 1,
                          "\(name) visible artwork is centered on its canvas")
                try check(image.colorAt(x: 0, y: 0)?.alphaComponent == 0,
                          "\(name) background is transparent")
            }
            print("App icon checks passed")
        } catch {
            print("FAIL \(error.localizedDescription)")
            exit(1)
        }
    }

    static func checkBlack(_ color: NSColor) throws {
        guard max(color.redComponent, color.greenComponent, color.blueComponent) < 0.01 else {
            throw NSError(domain: "AppIconVerification", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Menu template must remain monochrome"])
        }
    }
}

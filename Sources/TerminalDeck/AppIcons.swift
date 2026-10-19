import AppKit
import Foundation

/// Approved Mist / Apricot branding, including a separate monochrome status-item glyph.
@MainActor
enum AppIcons {
    // Packaged apps carry SwiftPM bundles in Contents/Resources; swift run uses .module.
    static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "TerminalDeck_TerminalDeck", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    static let applicationImage: NSImage? = {
        guard let url = resourceBundle.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }()

    static let menuBarImage: NSImage? = {
        let logicalSize = NSSize(width: 22, height: 22)
        let image = NSImage(size: logicalSize)
        // Explicit representations avoid loose-PNG named-image cache/Retina lookup issues.
        for name in ["MenuBarIcon", "MenuBarIcon@2x"] {
            guard let url = resourceBundle.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else { return nil }
            representation.size = logicalSize
            image.addRepresentation(representation)
        }
        image.isTemplate = true
        image.accessibilityDescription = "RunBo"
        return image
    }()
}

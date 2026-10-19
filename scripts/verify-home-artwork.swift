import AppKit
import SwiftUI
@testable import App

@main
struct VerifyHomeArtwork {
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else {
            throw NSError(domain: "HomeArtworkVerification", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: label])
        }
        print("PASS \(label)")
    }

    @MainActor static func render(_ scheme: ColorScheme) throws -> [UInt8] {
        let renderer = ImageRenderer(content: OxMarkView()
            .frame(width: 246, height: 245)
            .environment(\.colorScheme, scheme))
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            throw NSError(domain: "HomeArtworkVerification", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "artwork must produce an image"])
        }
        var pixels = [UInt8](repeating: 0, count: 246 * 245 * 4)
        let drawn = pixels.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: 246, height: 245,
                                          bitsPerComponent: 8, bytesPerRow: 246 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 246, height: 245))
            return true
        }
        try check(drawn, "\(scheme): rendered pixels are readable")
        var ink = 0, white = 0, beer = 0, transparent = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let a = pixels[index + 3]
            if a < 10 { transparent += 1 }
            guard a > 240 else { continue }
            if max(r, g, b) < 80 { ink += 1 }
            if min(r, g, b) > 220 { white += 1 }
            if r > 180 && g > 100 && g < 210 && b < 100 { beer += 1 }
        }
        try check(ink > 5_000, "\(scheme): black ink is visible, not an empty named image")
        try check(white > 10_000, "\(scheme): cow body stays white")
        try check(beer > 500, "\(scheme): beer retains its original colour")
        try check(transparent > 5_000, "\(scheme): outer paper remains transparent")
        return pixels
    }

    @MainActor static func main() {
        do {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let packaged = CommandLine.arguments.contains("--packaged")
            if packaged {
                try check(Bundle.main.bundleURL.pathExtension == "app", "verifier runs inside a relocated .app")
                let expected = Bundle.main.resourceURL!.appendingPathComponent("RunBo_App.bundle")
                try check(OxMarkView.artworkBundle.bundleURL.standardizedFileURL == expected.standardizedFileURL,
                          "packaged artwork resolves inside Contents/Resources, without build-path fallback")
            }
            let light = try render(.light)
            let dark = try render(.dark)
            try check(light == dark, "light/dark appearances preserve identical original artwork")
            print("Artwork checks passed (\(packaged ? "packaged" : "SwiftPM"))")
        } catch {
            print("FAIL \(error.localizedDescription)")
            exit(1)
        }
    }
}

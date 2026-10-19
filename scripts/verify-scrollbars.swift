import AppKit
import SwiftUI
import SwiftTerm
import PDFKit
import WebKit
import TerminalDeckKit
@testable import TerminalDeck

@main struct VerifyScrollbars {
    @MainActor static var checks = 0
    @MainActor static var windows: [NSWindow] = []
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
        guard value() else { throw NSError(domain: "ScrollbarCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        checks += 1
    }
    @MainActor static func pump(_ seconds: Double = 0.12) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    @MainActor static func wait(_ label: String, _ condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(12)
        while !condition(), Date() < end { pump(0.03) }
        try check(condition(), label)
    }
    @MainActor static func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    @MainActor static func mount(_ view: NSView, size: NSSize = NSSize(width: 640, height: 400)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "RunBo — isolated scrollbar checks"
        window.contentView = view
        // Hidden layer-backed windows still exercise the real AppKit rendering path.
        view.wantsLayer = true
        windows.append(window)
        view.layoutSubtreeIfNeeded()
        pump()
        return window
    }
    @MainActor static func bitmap(_ view: NSView, scale: Int = 2) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale,
                                  pixelsHigh: Int(view.bounds.height) * scale, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = view.bounds.size
        memset(rep.bitmapData!, 0, rep.bytesPerRow * rep.pixelsHigh)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
    @MainActor static func save(_ view: NSView, _ name: String) throws {
        guard let i = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > i + 1 else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap(view).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }
    @MainActor static func alpha(_ rep: NSBitmapImageRep, _ cross: Int, _ along: Int, vertical: Bool) -> CGFloat {
        rep.colorAt(x: vertical ? cross : along, y: vertical ? along : cross)!.alphaComponent
    }
    @MainActor static func rasterChecks() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for vertical in [true, false] {
                let parent = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
                let scroller = DeckScroller(frame: vertical ? NSRect(x: 20, y: 20, width: 12, height: 180)
                                                           : NSRect(x: 20, y: 20, width: 180, height: 12))
                parent.addSubview(scroller)
                let window = mount(parent, size: parent.frame.size)
                window.appearance = NSAppearance(named: appearance)
                scroller.knobStyle = .default
                scroller.isEnabled = true
                scroller.knobProportion = 0.25
                for style in [NSScroller.Style.legacy, .overlay] {
                    scroller.scrollerStyle = style
                    try check(scroller.scrollerStyle == .legacy && !scroller.wantsUpdateLayer,
                              "custom drawing cannot reenter AppKit's system layer/overlay renderer")
                    for position in [0.0, 0.5, 1.0] {
                        scroller.doubleValue = position
                        scroller.reveal()
                        let slot = scroller.rect(for: .knobSlot), thumb = scroller.rect(for: .knob)
                        try check(slot.contains(thumb), "thumb lies wholly inside inset track at \(position)")
                        try check((vertical ? slot.width : slot.height) == 4, "visual thickness is exactly 4 logical pixels")
                        try check((vertical ? slot.minY : slot.minX) == 2, "track leaves a full 2pt end margin")
                        for scale in [1, 2] {
                            let rep = bitmap(scroller, scale: scale)
                            let crossCount = vertical ? rep.pixelsWide : rep.pixelsHigh
                            let alongCount = vertical ? rep.pixelsHigh : rep.pixelsWide
                            var trackRows: [Int] = [], thumbRows: [Int] = []
                            for along in 0..<alongCount {
                                let values = (0..<crossCount).map { alpha(rep, $0, along, vertical: vertical) }
                                if values.contains(where: { $0 > 0.02 }) { trackRows.append(along) }
                                if values.contains(where: { $0 > 0.3 }) { thumbRows.append(along) }
                            }
                            try check(!trackRows.isEmpty && !thumbRows.isEmpty, "real layer-backed cache contains track AND thumb, not just numeric geometry")
                            let middle = thumbRows[thumbRows.count / 2]
                            let inkColumns = (0..<crossCount).filter { alpha(rep, $0, middle, vertical: vertical) > 0.3 }
                            try check(inkColumns.count == 4 * scale, "actual painted thumb is \(4 * scale) backing pixels at \(scale)x, \(appearance), \(vertical), \(style), \(position); got \(inkColumns.count)")
                            try check(trackRows.first! == 2 * scale && trackRows.last! == alongCount - 2 * scale - 1, "both track caps stay away from the clipping boundary")
                            func mass(_ row: Int) -> CGFloat { (0..<crossCount).reduce(0) { $0 + alpha(rep, $1, row, vertical: vertical) } }
                            let bodyMass = mass(middle)
                            try check(mass(thumbRows.first!) < bodyMass - 0.1 && mass(thumbRows.last!) < bodyMass - 0.1,
                                      "thumb top/bottom are rounded in pixels, not flat clipped ends")
                            // The first/last track rows have round cap coverage; compare with a
                            // neighbouring body row, whether or not the thumb is at that end.
                            try check(mass(trackRows.first!) < mass(trackRows.first! + 3 * scale) - 0.02
                                      && mass(trackRows.last!) < mass(trackRows.last! - 3 * scale) - 0.02,
                                      "track top/bottom are complete rounded caps")
                        }
                    }
                }
                scroller.knobProportion = 0.00001
                let tiny = scroller.rect(for: .knob)
                try check((vertical ? tiny.height : tiny.width) == 24, "long documents keep a usable 24pt minimum thumb")
                try save(parent, "caps-\(appearance.rawValue)-\(vertical ? "vertical" : "horizontal")")
            }
        }
        print("PASS raster: 1x/2x, light/dark, vertical/horizontal, both system styles, top/middle/bottom")
    }

    @MainActor static func nativeChecks() throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 180))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1800))
        scroll.documentView = document
        DeckScroller.install(in: scroll)
        let window = mount(scroll, size: scroll.frame.size)
        let v = scroll.verticalScroller as! DeckScroller, h = scroll.horizontalScroller as! DeckScroller
        for style in [NSScroller.Style.legacy, .overlay] {
            scroll.scrollerStyle = style; scroll.tile(); pump()
            scroll.contentView.scroll(to: NSPoint(x: 10, y: 10))
            scroll.reflectScrolledClipView(scroll.contentView)
            try check(scroll.scrollerStyle == .legacy, "system overlay preference safely falls back to custom metrics")
            try check(v.frame.width == 8 && h.frame.height == 8, "8pt native gutters leave transparent safety space around the 4pt paint")
            for position in [0.0, 0.5, 1.0] {
                let bounds = scroll.contentView.bounds
                scroll.contentView.scroll(to: NSPoint(x: (document.frame.width - bounds.width) * position,
                                                     y: (document.frame.height - bounds.height) * position))
                scroll.reflectScrolledClipView(scroll.contentView)
                pump(0.03)
                try check(abs(h.doubleValue - position) < 0.001, "horizontal geometry follows the document")
                try check(abs(v.doubleValue - (1 - position)) < 0.001, "vertical geometry respects unflipped document coordinates")
                try check(v.alphaValue == 1 && h.alphaValue == 1, "clip scrolling reveals both scrollers: v=\(v.alphaValue), h=\(h.alphaValue), position=\(position)")
                for s in [v, h] {
                    let rect = s.rect(for: .knob)
                    let point = s.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                    try check(s.testPart(point) == .knob, "native hit testing uses the painted knob")
                }
            }
        }
        // Native trackKnob consumes queued drag/up events; never post desktop CGEvents
        // or activate this window. This tests NSScroller's real target/action integration.
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        for s in [v, h] {
            let knob = s.rect(for: .knob)
            let start = s.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
            let end = s.convert(NSPoint(x: s === v ? knob.midX : s.bounds.midX,
                                       y: s === v ? s.bounds.midY : knob.midY), to: nil)
            let oldPosition = s.doubleValue
            NSApp.postEvent(mouse(.leftMouseDragged, end), atStart: false)
            NSApp.postEvent(mouse(.leftMouseUp, end), atStart: false)
            s.mouseDown(with: mouse(.leftMouseDown, start))
            try check(abs(s.doubleValue - oldPosition) > 0.1, "native thumb dragging moves the actual document on both axes")
            for part in [NSScroller.Part.decrementPage, .incrementPage] {
                let page = s.rect(for: part)
                try check(!page.isEmpty && s.testPart(s.convert(NSPoint(x: page.midX, y: page.midY), to: nil)) == part,
                          "native page click targets match the painted track on both axes")
            }
        }
        v.mouseEntered(with: mouse(.mouseMoved, .zero))
        pump(DeckScrollbarStyle.hideDelay + 0.15)
        try check(v.alphaValue == 1, "hover holds the shared track/thumb visible beyond the hide delay")
        v.mouseExited(with: mouse(.mouseMoved, .zero))
        pump(DeckScrollbarStyle.hideDelay + 0.15)
        try check(v.alphaValue == 0, "auto-hide works independently of system preference after pointer exit")
        try check(v.hitTest(v.frame.origin) == nil, "hidden scrollbar never swallows content clicks")
        v.reveal()
        try check(v.alphaValue == 1, "scrollbar can be revealed after hiding")
        document.setFrameSize(NSSize(width: 30, height: 30)); scroll.tile(); pump()
        try check(v.isHidden || !v.isEnabled, "nonoverflowing content has no active vertical scrollbar")
        print("PASS native: layout, values, hit tests, drag, auto-hide and nonoverflow")
    }

    /// Check the FINAL composited page, not the scroller in isolation. Panel strokes
    /// used to cover one backing-pixel column even after the custom renderer was fixed.
    @MainActor static func compositedChecks(_ host: NSView, scrollers: [DeckScroller]) throws {
        try check(host.isFlipped, "page pixel coordinates are top-down")
        for scale in [1, 2] {
            scrollers.forEach { $0.hideNow() }
            let background = bitmap(host, scale: scale)
            scrollers.forEach { $0.reveal() }
            let painted = bitmap(host, scale: scale)
            for s in scrollers {
                let slot = s.convert(s.rect(for: .knobSlot), to: host)
                let thumb = s.convert(s.rect(for: .knob), to: host)
                let x0 = Int((slot.minX - 1) * CGFloat(scale)), x1 = Int((slot.maxX + 1) * CGFloat(scale))
                func contrast(_ x: Int, _ y: Int) -> CGFloat {
                    let a = background.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    let b = painted.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    return max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
                }
                let midY = Int(thumb.midY * CGFloat(scale))
                let columns = (x0..<x1).filter { contrast($0, midY) > 0.15 }
                try check(columns.count == 4 * scale,
                          "composited sidebar/file thumb is fully visible at \(scale)x, not covered by panel border (got \(columns.count) columns)")
                func mass(_ y: Int) -> CGFloat { (x0..<x1).reduce(0) { $0 + contrast($1, y) } }
                let top = Int(thumb.minY * CGFloat(scale)), bottom = Int(ceil(thumb.maxY * CGFloat(scale))) - 1
                try check(mass(top) < mass(midY) - 0.05 && mass(bottom) < mass(midY) - 0.05,
                          "composited thumb has two round caps even at document extremes")
                let trackTop = Int(slot.minY * CGFloat(scale)), trackBottom = Int(slot.maxY * CGFloat(scale)) - 1
                try check(mass(trackTop) < mass(trackTop + 3 * scale) - 0.01
                          && mass(trackBottom) < mass(trackBottom - 3 * scale) - 0.01,
                          "composited track has two complete round caps, not hidden by a separator")
            }
        }
    }

    @MainActor static func appChecks(_ root: URL) throws {
        let store = try TerminalDeckStore(directory: root.appendingPathComponent("store"))
        for i in 0..<60 {
            try store.save(PresetCard(id: "\(i)", title: "Project \(i)", command: "true", workingDirectory: root.path))
            try Data().write(to: root.appendingPathComponent("file-\(i).txt"))
        }
        let model = AppModel(store: store)
        model.enterWorkhorseMode(); model.dismissNotice()
        model.page = .detail(OwnerKey(kind: .preset, ownerId: "0"))
        model.fileBrowser.togglePinned()
        if !model.fileBrowser.isVisible { model.fileBrowser.toggle() }
        let host = NSHostingView(rootView: DeckRootView(model: model))
        let window = mount(host, size: NSSize(width: 1100, height: 860))
        try wait("sidebar and file tree install their own scrollers") { descendants(host, DeckScroller.self).count >= 2 }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for collapsed in [false, true] {
                _ = model.sidebar.setMode(collapsed ? .collapsed : .pinned)
                if collapsed { model.sidebar.pointerChanged(true); pump(0.3) }
                pump(0.3); host.layoutSubtreeIfNeeded()
                let scrolls = descendants(host, NSScrollView.self).filter { $0.hasVerticalScroller }
                try check(scrolls.count >= 2, "fixture includes both expanded sidebar and file tree")
                for scroll in scrolls {
                    try check(scroll.verticalScroller is DeckScroller, "every visible app scroll area has the shared implementation")
                    let s = scroll.verticalScroller as! DeckScroller
                    s.reveal()
                    try check(s.frame.width == 8 && s.rect(for: .knob).width == 4, "sidebar/file tree never regress to native wide scrollers")
                }
                let scrollers = scrolls.compactMap { $0.verticalScroller as? DeckScroller }
                for position in [0.0, 0.5, 1.0] {
                    for scroll in scrolls {
                        guard let document = scroll.documentView else { continue }
                        let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: maxY * position))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    host.layoutSubtreeIfNeeded(); pump(0.04)
                    try compositedChecks(host, scrollers: scrollers)
                    try save(host, "app-\(appearance.rawValue)-\(collapsed ? "peek" : "pinned")-\(position)")
                }
                model.sidebar.windowInactive()
            }
        }
        model.page = .settings; pump(0.3)
        try wait("settings page survives SwiftUI remounting with the shared style") {
            host.layoutSubtreeIfNeeded()
            return descendants(host, NSScrollView.self).filter { $0.hasVerticalScroller }.allSatisfy { $0.verticalScroller is DeckScroller }
        }
        let textHost = NSHostingView(rootView: ReadOnlyFileText(text: String(repeating: String(repeating: "x", count: 200) + "\n", count: 100)))
        _ = mount(textHost)
        try check(descendants(textHost, DeckScroller.self).count == 2, "text previews share vertical and horizontal scrollers")
        let editorHost = NSHostingView(rootView: ShellTextEditor(text: .constant(String(repeating: "command\n", count: 100)), textColor: .labelColor, placeholder: ""))
        _ = mount(editorHost)
        try check(descendants(editorHost, DeckScroller.self).count == 1, "command editor uses the shared implementation")
        let image = ZoomableImagePreview(); _ = mount(image, size: NSSize(width: 800, height: 600))
        try check(image.verticalScroller is DeckScroller && image.horizontalScroller is DeckScroller, "image preview styles both axes")
        let imageBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 800,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let imageURL = root.appendingPathComponent("zoom.png")
        try imageBitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        image.load(url: imageURL); image.layoutSubtreeIfNeeded(); pump()
        let anchor = NSPoint(x: 250, y: 200)
        let before = image.documentView!.convert(anchor, to: image)
        let clipBefore = image.contentView.frame
        image.zoom(by: 2, at: anchor)
        let after = image.documentView!.convert(anchor, to: image)
        try check(image.contentView.frame == clipBefore && abs(before.x - after.x) < 1.5 && abs(before.y - after.y) < 1.5,
                  "fitted-to-overflow zoom never shifts the pointer anchor as scrollbars become enabled")
        image.zoom(by: 0.5, at: anchor)
        try check(image.contentView.frame == clipBefore, "zooming back to fit never removes gutters or shifts the viewport")
        let pdf = DeckPDFView(); pdf.displayMode = .singlePageContinuous
        let data = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 1200)).dataWithPDF(inside: NSRect(x: 0, y: 0, width: 800, height: 1200))
        pdf.document = PDFDocument(data: data); _ = mount(pdf); pdf.layoutSubtreeIfNeeded()
        let pdfScrolls = descendants(pdf, NSScrollView.self)
        try check(!pdfScrolls.isEmpty && pdfScrolls.allSatisfy { !$0.hasVerticalScroller || $0.verticalScroller is DeckScroller }, "PDFKit's internal scroll views use the shared style")
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let container = TerminalScrollContainer(terminal: terminal); _ = mount(container)
        terminal.feed(text: String(repeating: "scrollback\r\n", count: 200))
        container.flashScroller()
        try check(container.scroller.isEnabled && container.scroller.frame.width == 8 && !container.scroller.wantsUpdateLayer,
                  "terminal uses the same real renderer, not SwiftTerm's private system scrollbar")
        try check(terminal.subviews.compactMap { $0 as? NSScroller }.allSatisfy(\.isHidden), "SwiftTerm's system scrollbar cannot paint a second track")
        try save(container, "terminal")
        print("PASS app: pinned/peek sidebar + file tree, settings, editor, text/image/PDF previews, terminal")
    }

    @MainActor static func htmlChecks(_ root: URL) throws {
        try Data("<!doctype html><title>Scrollbars</title><div style='width:2400px;height:2400px'>Static preview</div>".utf8).write(to: root.appendingPathComponent("scroll.html"))
        var failure: String?
        let host = NSHostingView(rootView: StaticHTMLPreview(root: root, relative: "scroll.html", failure: { failure = $0 }))
        _ = mount(host)
        let web = descendants(host, WKWebView.self)[0]
        try wait("static HTML loaded") { web.title == "Scrollbars" || failure != nil }
        try check(failure == nil && !web.configuration.defaultWebpagePreferences.allowsContentJavaScript, "scrollbar CSS does not weaken HTML script restrictions")
        var result: String?, error: Error?, done = false
        web.evaluateJavaScript("['::-webkit-scrollbar','::-webkit-scrollbar-track','::-webkit-scrollbar-thumb'].map(p=>{let s=getComputedStyle(document.documentElement,p);return [s.width,s.borderRadius,s.borderLeftWidth,s.borderRightWidth,s.backgroundClip].join(',')}).join('|')") {
            result = $0 as? String; error = $1; done = true
        }
        try wait("WebKit CSS inspection completed") { done }
        try check(error == nil && result?.hasPrefix("8px,") == true && result?.contains("4px,2px,2px,padding-box") == true,
                  "WebKit paints 4px inside an 8px gutter with 2px transparent safety borders: \(result ?? "nil")")
        for scale in [1, 2] {
            // Title/DOM readiness precedes WebKit's asynchronous first compositing frame.
            try wait("actual WebKit thumb paint is 4px on BOTH axes at \(scale)x") {
                let rep = bitmap(host, scale: scale)
                func ink(_ x: Int, _ y: Int) -> CGFloat {
                    let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    return color.alphaComponent * (1 - color.redComponent)
                }
                let verticalColumns = (rep.pixelsWide - 12 * scale..<rep.pixelsWide).filter { ink($0, 20 * scale) > 0.3 }
                let horizontalRows = (rep.pixelsHigh - 12 * scale..<rep.pixelsHigh).filter { ink(100 * scale, $0) > 0.3 }
                return verticalColumns.count == 4 * scale && horizontalRows.count == 4 * scale
            }
        }
        try save(host, "html")
        print("PASS WebKit: shared CSS geometry with page JavaScript still disabled")
    }

    @MainActor static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scrollbar-checks-" + UUID().uuidString)
        defer { for window in windows { window.orderOut(nil); window.contentView = nil }; try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try rasterChecks(); try nativeChecks(); try appChecks(root); try htmlChecks(root)
            print("\(checks) SCROLLBAR CHECKS PASSED")
        } catch { print("FAIL \(error.localizedDescription)"); exit(1) }
    }
}

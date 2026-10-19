import AppKit
import SwiftUI
import WebKit
import PDFKit
import Network
import Core
@testable import App

@main
struct VerifyFileBrowser {
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw NSError(domain: "FileBrowserVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        print("PASS \(label)")
    }
    @MainActor static func pump(_ seconds: Double = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    @MainActor static func wait(_ label: String, timeout: Double = 15, _ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { pump() }
        try check(predicate(), label)
    }
    @MainActor static func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, type) }
    }
    @MainActor static var windows: [NSWindow] = []
    @MainActor static func host<V: View>(_ view: V, width: Double = 900, height: Double = 650) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "RunBo — isolated file checks"
        window.contentView = host
        window.orderBack(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        return host
    }
    @MainActor static func evaluate(_ script: String, on webView: WKWebView) throws -> String {
        var done = false, value: Any?, failure: Error?
        webView.evaluateJavaScript(script) { result, error in value = result; failure = error; done = true }
        try wait("WebKit inspection completed") { done }
        if let failure { throw failure }
        return value as? String ?? String(describing: value)
    }

    @MainActor static func modelChecks(_ root: URL) throws {
        let fm = FileManager.default
        let a = root.appendingPathComponent("work-a"), b = root.appendingPathComponent("work-b")
        try fm.createDirectory(at: a, withIntermediateDirectories: true)
        try fm.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: a.appendingPathComponent("hello.swift"))
        try fm.createDirectory(at: a.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let store = try DataStore(directory: root.appendingPathComponent("store"))
        try store.save(PresetCard(id: "a", title: "A", command: "printf FILES_READY", workingDirectory: a.path))
        try store.save(PresetCard(id: "b", title: "B", command: "true", workingDirectory: b.path))
        let model = AppModel(store: store)
        model.engine.baseEnvironment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        defer { model.engine.endAllSessions(timeout: 1) }
        let key = OwnerKey(kind: .preset, ownerId: "a"), other = OwnerKey(kind: .preset, ownerId: "b")
        try check(model.fileBrowserRoot(for: key).path == a.path, "unstarted card uses configured directory")
        let browser = model.fileBrowser
        let state = browser.card(for: key, root: a)
        let otherState = browser.card(for: other, root: b)
        state.open()
        try wait("directory loads asynchronously") { state.listings[""]?.count == 2 }
        let file = state.listings[""]!.first { $0.name == "hello.swift" }!
        let folder = state.listings[""]!.first { $0.name == "nested" }!
        state.state.selected = file.id; state.toggle(folder)
        try wait("expanded directory loads on demand") { state.listings["nested"] != nil }
        try check(otherState.state.selected == nil && otherState.state.expanded.isEmpty, "per-card tree state is independent")
        try check(browser.card(for: key, root: a) === state, "card navigation reuses runtime state")
        try check(!browser.isPinned && !browser.isVisible, "file panel starts as a closed floating panel in every layout")
        browser.close()
        browser.presentationChanged()
        try check(!browser.isVisible, "explicit close survives card/presentation changes")
        browser.toggle()
        browser.showPreview(file, root: a)
        try check(browser.consumeEscape() && browser.preview == nil && browser.isVisible, "first Escape closes only preview")
        try check(browser.consumeEscape() && !browser.isVisible, "next Escape closes only floating panel")
        try check(!browser.consumeEscape(), "terminal Escape is not intercepted when file UI is closed")
        browser.toggle()
        browser.togglePinned()
        browser.panelWidth = 300
        browser.saveWidth(report: { _ in })
        browser.presentationChanged()
        try check(browser.isPinned && browser.isVisible && !browser.consumeEscape(), "pinned panel survives presentation changes and does not consume terminal Escape")
        let restored = FileBrowserCoordinator(store: store)
        try check(restored.isPinned && restored.isVisible && restored.panelWidth == 300, "one global pin and width preference survives reopening")
        browser.togglePinned()
        try check(browser.isVisible && state.state.selected == file.id && state.state.expanded.contains(folder.id), "unpinning keeps panel open and preserves tree selection and expansion")
        try check(!FileBrowserCoordinator(store: store).isPinned, "unpinning persists the same global setting")
        model.page = .detail(key)
        model.startCard(model.card(for: "a")!)
        try wait("fixture terminal becomes ready") { model.liveRuntime(key)?.isReachable == true }
        let session = model.liveRuntime(key)!.sessionId
        model.beginEditCard(model.card(for: "a")!)
        model.editorWorkingDirectory = b.path
        try check(model.saveEditor(), "running card configuration can be edited")
        try check(model.fileBrowserRoot(for: key).path == a.path, "running session launch root wins over edited configuration")
        model.engine.send(text: "cd '\(b.path)'\n", to: session)
        pump(0.3)
        try check(model.fileBrowserRoot(for: key).path == a.path, "browser never follows shell cd")
        state.refresh()
        try wait("manual refresh completes") { state.loading.isEmpty }
        try check(model.liveRuntime(key)?.sessionId == session && state.state.selected == file.id, "refresh preserves PTY and file selection")
        try Data("new".utf8).write(to: a.appendingPathComponent(".hidden"))
        state.toggleHidden()
        try wait("hidden toggle refreshes disk") { state.listings[""]?.contains(where: { $0.name == ".hidden" }) == true }
        model.engine.endAllSessions(timeout: 1)
        pump(0.2)
        try check(model.fileBrowserRoot(for: key).path == a.path, "ended session retains its launch directory")
        state.setRoot(b)
        try check(state.state.selected == nil && state.state.expanded.isEmpty && state.listings.isEmpty, "root changes clear cached tree")
        try check(try String(contentsOf: a.appendingPathComponent("hello.swift"), encoding: .utf8) == "source", "browsing never modified source file")
        browser.remove([key])
        try check(browser.card(for: key, root: a) !== state, "deleted cards release runtime tree cache")
    }

    @MainActor static func nativeChecks(_ root: URL) throws {
        let textHost = host(ReadOnlyFileText(text: "import SwiftUI\n" + String(repeating: "text\n", count: 100)))
        try wait("native read-only text view is installed") { !descendants(textHost, NSTextView.self).isEmpty }
        let text = descendants(textHost, NSTextView.self)[0]
        try check(!text.isEditable && text.isSelectable && !text.isRichText && text.string.hasPrefix("import"), "text fallback is read-only, selectable source")
        try check(text.frame.height > 400 && text.enclosingScrollView?.hasVerticalScroller == true, "native text fallback lays out scrollable content")

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: root.appendingPathComponent("fixture.png"))
        let largeImage = NSImage(size: NSSize(width: 1000, height: 800))
        largeImage.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 800).fill(); largeImage.unlockFocus()
        let largePNG = NSBitmapImageRep(data: largeImage.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try largePNG.write(to: root.appendingPathComponent("fixture-large.png"))
        let pdf = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)).dataWithPDF(inside: NSRect(x: 0, y: 0, width: 100, height: 100))
        try pdf.write(to: root.appendingPathComponent("fixture.pdf"))
        let entries = try BrowserFileSystem.list(root: root)
        let imageHost = host(FilePreviewLayer(request: BrowserPreviewRequest(root: root, entry: entries.first { $0.name == "fixture.png" }!), close: {}, report: { _ in }),
                             width: 1200, height: 700)
        try wait("image preview installs transparent zoomable viewer") { !descendants(imageHost, ZoomableImagePreview.self).isEmpty }
        imageHost.layoutSubtreeIfNeeded()
        pump()
        let previewView = descendants(imageHost, ZoomableImagePreview.self)[0]
        let previewFrame = previewView.convert(previewView.bounds, to: imageHost)
        let imageView = previewView.documentView as? NSImageView
        try check(imageView?.image != nil, "image viewer receives private image snapshot")
        try check(!previewView.drawsBackground && !previewView.contentView.drawsBackground,
                  "image viewer leaves its backdrop transparent")
        let clipBounds = previewView.contentView.bounds
        try check(abs(clipBounds.midX - (imageView?.bounds.midX ?? 0)) < 1
                  && abs(clipBounds.midY - (imageView?.bounds.midY ?? 0)) < 1,
                  "small image stays centred in the transparent viewer")
        try check(previewFrame.width >= imageHost.bounds.width - 1 && previewFrame.height >= imageHost.bounds.height - 1,
                  "image preview fills the whole content area by default (1200pt-wide host, no 960pt card cap)")
        let fitted = previewView.magnification
        previewView.zoom(by: 2)
        try check(previewView.magnification > fitted, "wheel zoom path enlarges the image")
        try check(imageHost.bounds.width > 960, "image fill check exercises a content area wider than the old card cap")

        let anchorHost = host(FilePreviewLayer(request: BrowserPreviewRequest(root: root, entry: try BrowserFileSystem.list(root: root).first { $0.name == "fixture-large.png" }!), close: {}, report: { _ in }),
                              width: 800, height: 600)
        try wait("large image viewer installs") { !descendants(anchorHost, ZoomableImagePreview.self).isEmpty }
        anchorHost.layoutSubtreeIfNeeded(); pump()
        let anchorView = descendants(anchorHost, ZoomableImagePreview.self)[0]
        guard let anchorImage = anchorView.documentView else { throw NSError(domain: "MissingImageDocument", code: 1) }
        let anchor = NSPoint(x: 250, y: 200)
        let before = anchorImage.convert(anchor, to: anchorView)
        anchorView.zoom(by: 2, at: anchor)
        let after = anchorImage.convert(anchor, to: anchorView)
        try check(abs(before.x - after.x) < 1.5 && abs(before.y - after.y) < 1.5,
                  "wheel zoom keeps the pointer anchor fixed")
        let wheelBefore = anchorView.magnification
        if let wheel = NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                                wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!) {
            anchorView.scrollWheel(with: wheel)
        }
        try check(anchorView.magnification > wheelBefore, "a notched mouse wheel zooms the image")
        let pdfHost = host(FilePreviewLayer(request: BrowserPreviewRequest(root: root, entry: entries.first { $0.name == "fixture.pdf" }!), close: {}, report: { _ in }))
        try wait("PDF preview installs PDFKit document") { descendants(pdfHost, PDFView.self).first?.document?.pageCount == 1 }
        print("NOTE native component smoke checks do not establish GIF animation, WebP compatibility or human visual quality")
    }

    @MainActor static func eventChecks(_ root: URL) throws {
        let store = try DataStore(directory: root.appendingPathComponent("event-store"))
        try store.save(PresetCard(id: "event", title: "File browser fixture", command: "echo fixture", workingDirectory: root.path))
        let model = AppModel(store: store)
        let key = OwnerKey(kind: .preset, ownerId: "event")
        model.page = .detail(key)
        var frames: [String: CGRect] = [:]
        let rootView = host(RootView(model: model)
            .onPreferenceChange(ControlFrameKey.self) { frames = $0 }, width: 1100, height: 860)
        let window = rootView.window!
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pump(0.5)
        let browser = model.fileBrowser
        let card = browser.card(for: key, root: model.fileBrowserRoot(for: key))
        try check(!browser.isVisible && !browser.isPinned, "wide detail does not choose a different file presentation automatically")
        browser.toggle(requestFocus: true, source: .keyboard)
        try wait("explicit Files action loads the shared floating panel") { card.listings[""] != nil }
        pump(0.2)
        let floatingTerminal = frames["terminal-panel"]!
        func pressPin() throws {
            guard let frame = frames["file-browser-pin"] else { throw NSError(domain: "MissingPinButton", code: 1) }
            let point = rootView.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
            pump(0.3)
        }
        try pressPin()
        try check(browser.isPinned && browser.isVisible, "native header pin docks the currently open file panel")
        try check(abs(floatingTerminal.width - frames["terminal-panel"]!.width - browser.panelWidth - 10) < 2,
                  "pinning allocates space beside terminal instead of covering it")
        try check(abs(frames["file-browser-panel"]!.width - browser.panelWidth) < 1, "docked panel uses the shared preferred width")
        guard let dividerFrame = frames["file-browser-divider"] else {
            throw NSError(domain: "MissingFileDivider", code: 1, userInfo: [NSLocalizedDescriptionKey: "divider frame missing"])
        }
        try check(abs(dividerFrame.width - 10) < 1
                  && abs(dividerFrame.minX - frames["terminal-panel"]!.maxX) < 1
                  && abs(dividerFrame.maxX - frames["file-browser-panel"]!.minX) < 1,
                  "pinned panel exposes the 10pt resize divider between terminal and file panel")
        model.toggleFullscreen(key); pump(0.2)
        try check(browser.isPinned && browser.isVisible, "fullscreen keeps the explicit pin choice")
        model.enterSplitMode(); model.page = .detail(key); pump(0.3)
        try check(browser.isPinned && browser.isVisible, "split mode keeps the same pinned panel")
        let terminalTop = frames["terminal-panel"]!.minY
        model.createCopy(key)
        let copy = model.copyKeys.first!
        model.page = .detail(copy); pump(0.4)
        try check(frames["copy-detail-menu"].map { frames["terminal-panel"]!.contains($0) } == true,
                  "copy retain/remove actions are inside the terminal toolbar")
        try check(abs(frames["terminal-panel"]!.minY - terminalTop) < 1,
                  "copy detail has no separate action row consuming terminal space")
        model.page = .detail(key); pump(0.3)
        try pressPin()
        try check(!browser.isPinned && browser.isVisible && abs(frames["terminal-panel"]!.width - floatingTerminal.width) < 2,
                  "native unpin returns the same panel to floating without reserving terminal width")
        try check(abs(frames["file-browser-panel"]!.width - browser.panelWidth) < 1, "floating panel has the same preferred width")
        model.exitSplitMode(); model.page = .detail(key); pump(0.2)
        let entry = card.listings[""]!.first { $0.name == "fixture.png" }!
        // Exercise the exact shared Escape dispatcher used by AppKit's local monitor.
        func escape() { _ = model.consumeAppEscape(); pump(0.15) }
        if !model.isFullscreen(key) { model.toggleFullscreen(key) }
        browser.showPreview(entry, root: card.state.root)
        pump(0.3)
        try check(browser.preview != nil && browser.isVisible && model.isFullscreen(key), "preview starts above fullscreen floating panel")
        escape()
        try check(browser.preview == nil && browser.isVisible && model.isFullscreen(key), "Escape closes only preview first")
        escape()
        try check(!browser.isVisible && model.isFullscreen(key), "Escape next closes only floating panel")
        escape()
        try check(!model.isFullscreen(key), "Escape then preserves fullscreen exit semantics")
        model.beginRename(key)
        escape()
        try check(model.renamingKey == nil, "Escape still cancels title editing")
        model.enterSplitMode()
        model.page = .detail(key)
        pump(0.3)
        try check(model.isFullscreen(key) && !browser.isVisible, "mode change preserves the explicit closed choice")
        model.openHistory(for: key)
        pump(0.2)
        try check(browser.preview == nil && !browser.isVisible, "history navigation does not reopen a closed panel")
        if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, width, pinned, dark) in [("standard-floating", 1100.0, false, false), ("standard-pinned", 1100.0, true, false), ("narrow-pinned", 950.0, true, false), ("split-floating-dark", 1100.0, false, true), ("split-pinned-dark", 1100.0, true, true)] {
                if dark { model.enterSplitMode() } else { model.exitSplitMode() }
                model.page = .detail(key)
                window.setContentSize(NSSize(width: width, height: 860))
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                if browser.isPinned != pinned { browser.togglePinned() }
                if !browser.isVisible { browser.toggle(source: .keyboard) }
                pump(0.4)
                try check(browser.isVisible && browser.isPinned == pinned, "rendered presentation follows only the global pin choice")
                rootView.layoutSubtreeIfNeeded()
                guard let bitmap = rootView.bitmapImageRepForCachingDisplay(in: rootView.bounds) else { continue }
                rootView.cacheDisplay(in: rootView.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
                print("SCREENSHOT \(directory.appendingPathComponent(name + ".png").path)")
            }
        }
        window.close()
    }

    final class LoopbackProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var hits = 0
        let listener: NWListener
        var port: UInt16? { listener.port?.rawValue }
        var count: Int { lock.lock(); defer { lock.unlock() }; return hits }
        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.lock(); self.hits += 1; self.lock.unlock()
                connection.start(queue: .global())
                connection.cancel()
            }
            listener.start(queue: DispatchQueue(label: "file-browser-loopback-probe"))
        }
        deinit { listener.cancel() }
    }

    @MainActor static func htmlChecks(_ root: URL) throws {
        let folder = root.appendingPathComponent("html", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let probe = try LoopbackProbe()
        try wait("temporary network probe is ready") { probe.port != nil }
        defer { probe.listener.cancel() }
        let remote = "http://127.0.0.1:\(probe.port!)/forbidden"
        try Data("body { background-color: rgb(1, 2, 3); }".utf8).write(to: folder.appendingPathComponent("style.css"))
        try FileManager.default.copyItem(at: root.appendingPathComponent("fixture.png"), to: folder.appendingPathComponent("local.png"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.png"), withDestinationURL: root.appendingPathComponent("fixture.png"))
        let source = """
        <!doctype html><html><head><title>STATIC</title><link rel="stylesheet" href="style.css">
        <link rel="stylesheet" href="\(remote).css"><script>document.title='EXECUTED';fetch('\(remote)')</script></head>
        <body onload="document.title='EVENT-RAN'">Static page
        <img id="local" src="local.png"><img id="remote" src="\(remote).png">
        <img id="file" src="\(root.appendingPathComponent("fixture.png").absoluteString)">
        <img id="parent" src="../fixture.png"><img id="link" src="link.png">
        <iframe src="\(remote).html"></iframe><object data="\(remote).pdf"></object>
        <a id="nav" href="\(remote)">external link</a><a id="download" download href="local.png">download</a>
        <form action="\(remote)" method="post"><input name="secret" value="DO-NOT-SEND"></form>
        </body></html>
        """
        try Data(source.utf8).write(to: folder.appendingPathComponent("index.html"))
        var failure: String?
        let htmlHost = host(StaticHTMLPreview(root: root, relative: "html/index.html", failure: { failure = $0 }))
        try wait("WebKit static HTML view installed") { !descendants(htmlHost, WKWebView.self).isEmpty }
        let web = descendants(htmlHost, WKWebView.self)[0]
        try wait("static HTML loads with security rules", timeout: 25) { web.title == "STATIC" || failure != nil }
        try check(failure == nil, "HTML loads without a main-frame failure: \(failure ?? "none")")
        pump(1)
        try check(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript, "WebKit disables page JavaScript")
        try check(try evaluate("document.title", on: web) == "STATIC", "inline scripts and event handlers never ran")
        try check(try evaluate("getComputedStyle(document.body).backgroundColor", on: web) == "rgb(1, 2, 3)", "same-directory CSS is available")
        let expectedWidth = NSBitmapImageRep(data: try Data(contentsOf: folder.appendingPathComponent("local.png")))!.pixelsWide
        let actualWidth = try evaluate("String(document.getElementById('local').naturalWidth)", on: web)
        print("INFO HTML local image: expected \(expectedWidth) pixels, decoded \(actualWidth)")
        try check(actualWidth == String(expectedWidth), "same-directory image is available at its physical pixel width")
        for id in ["remote", "file", "parent", "link"] {
            try check(try evaluate("String(document.getElementById('\(id)').naturalWidth)", on: web) == "0", "HTML blocks \(id) resource")
        }
        _ = try evaluate("document.getElementById('nav').click();document.forms[0].submit();document.getElementById('download').click();'attempted'", on: web)
        pump(0.5)
        try check(web.url?.scheme == BrowserHTMLPolicy.scheme && web.title == "STATIC", "navigation, forms and downloads are blocked")
        try check(probe.count == 0, "no HTML network request reached loopback (images/CSS/script/frame/object/forms/navigation)")
        web.stopLoading()
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        defer { for window in windows { window.close() }; windows = [] }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runbo-files-verify-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            try modelChecks(root)
            try nativeChecks(root)
            try htmlChecks(root)
            try eventChecks(root)
            print("All isolated file-browser integration checks passed")
        } catch {
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

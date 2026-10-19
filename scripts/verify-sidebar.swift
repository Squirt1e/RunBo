import AppKit
import SwiftUI
import TerminalDeckKit
@testable import TerminalDeck

@main struct VerifySidebar {
    @MainActor static var count = 0
    @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NSError(domain: "SidebarCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        count += 1; print("PASS \(label)")
    }
    @MainActor static func pump(_ seconds: Double = 0.15) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.003), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.003))
        }
    }
    @MainActor static func wait(_ label: String, _ condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(12)
        while !condition() && Date() < end { pump(0.03) }
        try check(condition(), label)
    }
    @MainActor static func fixture(_ root: URL) throws -> AppModel {
        let store = try TerminalDeckStore(directory: root)
        let tag = CardTag(id: "pi", name: "Pi")
        try store.save(tag)
        for (id, title) in [("a", "Terminal Dashboard"), ("b", "Agents Usage"), ("c", "Learning Agent")] {
            try store.save(PresetCard(id: id, title: title, command: "printf SIDEBAR_READY; sleep 60", workingDirectory: root.path, tagId: tag.id))
        }
        let model = AppModel(store: store)
        model.engine.baseEnvironment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        return model
    }
    @MainActor static func modelChecks(_ root: URL) throws {
        let model = try fixture(root)
        let sidebar = model.sidebar
        try check(sidebar.mode == .pinned && !sidebar.peeking, "existing data defaults to pinned without a new settings write")
        try check(try model.store.string(forKey: WorkbenchSidebarMode.key) == nil, "startup does not invent a persisted preference")
        let ratio = model.workhorseSidebarRatio
        try check(sidebar.setMode(.collapsed), "explicit collapse succeeds")
        try check(try model.store.string(forKey: WorkbenchSidebarMode.key) == "collapsed", "only the layout preference is persisted")
        let reopened = AppModel(store: try TerminalDeckStore(directory: root))
        try check(reopened.sidebar.mode == .collapsed && !reopened.sidebar.peeking, "reopening restores the rail, never a transient peek")
        model.enterWorkhorseMode(); model.exitWorkhorseMode()
        try check(sidebar.mode == .collapsed && model.workhorseSidebarRatio == ratio, "work mode changes preserve fold preference and expanded ratio")
        sidebar.pointerChanged(true); pump(0.06); sidebar.pointerChanged(false); pump(0.3)
        try check(!sidebar.peeking, "a brief pointer crossing never reveals the panel")
        sidebar.pointerChanged(true); pump(0.23)
        try check(sidebar.peeking && sidebar.inputSource == .pointer, "pointer dwell opens a transient peek")
        sidebar.pointerChanged(false); pump(0.1); sidebar.pointerChanged(true); pump(0.25)
        try check(sidebar.peeking, "reentering the panel cancels the pending close")
        try check(sidebar.setMode(.pinned), "pinning a peek changes the explicit preference")
        sidebar.pointerChanged(false); pump(0.35)
        try check(sidebar.expanded && !sidebar.peeking, "pinned mode is not closed by pointer exit")
        _ = sidebar.setMode(.collapsed)
        sidebar.focus(.owner(OwnerKey(kind: .preset, ownerId: "a")))
        try check(sidebar.peeking && sidebar.inputSource == .keyboard, "keyboard reveal is immediate and carries a focus transfer")
        try check(sidebar.consumeEscape() && !sidebar.peeking, "sidebar Escape closes only its own keyboard peek")
        sidebar.pointerChanged(true); pump(0.23)
        model.beginRename(OwnerKey(kind: .preset, ownerId: "a"), source: .workhorseList)
        sidebar.pointerChanged(false); pump(0.35)
        try check(sidebar.peeking && model.renamingKey != nil, "automatic close never interrupts rename")
        try check(sidebar.setMode(.pinned) && sidebar.mode == .pinned, "pinning is safe while rename is active")
        try check(!sidebar.setMode(.collapsed) && model.renamingKey != nil, "explicit collapse does not silently commit a protected rename")
        model.cancelRename(); sidebar.interactionChanged(); _ = sidebar.setMode(.collapsed)
        sidebar.pointerChanged(true); pump(0.23); sidebar.setDragging(true); sidebar.pointerChanged(false); pump(0.35)
        try check(sidebar.peeking, "a drag keeps the full list and its drop targets in place")
        sidebar.setDragging(false); pump(0.35)
        try check(!sidebar.peeking, "drag completion reevaluates automatic closing")
        sidebar.pointerChanged(true); pump(0.23); sidebar.menuTracking(true); sidebar.pointerChanged(false); pump(0.35)
        try check(sidebar.peeking, "native menu tracking holds its anchor open")
        sidebar.menuTracking(false); pump(0.35)
        try check(!sidebar.peeking, "menu dismissal rechecks the grace interval")
        try model.store.database.execute("CREATE TRIGGER reject_sidebar BEFORE UPDATE ON settings WHEN NEW.key = 'workbench_sidebar_mode' BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        try check(!sidebar.setMode(.pinned) && sidebar.mode == .collapsed, "failed preference write leaves the displayed mode unchanged")
        try check(model.feedback?.kind == .error, "preference write failure is surfaced as a persistent error")
        try model.store.database.execute("DROP TRIGGER reject_sidebar;")
        try check(sidebar.setMode(.pinned), "failed preference changes remain retryable")
    }

    @MainActor static func nativeChecks(_ root: URL) throws {
        let model = try fixture(root)
        defer { model.engine.endAllSessions(timeout: 1) }
        let key = OwnerKey(kind: .preset, ownerId: "a")
        model.page = .detail(key)
        var frames: [String: CGRect] = [:]
        let host = NSHostingView(rootView: DeckRootView(model: model).onPreferenceChange(WorkbenchControlFrameKey.self) { frames = $0 })
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 860), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.title = "RunBo — isolated sidebar checks"
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        func mouse(_ point: CGPoint, type: NSEvent.EventType = .mouseMoved) {
            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
        }
        func press(_ name: String) throws {
            guard let frame = frames[name] else { throw NSError(domain: "MissingFrame", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name): mode=\(model.sidebar.mode) peek=\(model.sidebar.peeking) pointer=\(model.sidebar.pointerInside) keyboard=\(model.sidebar.keyboardInside)"]) }
            let point = CGPoint(x: frame.midX, y: frame.midY)
            mouse(point, type: .leftMouseDown); pump(0.025); mouse(point, type: .leftMouseUp); pump(0.3)
        }
        func keyEvent(_ code: UInt16, _ text: String, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!, atStart: false)
            }
            pump(0.15)
        }
        func snapshot(_ name: String) throws {
            guard let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 else { return }
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            print("SCREENSHOT \(name)")
        }
        pump(0.5)
        try check(window.isKeyWindow && NSApp.isActive, "native test window owns desktop input")
        model.startCard(model.card(for: "a")!)
        try wait("fixture has a real ready PTY") { model.liveRuntime(key)?.isReachable == true }
        let session = model.liveRuntime(key)!.sessionId
        let scene = model.liveScene(sessionId: session)
        var resizes = 0
        let originalResize = scene.onResize
        scene.onResize = { cols, rows in resizes += 1; originalResize?(cols, rows) }
        for workhorse in [false, true] {
            if workhorse { model.enterWorkhorseMode() } else { model.exitWorkhorseMode() }
            let name = workhorse ? "workhorse" : "standard"
            model.page = .detail(key); model.dismissNotice(); pump(0.4)
            _ = model.sidebar.setMode(.pinned); pump(0.3)
            try press("sidebar-toggle")
            try check(model.sidebar.mode == .collapsed, "\(name): native toggle enters the rail")
            mouse(CGPoint(x: 1000, y: 600)); pump(0.4)
            window.makeFirstResponder(scene.view); pump(0.15)
            let content = frames["workbench-content"]!, terminal = scene.view.convert(scene.view.bounds, to: host)
            let parent = scene.container.superview
            resizes = 0
            mouse(CGPoint(x: 25, y: 200)); pump(0.45)
            try check(model.sidebar.peeking && model.sidebar.mode == .collapsed, "\(name): native mouse movement reveals the overlay")
            try check(frames["workbench-content"] == content && scene.view.convert(scene.view.bounds, to: host) == terminal,
                      "\(name): hover leaves exact content and real terminal geometry unchanged")
            try check(resizes == 0 && scene.container.superview === parent, "\(name): hover neither remounts TerminalView nor sends PTY resize")
            try check(window.firstResponder === scene.view, "\(name): hover does not steal terminal focus")
            try snapshot(name + "-peek-light")
            _ = model.consumeDeckEscape(terminalHasFocus: true)
            try check(model.sidebar.peeking, "\(name): terminal Escape does not close the hovered sidebar")
            mouse(CGPoint(x: 1000, y: 600)); pump(0.45)
            try check(!model.sidebar.peeking && frames["workbench-content"] == content && resizes == 0, "\(name): leaving the overlay closes without resizing")
            try snapshot(name + "-rail-light")
            mouse(CGPoint(x: 25, y: 200)); pump(0.45)
            try press("sidebar-pin")
            mouse(CGPoint(x: 1000, y: 600)); pump(0.4)
            try check(model.sidebar.mode == .pinned && frames["workbench-content"]!.minX > content.minX,
                      "\(name): native pin explicitly reallocates content width")
            try check(model.liveRuntime(key)?.sessionId == session, "\(name): collapse/hover/pin preserve the exact live session")
            try snapshot(name + "-pinned-light")
            window.makeFirstResponder(scene.view)
            keyEvent(1, "s", modifiers: [.command, .option]); pump(0.3)
            try check(model.sidebar.mode == .collapsed, "\(name): native Command Option S collapses from terminal focus")
            try check(window.firstResponder === scene.view, "\(name): folding shortcut preserves terminal input focus")
            window.makeFirstResponder(nil)
            for _ in 0..<12 {
                if model.sidebar.peeking && model.sidebar.keyboardInside { break }
                keyEvent(48, "\t")
            }
            try check(model.sidebar.peeking && model.sidebar.keyboardInside, "\(name): Tab opens accessible full labels instead of hidden focus stops")
            if !workhorse { keyEvent(53, "\u{1b}"); pump(0.2) }
            else {
                model.beginRename(key, source: .workhorseList); pump(0.2)
                mouse(CGPoint(x: 1000, y: 600)); pump(0.4)
                try check(model.sidebar.peeking && model.renamingKey == key, "native rename field is not unmounted by pointer exit")
                model.cancelRename(); model.sidebar.keyboardFocusChanged(false); pump(0.4)
            }
            model.sidebar.windowInactive(); pump(0.2)
        }
        model.sidebar.windowInactive(); pump(0.3)
        try press("rail-owner-b")
        try check(model.page == .detail(OwnerKey(kind: .preset, ownerId: "b")) && model.liveRuntime(OwnerKey(kind: .preset, ownerId: "b")) == nil,
                  "native rail click opens another project without starting its command")
        mouse(CGPoint(x: 1000, y: 600)); pump(0.4)
        try check(!model.sidebar.peeking, "mouse project selection does not leave a stale keyboard focus hold")
        model.page = .detail(key); pump(0.2)
        model.fileBrowser.togglePinned(); model.fileBrowser.toggle(source: .keyboard)
        let fileWidth = model.fileBrowser.panelWidth, ratio = model.workhorseSidebarRatio
        _ = model.sidebar.setMode(.pinned); _ = model.sidebar.setMode(.collapsed)
        try check(model.fileBrowser.isPinned && model.fileBrowser.panelWidth == fileWidth && model.workhorseSidebarRatio == ratio,
                  "file pin, file width and expanded sidebar ratio remain independent")
        model.beginEditCard(model.card(for: "b")!); model.editorTitle = "Unsaved sidebar draft"
        model.sidebar.focus(.owner(key)); model.workhorseSelect(key)
        try check(model.page == .editor && model.alert != nil && model.editorTitle == "Unsaved sidebar draft", "rail navigation retains existing dirty-draft protection")
        model.alert = nil; model.cancelEditor(); model.sidebar.windowInactive()
        for width in [950.0, 1100.0, 1800.0] {
            window.setContentSize(NSSize(width: width, height: 860)); pump(0.3)
            try check(abs(frames["workbench-content"]!.minX - 56) < 1 && frames["workbench-content"]!.maxX <= width + 1,
                      "\(Int(width))pt window retains exactly 56pt rail allocation")
        }
        window.appearance = NSAppearance(named: .darkAqua)
        model.sidebar.pointerChanged(true); pump(0.5)
        try snapshot("workhorse-peek-dark")
    }

    @MainActor static func main() {
        let modelOnly = CommandLine.arguments.contains("--model-only")
        _ = NSApplication.shared; NSApp.setActivationPolicy(modelOnly ? .prohibited : .accessory); NSApp.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-checks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try modelChecks(root.appendingPathComponent("model"))
            if !modelOnly { try nativeChecks(root.appendingPathComponent("native")) }
            else { print("MODEL-ONLY: skipped foreground input checks; no windows shown or events posted") }
            print("\(count) SIDEBAR CHECKS PASSED")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}

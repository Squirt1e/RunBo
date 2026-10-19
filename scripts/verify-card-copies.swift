import AppKit
import SwiftUI
import Core
@testable import App

/// App-model and native-layout smoke checks. Uses only temporary stores and a scratch HOME.
@main
struct VerifyCardCopies {
    @MainActor static func pump(_ seconds: Double = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw NSError(domain: "CardCopyVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        print("PASS \(label)")
    }
    @MainActor static func wait(_ label: String, timeout: Double = 12, _ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { pump(0.03) }
        try check(predicate(), label)
    }
    @MainActor static func scratch(_ name: String) throws -> (DataStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("card-copy-\(name)-\(UUID())")
        return (try DataStore(directory: root), root)
    }
    @MainActor static func isolate(_ model: AppModel, root: URL) {
        model.engine.baseEnvironment = ["HOME": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color"]
    }

    @MainActor static func modelChecks() throws {
        let (store, root) = try scratch("model")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(PresetCard(id: "source", title: "Source", command: "echo READY; sleep 30"))
        try store.save(TempTerminal(id: "terminal", title: "终端 1"))
        let source = OwnerKey(kind: .preset, ownerId: "source")
        let terminal = OwnerKey(kind: .temp, ownerId: "terminal")
        let model = AppModel(store: store)
        isolate(model, root: root)
        defer { model.engine.endAllSessions(timeout: 1) }
        try check(model.canCreateCopy(source) && !model.canCreateCopy(terminal), "only preset cards support copy creation")
        model.createCopy(terminal)
        try check(model.copyKeys.isEmpty && model.temps.count == 1 && (try store.temps()).count == 1,
                  "terminal copy requests are rejected without changing stored cards")
        model.createCopy(source)
        let kept = model.copyKeys.first!
        try check(model.copyKeys.count == 1 && model.engine.allRuntimes.isEmpty, "creation never starts a terminal")
        try check(model.page == .presets, "creation does not navigate into detail")
        model.startCard(model.card(for: kept.ownerId)!)
        model.startCard(model.card(for: source.ownerId)!)
        try wait("original and copy have separate ready PTYs") {
            model.engine.runtime(for: source)?.isReachable == true && model.engine.runtime(for: kept)?.isReachable == true
        }
        let originalID = model.liveRuntime(source)!.sessionId
        let keptID = model.liveRuntime(kept)!.sessionId
        model.retainCopy(kept)
        try check(model.copyIdentity(kept) == nil && (try store.cards()).first { $0.id == kept.ownerId }?.copy == nil
                  && model.liveRuntime(kept)?.sessionId == keptID, "retain clears copy identity without changing card ID or PTY")
        try check(model.copyKeys.isEmpty, "retained copy leaves global count immediately")
        try check(model.copyReflowing, "retain protects neighbours during footer reflow")
        pump(0.4)
        try check(!model.copyReflowing, "reflow hit protection releases automatically")
        model.createCopy(source)
        let disposable = model.copyKeys.first!
        model.createCopy(source)
        let secondDisposable = model.copyKeys.subtracting([disposable]).first!
        model.startCard(model.card(for: disposable.ownerId)!)
        model.startCard(model.card(for: secondDisposable.ownerId)!)
        model.restart(terminal)
        try wait("both preset copies and ordinary terminal are live") {
            model.isRunning(disposable) && model.isRunning(secondDisposable) && model.isRunning(terminal)
        }
        let terminalID = model.liveRuntime(terminal)!.sessionId
        let doomedSession = model.liveRuntime(disposable)!.sessionId
        try check(model.copyOnlineCount == 2, "global warning counts copy PTYs but excludes ordinary terminals")
        model.enterSplitMode()
        model.toggleSidebarMenu(.preset)
        model.toggleSidebarMenu(.temp)
        model.page = .settings
        try check(model.copyKeys.count == 2, "hidden groups/settings do not change global scope")
        model.beginEditCard(model.card(for: disposable.ownerId)!)
        model.editorCommand = "unsaved draft"
        model.removeAllCopies()
        try check(model.alert != nil && model.removingCopies.isEmpty, "global cleanup protects unsaved draft before starting")
        model.alert = nil
        try check(model.copyKeys.count == 2, "cancelling draft protection preserves every copy")
        model.removeAllCopies()
        let action = model.alert!.action
        model.alert = nil
        action()
        try check(model.alert?.title == "解除在线分身？" && model.removingCopies.isEmpty
                  && model.liveRuntime(disposable)?.sessionId == doomedSession,
                  "discarding a draft does not silently authorize terminating live copies")
        let liveConfirmation = model.alert!.action
        model.alert = nil
        liveConfirmation()
        model.removeAllCopies() // A duplicate click must be ignored.
        try wait("global one-click removes both copies", timeout: 15) { model.removingCopies.isEmpty && model.copyKeys.isEmpty }
        try check(model.liveRuntime(terminal)?.sessionId == terminalID, "global cleanup leaves ordinary terminal unchanged")
        try check(model.liveRuntime(source)?.sessionId == originalID, "global cleanup leaves original PTY unchanged")
        try check(model.liveRuntime(kept)?.sessionId == keptID, "global cleanup leaves retained PTY unchanged")
        try check(model.page == .presets && model.splitSelection == nil, "removing selected copy returns split-mode home")
        try check(try store.events(sessionId: doomedSession).isEmpty, "removed output is not resurrected")
        model.removeCopy(kept)
        try check(model.card(for: kept.ownerId) != nil, "ordinary retained card cannot be dismissed as a copy")

        // Feed a late queued delegate callback deliberately; it must not restore UI state.
        model.engine(model.engine, didFinish: SessionRecord(id: doomedSession, kind: .preset, ownerId: disposable.ownerId,
                                                            title: "Late", shell: "/bin/zsh", endedAt: Date()))
        pump()
        try check(model.storedLastSession[disposable] == nil, "late delegate callback cannot restore deleted owner")

        model.createCopy(source)
        let failed = model.copyKeys.first!
        try store.database.execute("""
        CREATE TRIGGER reject_copy_delete BEFORE DELETE ON preset_cards WHEN OLD.clone_run_id IS NOT NULL
        BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
        """)
        model.removeAllCopies()
        try wait("failed cleanup is retryable") { model.removingCopies.isEmpty }
        try check(model.copyKeys.contains(failed) && model.notice?.contains("未解除") == true, "failed deletion stays visible and reports partial failure")
        try check(model.feedback?.kind == .error && model.feedback?.retry != nil, "partial cleanup failure stays visible with an explicit retry")
        try store.database.execute("DROP TRIGGER reject_copy_delete;")
        model.retryNotice(id: model.feedback!.id)
        try wait("retry removes failed copy") { model.copyKeys.isEmpty && model.removingCopies.isEmpty }

        model.createCopy(source)
        let stale = model.copyKeys.first!
        model.engine.endAllSessions(timeout: 1)
        let reopened = AppModel(store: try DataStore(directory: root))
        try check(reopened.card(for: stale.ownerId) == nil && reopened.card(for: kept.ownerId) != nil,
                  "new App run drops disposable identity but keeps retained card")
        try check(reopened.engine.allRuntimes.isEmpty, "relaunch never resumes previous PTYs")
    }

    @MainActor static func startupFailureCheck() throws {
        let (store, root) = try scratch("startup-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(PresetCard(id: "auto", title: "Auto", command: "echo SHOULD_NOT_START", autoRun: true))
        _ = try store.createCopy(of: OwnerKey(kind: .preset, ownerId: "auto"), runID: "stale", defaultShell: "zsh")
        try store.database.execute("""
        CREATE TRIGGER reject_startup_purge BEFORE DELETE ON preset_cards
        BEGIN SELECT RAISE(ABORT, 'injected startup cleanup failure'); END;
        """)
        let model = AppModel(store: store)
        try check(model.engine.allRuntimes.isEmpty && model.cards.isEmpty && model.notice?.contains("无法清理") == true,
                  "startup cleanup failure fails closed before any auto-run")
    }

    /// Drain AppKit's event queue too: a run-loop-only pump does not deliver posted mouse events.
    @MainActor static func pumpEvents(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            pump(0.01)
        }
    }

    @MainActor static func menuButtons(in element: Any) -> [NSAccessibilityProtocol] {
        guard let ax = element as? NSAccessibilityProtocol else { return [] }
        if ax.accessibilityRole() == .menuButton { return [ax] }
        let children = ax.accessibilityChildren() ?? []
        return (children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children)
            .flatMap { menuButtons(in: $0) }
    }

    @MainActor final class GestureProbe {
        var lifted = false
        var menu: NSMenu?
        var menuOpened = false
        var liftedWhileMenuOpen = false
    }

    /// Native mouse events, no Accessibility permission or global pointer movement required.
    @MainActor static func splitGestureChecks() throws {
        NSApp.finishLaunching()
        let (store, root) = try scratch("split-gestures")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(PresetCard(id: "source", title: "Source", command: "echo READY"))
        let model = AppModel(store: store)
        isolate(model, root: root)
        let source = OwnerKey(kind: .preset, ownerId: "source")
        model.createCopy(source)
        let copy = model.copyKeys.first!
        model.enterSplitMode()
        // Keep earlier windows alive: closing an accessory app's last window can asynchronously
        // deactivate it after the next fixture has already requested activation.
        var windows: [NSWindow] = []
        defer { for window in windows { window.orderOut(nil); window.contentView = nil } }
        for width in [240.0, 296.0, 460.0] {
            for key in [source, copy] {
                // A fresh row isolates gesture routing from the panel's drag-preview animation.
                let probe = GestureProbe()
                let view = SplitRow(model: model, kind: .preset, id: key.ownerId,
                                        title: model.card(for: key.ownerId)!.title, detail: "echo READY",
                                        selectedKey: nil, hoveredID: key.ownerId,
                                        onLongPress: { probe.lifted = true })
                    .frame(width: width - 20, height: SplitLayout.listRowHeight)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width - 20,
                                                          height: SplitLayout.listRowHeight),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                windows.append(window)
                let monitor = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                      object: nil, queue: .main) { notification in
                    MainActor.assumeIsolated {
                        probe.menu = notification.object as? NSMenu
                        probe.menuOpened = probe.menu != nil
                    }
                }
                defer { NotificationCenter.default.removeObserver(monitor) }
                func mouse(_ type: NSEvent.EventType, at point: CGPoint) {
                    let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
                                                  modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                  clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                    NSApp.postEvent(event, atStart: false)
                }
                pumpEvents(0.5)
                guard NSApp.isActive, window.isKeyWindow else {
                    print("SKIP \(Int(width))pt \(key == copy ? "copy" : "ordinary"): desktop focus was not granted")
                    continue
                }
                let title = window.convertPoint(toScreen: host.convert(CGPoint(x: 50, y: host.bounds.midY), to: nil))
                mouse(.leftMouseDown, at: title)
                pumpEvents(0.6)
                let retainedFocus = NSApp.isActive && window.isKeyWindow
                mouse(.leftMouseUp, at: title)
                pumpEvents(0.3)
                guard retainedFocus else {
                    print("SKIP \(Int(width))pt \(key == copy ? "copy" : "ordinary"): desktop focus changed during long press")
                    continue
                }
                try check(probe.lifted, "\(Int(width))pt \(key == copy ? "copy" : "ordinary") title still recognizes long press")

                guard let menuFrame = menuButtons(in: host).first?.accessibilityFrame() else {
                    try check(key == copy, "only copy rows may omit an ellipsis menu")
                    print("SKIP \(Int(width))pt copy ellipsis: this UI does not offer a copy menu")
                    continue
                }
                probe.lifted = false
                let point = CGPoint(x: menuFrame.midX, y: menuFrame.midY)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    probe.liftedWhileMenuOpen = probe.lifted
                    probe.menu?.cancelTracking()
                    probe.menu = nil
                    mouse(.leftMouseUp, at: point)
                }
                mouse(.leftMouseDown, at: point)
                pumpEvents(1)
                try check(probe.menuOpened && !probe.liftedWhileMenuOpen && !probe.lifted,
                          "\(Int(width))pt \(key == copy ? "copy" : "ordinary") ellipsis opens menu without lifting, even past long-press delay")
            }
        }
        try check(model.engine.allRuntimes.isEmpty && model.copyKeys == [copy], "gesture checks do not activate row actions")
    }

    @MainActor static func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat, dark: Bool) throws {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: width, height: height).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "RunBo · 分身验证（临时数据）"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        pump(0.7)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "Render", code: 1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "Render", code: 2) }
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/verify-card-copies/\(name).png")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: path)
        window.orderOut(nil)
        window.contentView = nil
        print("RENDER \(path.path)")
    }

    @MainActor static func renderChecks() throws {
        let (store, root) = try scratch("render")
        defer { try? FileManager.default.removeItem(at: root) }
        try store.save(CardTag(id: "work", name: "工作"))
        for (id, title) in [("build", "Build Release"), ("web", "Web Dev"), ("docs", "Docs Preview")] {
            try store.save(PresetCard(id: id, title: title, command: "echo \(id); sleep 30", tagId: "work"))
        }
        try store.save(TempTerminal(id: "t", title: "终端 1"))
        let model = AppModel(store: store)
        isolate(model, root: root)
        defer { model.engine.endAllSessions(timeout: 1) }
        let build = OwnerKey(kind: .preset, ownerId: "build")
        let web = OwnerKey(kind: .preset, ownerId: "web")
        model.createCopy(build)
        model.createCopy(web)
        let terminal = OwnerKey(kind: .temp, ownerId: "t")
        model.restart(terminal)
        let webCopy = model.copyKeys.first { model.copyIdentity($0)?.sourceID == "web" }!
        model.startCard(model.card(for: "build")!)
        model.startCard(model.card(for: webCopy.ownerId)!)
        try wait("render fixture PTYs ready") { model.liveRuntime(webCopy)?.isReachable == true && model.liveRuntime(terminal)?.isReachable == true }
        try render(RootView(model: model), name: "card-copy-implementation-light", width: 1100, height: 860, dark: false)
        try render(RootView(model: model), name: "card-copy-implementation-dark", width: 1100, height: 860, dark: true)
        model.setDisplayMode(.square, for: .preset)
        try render(RootView(model: model), name: "card-copy-implementation-square", width: 950, height: 700, dark: false)
        model.enterSplitMode()
        model.setSidebarRatio(240.0/1100.0, persist: false)
        model.page = .detail(webCopy)
        try render(RootView(model: model), name: "card-copy-implementation-split-narrow", width: 1100, height: 700, dark: false)
        try render(RootView(model: model), name: "card-copy-implementation-split-night", width: 1100, height: 700, dark: true)
        try check(model.copyKeys.count == 2 && model.copyKeys.allSatisfy { $0.kind == .preset },
                  "layout changes preserve preset copies without creating terminal copies")
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--interactions") {
            try splitGestureChecks()
            print("ALL SPLIT GESTURE CHECKS PASSED")
            return
        }
        try modelChecks()
        try startupFailureCheck()
        if CommandLine.arguments.contains("--render") { try renderChecks() }
        print("ALL CARD COPY APP CHECKS PASSED")
    }
}

import AppKit
import SwiftUI
import TerminalDeckKit
@testable import TerminalDeck

@main struct VerifyWorkhorseInteractions {
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else {
            throw NSError(domain: "WorkhorseInteractions", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: label])
        }
        print("PASS \(label)")
    }
    @MainActor static func pump(_ seconds: Double = 0.15) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.003), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.003))
        }
    }
    @MainActor static func fixture(_ root: URL) throws -> AppModel {
        let store = try TerminalDeckStore(directory: root)
        try store.save(PresetCard(id: "a", title: "构建生产版本 · 长标题检查", command: "printf READY", workingDirectory: root.path))
        try store.save(PresetCard(id: "b", title: "监控任务 · 很长很长的项目名称", command: "sleep 30", workingDirectory: root.path))
        try store.save(PresetCard(id: "c", title: "其他任务", command: "true", workingDirectory: root.path))
        let model = AppModel(store: store)
        model.engine.baseEnvironment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        model.enterWorkhorseMode()
        return model
    }
    @MainActor static func confirm(_ model: AppModel, save: Bool = false) throws {
        guard let alert = model.alert else { throw NSError(domain: "MissingAlert", code: 1) }
        model.alert = nil
        if save { alert.saveAction?() } else { alert.action() }
    }
    @MainActor static func modelChecks(_ root: URL) throws {
        let model = try fixture(root)
        defer { model.engine.endAllSessions(timeout: 1) }
        let a = OwnerKey(kind: .preset, ownerId: "a"), b = OwnerKey(kind: .preset, ownerId: "b")
        let card = model.card(for: "a")!
        model.workhorseSelect(a)
        model.beginEditCard(card)
        model.editorTitle = "未保存的修改"
        model.requestCancelEditor()
        try check(model.page == .editor && model.alert?.saveAction != nil, "Back protects dirty draft and offers save-and-continue")
        model.alert = nil
        try check(model.editorTitle == "未保存的修改", "cancelling exit preserves draft")
        model.beginEditCard(card)
        try check(model.alert == nil && model.editorTitle == "未保存的修改", "editing the same card does not reset its draft")
        model.beginEditCard(model.card(for: "b")!)
        try check(model.editorEditingCardId == "a" && model.alert != nil, "editing another row cannot replace a dirty draft")
        try confirm(model, save: true)
        try check(model.card(for: "a")?.title == "未保存的修改" && model.editorEditingCardId == "b" && model.alert == nil,
                  "save-and-continue persists source and enters destination without a second prompt")
        model.editorTitle = "B draft"
        model.beginNewCard()
        try check(model.editorEditingCardId == "b" && model.alert != nil, "new-card shortcut protects current draft")
        model.alert = nil
        model.createWorkhorseTempTerminal()
        try check(model.temps.isEmpty && model.alert != nil, "new-terminal shortcut does not start before draft decision")
        model.alert = nil
        model.navigate(to: .settings)
        try check(model.page == .editor && model.alert != nil, "settings navigation uses the same draft guard")
        model.alert = nil
        model.requestDeleteCard(model.card(for: "c")!)
        model.confirmDeletion()
        try check(model.page == .editor && model.editorEditingCardId == "b" && model.editorTitle == "B draft",
                  "deleting an unrelated row preserves editor identity and text")
        pump(0.8)
        try check(model.page == .editor && model.card(for: "c") == nil, "deletion reflow cannot dismiss unrelated editor")
        model.requestDeleteCard(model.card(for: "b")!)
        model.confirmDeletion()
        try check(model.alert != nil && model.pendingDeletion?.key == b && model.card(for: "b") != nil,
                  "deleting the edited card requires explicit draft discard before mutation")
        model.alert = nil; model.cancelDeletion()
        try check(model.editorTitle == "B draft", "cancelling edited-card removal preserves draft")
        model.requestCancelEditor(); try confirm(model)
        try check(model.page == .detail(b), "confirmed discard returns to source detail")
        model.beginNewCard()
        try check(!model.saveEditor() && model.editorTitleError != nil && model.editorCommandError != nil,
                  "required fields have persistent validation messages")
        model.editorTitle = "Valid name"
        try check(model.editorTitleError == nil && !model.saveEditor() && model.editorCommandError != nil,
                  "correcting a field clears only its own error")
        model.editorCommand = "true"
        try model.store.database.execute("CREATE TRIGGER fail_save BEFORE INSERT ON preset_cards BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        try check(!model.saveEditor() && model.editorError != nil && model.page == .editor && model.editorTitle == "Valid name",
                  "storage failure remains visible with retryable draft")
        try model.store.database.execute("DROP TRIGGER fail_save;")
        try check(model.saveEditor() && model.editorError == nil, "retry clears persistent storage error only after success")
        model.beginEditCard(model.card(for: "b")!)
        try model.store.database.execute("CREATE TRIGGER fail_delete BEFORE DELETE ON preset_cards BEGIN SELECT RAISE(ABORT, 'injected'); END;")
        model.requestDeleteCard(model.card(for: "b")!)
        model.confirmDeletion()
        try check(model.page == .editor && model.editorEditingCardId == "b" && model.card(for: "b") != nil,
                  "failed deletion does not clear editor identity or navigate")
        try model.store.database.execute("DROP TRIGGER fail_delete;")
        model.cancelEditor()
        let tag = model.createTag(named: "工作")!
        model.assignTag(tag.id, to: a)
        model.goHome()
        model.toggleWorkhorseMenu(.preset)
        model.toggleTagCollapsed(tag.id)
        model.openWorkhorseHome(.detail(a))
        try check(model.workhorseSelection == a && !model.isTagCollapsed(tag.id) && !model.workhorseCollapsedMenus.contains(.preset),
                  "home navigation reveals both folded menu and target tag")
        model.openHistory(for: a)
        try check(!model.isFullscreen(a), "history list cannot inherit detail expansion")
        let record = SessionRecord(id: "history", kind: .preset, ownerId: "a", title: "A", shell: "/bin/zsh",
                                   startedAt: Date().addingTimeInterval(-10), endedAt: Date(), termination: .normal)
        try model.store.save(record)
        model.loadHistoryEntries(for: a)
        model.showHistoryRecord(record.id, for: a)
        model.toggleFullscreen(a)
        try check(model.isFullscreen(a), "valid history replay can be expanded explicitly")
        model.backFromHistory(for: a, sessionId: record.id)
        try check(model.page == .history(a, nil) && !model.isFullscreen(a), "return from expanded replay restores navigable history list")
        model.backFromHistory(for: a, sessionId: nil)
        try check(model.page == .detail(a) && model.isFullscreen(a), "history Back returns to workhorse detail")
        model.requestDeleteCard(model.card(for: "a")!)
        model.alert = DeckAlert(title: "Modal", message: "Modal owns Escape", confirmTitle: "OK", destructive: false, action: {})
        try check(!model.consumeDeckEscape(terminalHasFocus: true) && model.pendingDeletion != nil,
                  "native alert owns Escape without cancelling a covered operation")
        model.alert = nil
        try check(model.consumeDeckEscape(terminalHasFocus: true) && model.pendingDeletion == nil && model.isFullscreen(a),
                  "Escape cancels deletion before changing expansion, even with PTY focus")
        model.beginRename(a)
        model.renameText = "do not save"
        try check(model.consumeDeckEscape(terminalHasFocus: true) && model.renamingKey == nil && model.card(for: "a")?.title != "do not save",
                  "Escape cancels title editing without saving or collapsing terminal")
        try check(!model.consumeDeckEscape(terminalHasFocus: true) && model.isFullscreen(a), "ordinary terminal Escape passes through to vim/less")
        try check(model.consumeDeckEscape() && !model.isFullscreen(a), "Escape outside terminal still exits expanded panel")
        model.exitWorkhorseMode()
        model.beginEditCard(model.card(for: "a")!)
        model.editorTitle = "Card mode draft"
        model.navigate(to: .temps)
        try check(model.alert != nil && model.page == .editor, "shared card-mode editor is also protected")
    }
    @MainActor static func paletteChecks() throws {
        func luminance(_ color: SwiftUI.Color) -> Double {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            let rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { value -> Double in
                let n = Double(value)
                return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
            }
            return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var ratios: [Double] = []
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                for foreground in [WorkhorseTheme.muted, WorkhorseTheme.accentText] {
                    for background in [WorkhorseTheme.background, WorkhorseTheme.panelSecondary,
                                       WorkhorseTheme.hover, WorkhorseTheme.selection, WorkhorseTheme.accentSoft] {
                        let a = luminance(foreground), b = luminance(background)
                        ratios.append((max(a, b) + 0.05) / (min(a, b) + 0.05))
                    }
                }
            }
            try check(ratios.allSatisfy { $0 >= 4.5 }, "\(appearance.rawValue) small text contrast >= 4.5 across normal/hover/selected surfaces (min \(ratios.min()!))")
        }
    }

    @MainActor static func key(_ code: UInt16, characters: String, in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                        isARepeat: false, keyCode: code)!
            NSApp.postEvent(event, atStart: false)
        }
        pump(0.15)
    }

    @MainActor static func mouse(_ type: NSEvent.EventType, _ point: CGPoint, in window: NSWindow,
                                 host: NSView, count: Int = 1) {
        let event = NSEvent.mouseEvent(with: type, location: host.convert(point, to: nil), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: count,
                                      pressure: type == .leftMouseDown ? 1 : 0)!
        NSApp.postEvent(event, atStart: false)
    }
    @MainActor static func snapshot<V: View>(_ name: String, host: NSHostingView<V>) throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pump(0.25)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        print("SCREENSHOT \(name)")
    }
    @MainActor static func nativeChecks(_ root: URL) throws {
        let model = try fixture(root)
        defer { model.engine.endAllSessions(timeout: 1) }
        let key = OwnerKey(kind: .preset, ownerId: "a")
        let host = NSHostingView(rootView: DeckRootView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 860),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "RunBo — isolated interaction regressions"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        pump(0.5)
        try check(NSApp.isActive && window.isKeyWindow, "native fixture receives desktop input focus")
        for index in 1...5 {
            // Model-driven navigation is not a physical intervening click. Let the previous
            // double-click sequence expire before sending a new clickCount=1 sequence.
            model.goHome(); pump(NSEvent.doubleClickInterval + 0.05)
            guard let frame = model.cardFrame(for: key) else { throw NSError(domain: "MissingRowFrame", code: 1) }
            let point = CGPoint(x: frame.midX, y: frame.midY)
            let start = Date()
            mouse(.leftMouseDown, point, in: window, host: host); pump(0.01)
            mouse(.leftMouseUp, point, in: window, host: host)
            // Measure the whole new Debug surface, not just the gesture. The invariant is
            // navigation before the double-click decision deadline, not a device-specific 100ms SLA.
            let budget = min(0.25, NSEvent.doubleClickInterval * 0.75)
            while model.page == .presets && Date().timeIntervalSince(start) < budget { pump(0.003) }
            let elapsed = Date().timeIntervalSince(start)
            try check(model.page == .detail(key) && elapsed < budget,
                      "single click \(index) navigates before double-click deadline (\(Int(elapsed * 1000))ms, page \(model.page))")
            pump(0.1)
        }
        model.goHome(); pump(NSEvent.doubleClickInterval + 0.05)
        guard let frame = model.cardFrame(for: key) else { throw NSError(domain: "MissingRowFrame", code: 1) }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        mouse(.leftMouseDown, point, in: window, host: host); pump(0.01)
        mouse(.leftMouseUp, point, in: window, host: host); pump(0.08)
        mouse(.leftMouseDown, point, in: window, host: host, count: 2); pump(0.01)
        mouse(.leftMouseUp, point, in: window, host: host, count: 2); pump(0.15)
        try check(model.isRenaming(key, in: .workhorseList), "native double click still edits title after immediate single-click selection")
        try snapshot("inline-rename", host: host)
        let other = OwnerKey(kind: .preset, ownerId: "b")
        model.beginRename(other, source: .workhorseList); pump(0.2)
        try check(model.isRenaming(other, in: .workhorseList), "old row's deferred focus callback cannot commit a newly opened title editor")
        model.cancelRename()
        model.openHistory(for: key)
        try snapshot("empty-history", host: host)
        model.beginNewCard(); pump(0.2)
        _ = model.saveEditor(); pump(0.25)
        try check(window.firstResponder is NSTextView && model.editorTitleError != nil, "invalid form focuses title field")
        model.editorTitle = "Valid title"
        _ = model.saveEditor(); pump(0.25)
        try check(window.firstResponder is PlaceholderTextView && model.editorCommandError != nil, "missing command focuses native shell editor")
        try snapshot("editor-validation", host: host)
        model.cancelEditor()
        model.workhorseSelect(key)
        model.startCard(model.card(for: "a")!)
        let readyDeadline = Date().addingTimeInterval(10)
        while model.liveRuntime(key)?.isReachable != true && Date() < readyDeadline { pump(0.05) }
        try check(model.liveRuntime(key)?.isReachable == true, "isolated PTY becomes ready for focus regression")
        let scene = model.liveScene(sessionId: model.liveRuntime(key)!.sessionId)
        pump(0.2)
        window.makeFirstResponder(scene.view)
        try Data("focus fixture".utf8).write(to: root.appendingPathComponent("example.txt"))
        model.fileBrowser.toggle(requestFocus: true); pump(0.35)
        let tree = model.fileBrowser.card(for: key, root: root)
        self.key(125, characters: "\u{F701}", in: window)
        try check(window.firstResponder !== scene.view && tree.state.selected != nil,
                  "explicit Files open focuses tree and down arrow selects a file, not the PTY")
        try snapshot("file-tree-focus", host: host)
        _ = model.consumeDeckEscape(terminalHasFocus: false); pump(0.25)
        try check(window.firstResponder === scene.view, "closing file drawer restores originating terminal focus")
        let first = model.createTag(named: "第一项")!, second = model.createTag(named: "第二项")!
        model.openTagPicker(for: key); pump(0.3)
        try check(model.tagPicker != nil, "tag picker opens against real row geometry")
        self.key(125, characters: "\u{F701}", in: window)
        self.key(36, characters: "\r", in: window)
        try check(model.tagID(for: key) == second.id && model.tagID(for: key) != first.id,
                  "tag picker down-arrow and Return assign the second tag using native keys")
        model.closeTagPicker()
        model.createCopy(key)
        let copy = model.copyKeys.first!
        model.notice = nil
        let surface = NSHostingView(rootView:
            VStack(alignment: .leading, spacing: 14) {
                ForEach([240.0, 296.0, 460.0], id: \.self) { width in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Int(width))pt / ordinary + copy").font(.system(size: 12))
                        WorkhorseRow(model: model, kind: .preset, id: "b", title: model.card(for: "b")!.title,
                                     detail: "printf READY; sleep 30", selectedKey: nil, hoveredID: "b")
                        WorkhorseRow(model: model, kind: .preset, id: copy.ownerId, title: model.card(for: copy.ownerId)!.title,
                                     detail: "printf READY", selectedKey: nil, hoveredID: copy.ownerId)
                    }.frame(width: width - 20)
                }
            }.padding(20).frame(width: 500, alignment: .leading).background(WorkhorseTheme.panelSecondary))
        let rowWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 500, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        rowWindow.isReleasedWhenClosed = false; rowWindow.contentView = surface; rowWindow.orderFront(nil)
        defer { rowWindow.orderOut(nil); rowWindow.contentView = nil }
        for dark in [false, true] {
            rowWindow.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try snapshot(dark ? "hover-dark" : "hover-light", host: surface)
        }
    }
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runbo-interactions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try modelChecks(root.appendingPathComponent("model"))
            try paletteChecks()
            try nativeChecks(root.appendingPathComponent("native"))
            print("ALL WORKHORSE INTERACTION CHECKS PASSED")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}

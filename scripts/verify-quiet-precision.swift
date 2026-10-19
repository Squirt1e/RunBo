import AppKit
import SwiftUI
import TerminalDeckKit
@testable import TerminalDeck

/// This verifies the native implementation, not the earlier HTML prototype.
/// Physical keyboard/TUI, VoiceOver speech and low-end frame rates still need human acceptance.
@main struct VerifyQuietPrecision {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw NSError(domain: "QuietPrecision", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        count += 1; print("PASS \(label)")
    }
    @MainActor static func pump(_ seconds: Double = 0.12) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.003), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.003))
        }
    }
    @MainActor static func wait(_ label: String, _ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(12)
        while !predicate() && Date() < deadline { pump(0.03) }
        try check(predicate(), label)
    }
    @MainActor static func fixture(_ root: URL) throws -> AppModel {
        let store = try TerminalDeckStore(directory: root)
        try store.save(PresetCard(id: "a", title: "Build Release", command: "printf BUILD; sleep 25", workingDirectory: root.path))
        try store.save(PresetCard(id: "b", title: "Web Dev", command: "printf WEB; sleep 25", workingDirectory: root.path))
        try store.save(PresetCard(id: "c", title: "文档预览", command: "false", workingDirectory: root.path))
        let model = AppModel(store: store)
        model.engine.baseEnvironment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        model.enterWorkhorseMode()
        model.notice = nil
        return model
    }
    @MainActor static func confirm(_ model: AppModel) throws {
        guard let alert = model.alert else { throw NSError(domain: "MissingAlert", code: 1) }
        model.alert = nil; alert.action()
    }
    @MainActor static func modelChecks(_ root: URL) throws {
        let model = try fixture(root)
        defer { model.engine.endAllSessions(timeout: 1) }
        let a = OwnerKey(kind: .preset, ownerId: "a"), b = OwnerKey(kind: .preset, ownerId: "b")
        try check(DeckTheme.menuIconSize < DeckTheme.homeIconSize, "menu glyphs remain smaller than Home without reducing hit areas")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                DeckTheme.palette = .standard
                let standard = NSColor(DeckTheme.background).usingColorSpace(.sRGB)!
                DeckTheme.palette = .workhorse
                let workhorse = NSColor(DeckTheme.background).usingColorSpace(.sRGB)!
                precondition(standard == workhorse, "the two layouts must share material tokens")
            }
        }
        try check(WorkhorseHomeLayout(width: 2094, height: 2000).heroHeight <= 160, "large screens do not turn the brand signature into a billboard")
        try check(WorkhorseHomeLayout(width: 804, height: 500).heroHeight == 120, "short windows reserve more room for tasks")
        try check(model.quickNavigationResults(matching: "ｗｅｂ DEV").count == 1, "quick navigation folds width and case")
        let tag = model.createTag(named: "发布")!
        model.assignTag(tag.id, to: a)
        try check(model.quickNavigationResults(matching: "发布 build").first?.title == "Build Release", "quick navigation combines tag and title search terms")
        try check(model.quickNavigationResults(matching: "no-such-project").isEmpty, "unknown input has no implicit execution fallback")
        let sessionsBefore = try model.store.sessions(kind: .preset, ownerId: "b").count
        let result = model.quickNavigationResults(matching: "web").first!
        model.activateQuickNavigation(result)
        try check(model.page == .detail(b) && model.engine.allRuntimes.isEmpty, "choosing a result only navigates and never starts its command")
        try check(try model.store.sessions(kind: .preset, ownerId: "b").count == sessionsBefore, "navigation creates no stored session")
        model.beginEditCard(model.card(for: "a")!)
        model.editorTitle = "Unsaved"
        model.activateQuickNavigation(result)
        try check(model.page == .editor && model.alert?.saveAction != nil && model.engine.allRuntimes.isEmpty, "quick navigation cannot bypass dirty-draft protection")
        model.alert = nil; model.cancelEditor(); model.goHome()
        let beforeFocus = model.page
        try check(model.sidebarNavigationNodes.contains(.tag(tag.id)) && model.sidebarNavigationNodes.contains(.owner(a)), "expanded sidebar exposes tag and project focus nodes")
        model.activateSidebarNode(.tag(tag.id))
        try check(!model.sidebarNavigationNodes.contains(.owner(a)) && model.page == beforeFocus, "collapsing a group removes hidden focus stops without navigating")
        model.activateSidebarNode(.menu(.preset))
        try check(!model.sidebarNavigationNodes.contains(.tag(tag.id)), "collapsed menus have no hidden tag stops")
        model.activateSidebarNode(.menu(.preset)); model.activateSidebarNode(.tag(tag.id))
        try check(model.sidebarParent(of: a) == .tag(tag.id), "left arrow can find a project's actual tag parent")
        model.activateSidebarNode(.owner(a))
        try check(model.page == .detail(a) && model.engine.allRuntimes.isEmpty, "sidebar Return only navigates")

        model.dismissNotice()
        var retries = 0
        model.showError("Persistent error A", retry: { retries += 1 })
        let firstError = model.feedback!.id
        model.showNotice("A routine success must not erase error A")
        try check(model.notice == "Persistent error A" && model.feedback?.kind == .error, "success feedback never overwrites an unread error")
        pump(3.4)
        try check(model.feedback?.id == firstError, "errors do not expire after the old 3.2 second toast timeout")
        model.showError("Persistent error B")
        model.showError("Persistent error B")
        model.retryNotice(id: firstError)
        try check(retries == 1 && model.notice == "Persistent error B", "retry is explicit and the next distinct error is preserved")
        model.retryNotice(id: firstError)
        try check(retries == 1, "a stale retry cannot repeat an already consumed action")
        model.dismissNotice()
        try check(model.feedback == nil, "duplicate errors are coalesced, not endlessly queued")

        let files = model.fileBrowser
        files.toggle(source: .keyboard)
        try check(files.inputSource == .keyboard && DeckInputSource.keyboard.animation(entering: true) == nil, "keyboard file opening does not wait for animation")
        _ = files.consumeEscape()
        try check(!files.isVisible && files.inputSource == .keyboard, "Escape closes the drawer as a keyboard interaction")
        try check(DeckInputSource.automatic.animation(entering: true) == nil, "automatic wide-panel presentation stays immediate")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try check(DeckInputSource.pointer.animation(entering: true) != nil, "pointer drawer opening has a bounded purposeful transition")
        }

        model.createCopy(a)
        let offline = model.copyKeys.first!
        model.removeCopy(offline)
        try check(model.alert == nil && model.vanishing[offline] != nil, "offline copy removal retains the existing particle lifecycle without extra confirmation")
        try wait("offline copy disappears after its particle lifecycle") { !model.copyKeys.contains(offline) && model.removingCopies.isEmpty }
        model.createCopy(a)
        let live = model.copyKeys.first!
        model.startCard(model.card(for: live.ownerId)!)
        try wait("copy gets a real live PTY") { model.liveRuntime(live)?.isReachable == true }
        let firstSession = model.liveRuntime(live)!.sessionId
        model.removeCopy(live)
        try check(model.alert?.destructive == true && model.removingCopies.isEmpty && model.liveRuntime(live)?.sessionId == firstSession,
                  "requesting online removal does not terminate before confirmation")
        let oldConfirmation = model.alert!.action
        model.alert = nil
        try check(model.isDisposableCopy(live) && model.liveRuntime(live)?.sessionId == firstSession, "cancelling online removal preserves card and exact PTY")
        model.stop(live)
        try wait("old copy session stops for stale-confirmation test") { model.liveRuntime(live) == nil }
        model.startCard(model.card(for: live.ownerId)!)
        try wait("copy starts a distinct replacement PTY") { model.liveRuntime(live)?.isReachable == true && model.liveRuntime(live)?.sessionId != firstSession }
        let replacement = model.liveRuntime(live)!.sessionId
        oldConfirmation()
        try check(model.alert?.title == "解除在线分身？" && model.liveRuntime(live)?.sessionId == replacement && model.removingCopies.isEmpty,
                  "an old confirmation cannot authorize destroying a replacement PTY")
        try confirm(model)
        try wait("confirmed live copy removal finishes") { !model.copyKeys.contains(live) && model.removingCopies.isEmpty }
        try check(model.card(for: a.ownerId) != nil && model.liveRuntime(a) == nil, "online copy removal does not affect its source")
    }

    @MainActor static func key(_ code: UInt16, _ characters: String, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.postEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)!, atStart: false)
        }
        pump(0.15)
    }
    @MainActor static func snapshot<V: View>(_ name: String, host: NSHostingView<V>) throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pump(0.2); host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        print("SCREENSHOT \(name)")
    }
    @MainActor static func menuButtons(in element: Any) -> [NSAccessibilityProtocol] {
        guard let ax = element as? NSAccessibilityProtocol else { return [] }
        if ax.accessibilityRole() == .menuButton { return [ax] }
        let children = ax.accessibilityChildren() ?? []
        return (children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children).flatMap { menuButtons(in: $0) }
    }
    @MainActor static func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    @MainActor static func pressAlert(_ title: String, window: NSWindow) throws {
        guard let content = window.attachedSheet?.contentView,
              let button = buttons(in: content).first(where: { $0.title == title }) else {
            throw NSError(domain: "MissingNativeAlertButton", code: 1, userInfo: [NSLocalizedDescriptionKey: title])
        }
        button.performClick(nil); pump(0.15)
    }
    @MainActor static func nativeChecks(_ root: URL) throws {
        let model = try fixture(root)
        defer { model.engine.endAllSessions(timeout: 1) }
        let work = model.createTag(named: "工作")!, other = model.createTag(named: "数据库")!
        model.assignTag(work.id, to: OwnerKey(kind: .preset, ownerId: "a"))
        model.assignTag(work.id, to: OwnerKey(kind: .preset, ownerId: "b"))
        model.assignTag(other.id, to: OwnerKey(kind: .preset, ownerId: "c"))
        model.notice = nil
        let host = NSHostingView(rootView: DeckRootView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1100, height: 860), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        pump(0.5)
        try check(window.isKeyWindow && NSApp.isActive, "native fixture receives desktop input focus")
        try snapshot("home-light", host: host)
        window.setContentSize(NSSize(width: 1100, height: 650)); pump(0.2)
        try snapshot("home-short", host: host)
        window.setContentSize(NSSize(width: 1100, height: 860)); pump(0.2)
        window.makeFirstResponder(nil)
        var tabs = 0
        while model.sidebarFocusedNode?.owner == nil && tabs < 30 {
            key(48, "\t", window: window); tabs += 1
        }
        try check(model.sidebarFocusedNode?.owner != nil, "Tab reaches an actual sidebar project focus stop")
        let pageBeforeArrow = model.page
        key(125, "\u{F701}", window: window)
        try check(model.page == pageBeforeArrow && model.sidebarFocusedNode != nil, "sidebar arrow changes focus without selecting or starting a project")
        if let owner = model.sidebarFocusedNode?.owner {
            key(36, "\r", window: window)
            try check(model.page == .detail(owner) && model.engine.allRuntimes.isEmpty, "native Return on focused row only opens its detail")
        } else { throw NSError(domain: "ExpectedFocusedOwner", code: 1) }
        try snapshot("sidebar-keyboard-focus", host: host)
        key(48, "\t", window: window)
        try snapshot("sidebar-actions-tab", host: host)
        try check(model.sidebarFocusedNode == .action(OwnerKey(kind: .preset, ownerId: "b"), "primary") && !menuButtons(in: host).isEmpty,
                  "Tab reaches row actions and does not remove them during focus transfer")
        key(48, "\t", window: window, modifiers: .shift)
        try check(model.sidebarFocusedNode?.owner != nil, "Shift Tab returns from an action to its project row")

        let a = OwnerKey(kind: .preset, ownerId: "a")
        model.workhorseSelect(a); model.startCard(model.card(for: "a")!)
        try wait("terminal gets ready for palette focus restoration") { model.liveRuntime(a)?.isReachable == true }
        let scene = model.liveScene(sessionId: model.liveRuntime(a)!.sessionId)
        try wait("live terminal view is mounted") { scene.view.window === window }
        try check(window.makeFirstResponder(scene.view) && window.firstResponder === scene.view, "terminal owns focus before Command K")
        let session = model.liveRuntime(a)!.sessionId
        key(40, "k", window: window, modifiers: .command)
        try wait("native Command K opens and focuses search instead of sending input to the PTY") {
            model.quickNavigationPresented && window.firstResponder is NSTextView
        }
        try snapshot("quick-navigation-light", host: host)
        for _ in 0..<12 { key(48, "\t", window: window) }
        try check(model.quickNavigationPresented && window.firstResponder !== scene.view, "palette Tab remains inside the modal instead of reaching the PTY")
        key(53, "\u{1b}", window: window)
        try wait("palette Escape restores the original terminal focus") { !model.quickNavigationPresented && window.firstResponder === scene.view }
        try check(model.liveRuntime(a)?.sessionId == session, "opening and closing palette never restarts the terminal")
        key(40, "k", window: window, modifiers: .command)
        if let editor = window.firstResponder as? NSTextView {
            editor.insertText("web", replacementRange: NSRange(location: NSNotFound, length: 0)); pump(0.2)
        }
        key(36, "\r", window: window)
        try check(!model.quickNavigationPresented && model.page == .detail(OwnerKey(kind: .preset, ownerId: "b")) && model.liveRuntime(OwnerKey(kind: .preset, ownerId: "b")) == nil,
                  "native palette search and Return open an unstarted project without executing it")
        model.workhorseSelect(a)
        window.appearance = NSAppearance(named: .darkAqua); pump(0.2)
        try snapshot("terminal-dark", host: host)
        model.createCopy(a)
        let copy = model.copyKeys.first!
        model.startCard(model.card(for: copy.ownerId)!)
        try wait("native online-copy fixture has a live session") { model.liveRuntime(copy)?.isReachable == true }
        let copySession = model.liveRuntime(copy)!.sessionId
        model.beginEditCard(model.card(for: copy.ownerId)!)
        model.editorTitle = "Unsaved copy title"
        model.removeCopy(copy)
        try wait("native dirty-copy confirmation appears") { window.attachedSheet != nil && model.alert?.title == "放弃未保存的修改？" }
        try pressAlert("放弃修改", window: window)
        try wait("native follow-up online confirmation survives old-alert dismissal") {
            window.attachedSheet != nil && model.alert?.title == "解除在线分身？"
        }
        key(36, "\r", window: window.attachedSheet!)
        try wait("native Return defaults to cancelling online-copy termination") { window.attachedSheet == nil && model.alert == nil }
        try check(model.liveRuntime(copy)?.sessionId == copySession, "default Return cannot silently destroy the online copy")
        model.removeCopy(copy)
        try wait("online confirmation reopens for the independent Escape check") { window.attachedSheet != nil && model.alert != nil }
        key(53, "\u{1b}", window: window.attachedSheet!)
        try wait("native Escape cancels online-copy confirmation") { window.attachedSheet == nil && model.alert == nil }
        try check(model.copyKeys.contains(copy) && model.liveRuntime(copy)?.sessionId == copySession,
                  "native cancellation preserves the exact online-copy terminal")
        model.removeCopy(copy)
        try wait("native online-copy confirmation can be requested again") { window.attachedSheet != nil && model.alert != nil }
        try pressAlert("结束终端并解除", window: window)
        try wait("native destructive confirmation removes only the requested copy") { !model.copyKeys.contains(copy) && model.removingCopies.isEmpty }
        try check(model.liveRuntime(a)?.sessionId == session, "native copy confirmation leaves the original session intact")
        model.workhorseSelect(a); model.notice = nil
        model.fileBrowser.toggle(requestFocus: true, source: .pointer); pump(0.3)
        try snapshot("files-dark", host: host)
        model.fileBrowser.close(source: .keyboard)
        let failed = OwnerKey(kind: .preset, ownerId: "c")
        model.startCard(model.card(for: "c")!)
        try wait("a real failed command supplies the home attention row") { model.presentation(for: failed).tone == .failed }
        model.goHome(); model.notice = nil
        try snapshot("home-dark-running", host: host)
        window.appearance = NSAppearance(named: .aqua)
        try snapshot("home-light-running", host: host)
        model.exitWorkhorseMode(); model.notice = nil; window.appearance = NSAppearance(named: .aqua)
        try snapshot("cards-light-running", host: host)
        try wait("standard cards publish grid frames rather than stale sidebar row frames") {
            model.cardFrame(for: a).map { abs($0.height - CardDisplay.cardHeight) < 1 } == true
        }
        let beforeError = model.cardFrame(for: a)!
        model.showError("设计回归测试：此错误会持续保留，可以复制完整信息；没有重试闭包时不提供误导性重试按钮。")
        pump(0.4)
        try check(model.page == .presets && model.cardFrame(for: a)! == beforeError,
                  "floating error feedback leaves the card's complete frame unchanged")
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let pixel = bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh * 2 / 3)!.usingColorSpace(.sRGB)!
        try check(pixel.redComponent + pixel.greenComponent + pixel.blueComponent > 1,
                  "light card content still renders behind persistent floating feedback")
        try snapshot("persistent-error", host: host)
    }
    /// Real SwiftUI frames: shared tracks across groups, legacy retained cards, and flat copy flow.
    @MainActor static func layoutFeedbackChecks(_ root: URL) throws {
        let store = try TerminalDeckStore(directory: root)
        let groups = [("pi", "Pi", 2), ("clash", "Clash", 2), ("scripts", "Scripts", 4)]
        for (index, group) in groups.enumerated() {
            try store.save(CardTag(id: group.0, name: group.1, sortOrder: index))
            for number in 0..<group.2 {
                try store.save(PresetCard(id: "\(group.0)-\(number)", title: "\(group.1) \(number + 1)",
                                         command: "printf READY; sleep 30", workingDirectory: root.path, tagId: group.0))
            }
        }
        let source = OwnerKey(kind: .preset, ownerId: "pi-1")
        let retained = try store.createCopy(of: source, runID: "fixture", defaultShell: "zsh")
        try store.retainCopy(retained)
        // Reproduce the screenshot's v4 data, not only newly retained cards.
        try store.database.run("""
        UPDATE preset_cards SET title = 'Agents Usage', copy_source_id = ?, copy_number = 8,
            copy_anchor_id = ? WHERE id = ?;
        """, [.text(source.ownerId), .text(source.ownerId), .text(retained.ownerId)])
        let model = AppModel(store: store)
        model.engine.baseEnvironment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        defer { model.engine.endAllSessions(timeout: 1) }
        let host = NSHostingView(rootView: DeckRootView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1800, height: 1100),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        if CommandLine.arguments.contains("--background") { window.orderBack(nil) }
        else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        defer { window.orderOut(nil); window.contentView = nil }
        pump(0.4)
        func frame(_ id: String) throws -> CGRect {
            guard let value = model.cardFrame(for: OwnerKey(kind: .preset, ownerId: id)) else {
                throw NSError(domain: "MissingCardFrame", code: 1, userInfo: [NSLocalizedDescriptionKey: id])
            }
            return value
        }
        func listScrollView() throws -> NSScrollView {
            func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
            }
            guard let scroll = scrollView(in: host) else { throw NSError(domain: "MissingListScrollView", code: 1) }
            return scroll
        }
        func listViewport() throws -> CGRect {
            let scroll = try listScrollView()
            guard let document = scroll.documentView else { throw NSError(domain: "MissingListDocument", code: 1) }
            return document.convert(document.bounds, to: host)
        }
        func revealScripts() throws {
            // Scroll rather than collapsing preceding groups: with classic scrollers, folding
            // enough content removes the scrollbar and legitimately changes viewport width.
            for _ in 0..<3 {
                let scroll = try listScrollView()
                guard let document = scroll.documentView else { throw NSError(domain: "MissingListDocument", code: 1) }
                let clip = scroll.contentView
                let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height)
                                          : document.bounds.minY
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
                scroll.reflectScrolledClipView(clip)
                host.layoutSubtreeIfNeeded(); pump(0.1)
            }
        }
        var scrollerStyle = NSScroller.Style.overlay
        func resize(_ width: Double) {
            window.setContentSize(NSSize(width: width, height: 1100))
            // SwiftUI can restore the system scroller preference when groups change. Reapply
            // the fixture's style so comparisons really use the same viewport in both phases.
            for _ in 0..<3 {
                if let scroll = try? listScrollView() {
                    scroll.scrollerStyle = scrollerStyle
                    scroll.hasVerticalScroller = true
                    scroll.autohidesScrollers = false
                    scroll.tile()
                }
                host.layoutSubtreeIfNeeded(); pump(0.15)
            }
        }
        try check(model.card(for: retained.ownerId)?.copy == nil,
                  "legacy retained cards load as independent ordinary cards")
        for style in [NSScroller.Style.overlay, .legacy] {
            let styleName = style == .overlay ? "overlay" : "legacy"
            scrollerStyle = style
            for tag in ["pi", "clash"] where model.isTagCollapsed(tag) { model.toggleTagCollapsed(tag) }
            var sparseWidths: [Double: CGFloat] = [:]
            for width in [1800.0, 1200.0, 900.0, 600.0] {
                resize(width)
                let viewport = try listViewport()
                try check(try listScrollView().scrollerStyle == .legacy && listScrollView().verticalScroller is DeckScroller,
                          "\(styleName) preference uses the shared renderer without native overlay clipping")
                let grid = CardDisplay.wideListGrid(in: viewport.width - 60)
                let first = try frame("pi-0")
                let piFrames = try ["pi-0", "pi-1", retained.ownerId].map { try frame($0) }
                sparseWidths[width] = first.width
                try check(abs(first.minX - viewport.minX - 30) < 1 && abs(first.width - grid.cardWidth) < 1,
                          "\(styleName) \(Int(width))pt list tracks use the actual scroll-content width")
                for (index, card) in piFrames.enumerated() {
                    let x = first.minX + CGFloat(index % grid.columns) * (first.width + CardDisplay.spacing)
                    let y = first.minY + CGFloat(index / grid.columns) * (CardDisplay.cardHeight + CardDisplay.spacing)
                    try check(abs(card.minX - x) < 1 && abs(card.minY - y) < 1 && abs(card.width - first.width) < 1,
                              "\(styleName) \(Int(width))pt Pi card \(index) follows ordinary row-major order")
                    try check(card.maxX <= viewport.maxX - 29 && abs(card.height - CardDisplay.cardHeight) < 1,
                              "\(styleName) \(Int(width))pt Pi card \(index) has stable height without overflow")
                }
                let clash = try frame("clash-0")
                try check(abs(clash.width - first.width) < 1 && abs(clash.minX - first.minX) < 1,
                          "\(styleName) \(Int(width))pt Pi and Clash share column width and leading origin")
                let piBottom = piFrames.map(\.maxY).max()!
                try check(abs(clash.minY - piBottom - 64) < 1,
                          "\(styleName) \(Int(width))pt Pi reserves no hidden source-copy stack row")
                let before = try frame("pi-0")
                model.showNotice("布局测试：成功提示不会挤动页面。"); pump(0.15)
                try check(try frame("pi-0") == before, "\(styleName) \(Int(width))pt success toast does not shift cards")
                model.showError(String(repeating: "完整错误信息，支持滚动和复制。", count: 30)); pump(0.15)
                try check(try frame("pi-0") == before, "\(styleName) \(Int(width))pt long error toast does not shift cards")
                try snapshot("cards-responsive-\(styleName)-\(Int(width))", host: host)
                model.dismissNotice(); pump(0.15)
                try check(try frame("pi-0") == before, "\(styleName) \(Int(width))pt dismissing feedback does not shift cards")
            }
            // Keep all groups mounted in the document while bringing Scripts into view.
            for width in [600.0, 900.0, 1200.0, 1800.0] {
                resize(width)
                try revealScripts()
                let viewport = try listViewport()
                try check(try listScrollView().scrollerStyle == .legacy && listScrollView().verticalScroller is DeckScroller,
                          "\(styleName) dense fixture keeps the shared renderer after relayout")
                let grid = CardDisplay.wideListGrid(in: viewport.width - 60)
                let first = try frame("scripts-0")
                for number in 0..<4 {
                    let card = try frame("scripts-\(number)")
                    let x = first.minX + CGFloat(number % grid.columns) * (first.width + CardDisplay.spacing)
                    let y = first.minY + CGFloat(number / grid.columns) * (CardDisplay.cardHeight + CardDisplay.spacing)
                    try check(abs(card.width - sparseWidths[width]!) < 1 && abs(card.width - grid.cardWidth) < 1,
                              "\(styleName) \(Int(width))pt Scripts card \(number) matches sparse-group width (actual \(card.width), sparse \(sparseWidths[width]!), grid \(grid.cardWidth), viewport \(viewport.width))")
                    try check(abs(card.minX - x) < 1 && abs(card.minY - y) < 1 && card.maxX <= viewport.maxX - 29,
                              "\(styleName) \(Int(width))pt Scripts card \(number) shares tracks without overflow")
                }
            }
        }
        for tag in ["pi", "clash"] where model.isTagCollapsed(tag) { model.toggleTagCollapsed(tag) }
        resize(1800)
        model.createCopy(source); pump(0.35)
        let active = model.copyKeys.first!
        model.createCopy(active); pump(0.35)
        let nested = model.copyKeys.subtracting([active]).first!
        for mode in CardDisplayMode.allCases {
            model.setDisplayMode(mode, for: .preset); resize(1800)
            let viewport = try listViewport()
            let columns = mode == .wide ? CardDisplay.wideListGrid(in: viewport.width - 60).columns
                                        : CardDisplay.squareColumns(in: viewport.width - 60)
            let ids = model.cards.filter { $0.tagId == "pi" }.map(\.id)
            let first = try frame(ids[0])
            for (index, id) in ids.enumerated() {
                let card = try frame(id)
                let x = first.minX + CGFloat(index % columns) * (first.width + CardDisplay.spacing)
                let y = first.minY + CGFloat(index / columns) * (CardDisplay.cardHeight + CardDisplay.spacing)
                try check(abs(card.minX - x) < 1 && abs(card.minY - y) < 1 && abs(card.width - first.width) < 1,
                          "\(mode.rawValue) ordinary, retained, active and nested copy \(index) share flat grid flow")
            }
            if mode == .square {
                try check(abs(first.width - CardDisplay.cardHeight) < 1, "square cards retain their fixed side")
            }
            try snapshot("cards-flat-copies-\(mode.rawValue)", host: host)
        }
        model.startCard(model.card(for: active.ownerId)!)
        try wait("copy gets a real PTY before independent retention") { model.liveRuntime(active)?.isReachable == true }
        let retainedSession = model.liveRuntime(active)!.sessionId
        let historyIDs = try store.sessions(kind: .preset, ownerId: active.ownerId).map(\.id)
        let order = model.cards.map(\.id)
        model.retainCopy(active); pump(0.3)
        try check(model.copyIdentity(active) == nil && (try store.cards()).first { $0.id == active.ownerId }?.copy == nil,
                  "retention clears all copy identity in memory and storage")
        try check(model.cards.map(\.id) == order && model.liveRuntime(active)?.sessionId == retainedSession,
                  "independent retention preserves the saved sequence and exact live PTY")
        try check(try store.sessions(kind: .preset, ownerId: active.ownerId).map(\.id) == historyIDs,
                  "independent retention preserves owned history")
        try check(model.isDisposableCopy(nested), "retaining a card does not change another copy's lifecycle")
        window.setContentSize(NSSize(width: 1100, height: 860))
        model.startCard(model.card(for: source.ownerId)!)
        try wait("feedback regression fixture starts a real terminal") { model.liveRuntime(source)?.isReachable == true }
        for workhorse in [false, true] {
            if workhorse { model.enterWorkhorseMode() }
            model.navigate(to: .detail(source)); model.dismissNotice(); pump(0.3)
            let scene = model.liveScene(sessionId: model.liveRuntime(source)!.sessionId)
            try wait("terminal is mounted in \(workhorse ? "workhorse" : "card") mode") { scene.view.window === window }
            window.makeFirstResponder(scene.view)
            let bounds = scene.view.bounds, position = scene.view.convert(scene.view.bounds, to: host)
            for isError in [false, true] {
                if isError { model.showError("Persistent terminal error") } else { model.showNotice("Terminal ready") }
                pump(0.2)
                try check(scene.view.bounds == bounds && scene.view.convert(scene.view.bounds, to: host) == position,
                          "\(workhorse ? "workhorse" : "card") \(isError ? "error" : "success") toast preserves terminal size and position")
                try check(window.firstResponder === scene.view, "feedback does not steal terminal keyboard focus")
                model.dismissNotice(); pump(0.15)
                try check(scene.view.bounds == bounds && scene.view.convert(scene.view.bounds, to: host) == position,
                          "dismissing feedback preserves terminal geometry")
            }
        }
    }
    @MainActor static func pixels<V: View>(_ host: NSHostingView<V>) -> Data {
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])!
    }
    /// Follow the actual browse → detail → run → switch → retain chain, not only model setters.
    @MainActor static func refinementChecks(_ root: URL) throws {
        let store = try TerminalDeckStore(directory: root)
        for id in ["a", "b", "c"] {
            try store.save(PresetCard(id: id, title: "Task \(id)", command: "printf READY; sleep 30", workingDirectory: root.path))
        }
        let record = SessionRecord(id: "narrow-record", kind: .preset, ownerId: "a", title: "Task a",
                                   shell: "/bin/zsh", workingDirectory: root.path, endedAt: Date(), termination: .normal)
        try store.save(record)
        try store.append([
            SessionEvent(sessionId: record.id, sequence: 0, kind: .resize, cols: 40, rows: 12),
            SessionEvent(sessionId: record.id, sequence: 1, kind: .output, data: Data("Recorded at 40 columns\r\n".utf8)),
            SessionEvent(sessionId: record.id, sequence: 2, kind: .resize, cols: 40, rows: 12),
        ])
        let model = AppModel(store: store)
        model.engine.baseEnvironment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        defer { model.engine.endAllSessions(timeout: 1) }
        let a = OwnerKey(kind: .preset, ownerId: "a")
        func switchResult() -> QuickNavigationItem { model.quickNavigationResults(matching: "模式").first! }
        try check(model.quickNavigationResults(matching: "mode switch").count == 1, "mode is a searchable explicit command in both languages")
        model.beginEditCard(model.card(for: "a")!); model.editorTitle = "Unsaved mode draft"
        model.activateQuickNavigation(switchResult())
        try check(!model.workhorseMode.isOn && model.page == .editor && model.alert != nil,
                  "mode command cannot discard a dirty editor draft")
        model.alert = nil
        try check(!model.workhorseMode.isOn && model.editorTitle == "Unsaved mode draft", "cancelling mode change preserves the draft and mode")
        model.cancelEditor()
        model.page = .settings; model.activateQuickNavigation(switchResult())
        try check(model.workhorseMode.isOn && model.page == .presets, "entering mode from Settings goes straight to the workbench")
        model.page = .settings; model.exitWorkhorseMode()
        try check(!model.workhorseMode.isOn && model.page == .presets, "leaving mode from Settings goes straight to the card view")
        model.setWorkhorseSidebarRatio(0.30, persist: true)
        model.fileBrowser.panelWidth = 300
        model.fileBrowser.togglePinned()
        model.fileBrowser.toggle(source: .keyboard)
        model.notice = nil; model.openDetail(a)
        var controlFrames: [String: CGRect] = [:]
        let host = NSHostingView(rootView: DeckRootView(model: model)
            .onPreferenceChange(WorkbenchControlFrameKey.self) { controlFrames = $0 })
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1800, height: 1000),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        func resize(_ width: CGFloat) {
            window.setContentSize(NSSize(width: width, height: 1000))
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); pump(0.12) }
        }
        func pressFrame(_ frame: CGRect) {
            let point = host.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!, atStart: false)
                pump(0.04)
            }
            pump(0.2)
        }
        func press(_ id: String) throws {
            guard let frame = controlFrames[id], host.bounds.contains(frame), !frame.isEmpty else {
                throw NSError(domain: "MissingRefinementButton", code: 1, userInfo: [NSLocalizedDescriptionKey: id])
            }
            pressFrame(frame)
        }
        let archive = model.archiveScene(sessionId: record.id)
        try wait("standard detail mounts its cached archive") { archive.view.window === window }
        try wait("archive replay finishes without blocking fixtures") { archive.replayFinished }
        for width in [950.0, 1100.0, 1800.0] {
            resize(width)
            let optimal = archive.view.getOptimalFrameSize().size
            try check(abs(optimal.width - archive.view.bounds.width) < 20 && abs(optimal.height - archive.view.bounds.height) < 30,
                      "\(Int(width))pt archive grid fits the current viewport instead of its recorded 40×12 grid")
            try snapshot("standard-detail-\(Int(width))", host: host)
            try check(controlFrames["启动"].map { host.bounds.contains($0) && $0.width >= 28 } == true,
                      "\(Int(width))pt standard detail keeps its lifecycle action reachable")
        }
        try check(try store.events(sessionId: record.id).last?.cols == 40, "fitting read-only replay never rewrites recorded sizes")
        let standardFrame = archive.view.convert(archive.view.bounds, to: host)
        model.enterWorkhorseMode(); model.toggleFullscreen(a); pump(0.4)
        let workhorseFrame = archive.view.convert(archive.view.bounds, to: host)
        try check(abs(workhorseFrame.minX - standardFrame.minX) < 1 && abs(workhorseFrame.width - standardFrame.width) < 1,
                  "both modes share the same sidebar, file width and terminal horizontal allocation")
        try check(model.fileBrowser.panelWidth == 300 && model.workhorseSidebarRatio == 0.30,
                  "switching modes does not reset either panel width")
        try press("启动")
        try wait("native detail Start launches the task") { model.liveRuntime(a)?.isCommandRunning == true }
        let session = model.liveRuntime(a)!.sessionId
        model.exitWorkhorseMode(); pump(0.4)
        try check(model.page == .detail(a) && model.liveRuntime(a)?.sessionId == session,
                  "switching back preserves the exact terminal and detail context")
        // At this width the explicitly pinned file panel leaves a narrow terminal bar.
        resize(1140)
        try check(controlFrames["终止"].map { abs($0.width - 28) < 1 } == true,
                  "narrow terminal toolbar switches to icons without shrinking its hit targets")
        try snapshot("standard-detail-compact-running", host: host)
        try press("终止")
        try wait("native compact toolbar Stop ends only its task") { model.liveRuntime(a) == nil }
        try check(model.page == .detail(a), "lifecycle controls never also trigger card navigation")
        model.page = .settings; pump(0.3)
        try snapshot("settings-corrected", host: host)
        try press("switch-mode")
        try check(model.workhorseMode.isOn && model.page == .presets, "native Settings switch immediately shows the target view")
        model.exitWorkhorseMode(); model.notice = nil; resize(1100)
        for mode in CardDisplayMode.allCases {
            model.setDisplayMode(mode, for: .preset)
            model.createCopy(a); pump(0.35)
            let copy = model.copyKeys.first!
            let before = model.cardFrame(for: copy)!
            let order = model.cards.map(\.id)
            try check(abs(before.height - model.cardFrame(for: a)!.height) < 1,
                      "\(mode.rawValue) copy footer buttons do not add a row to the card")
            try snapshot("copy-overlay-\(mode.rawValue)", host: host)
            let retainPoint = CGRect(x: before.minX + 15, y: before.maxY - (mode == .square ? 53 : 15) - 26,
                                     width: 30, height: 26)
            pressFrame(retainPoint)
            try check(!model.isDisposableCopy(copy) && model.page == .presets, "native Retain acts without opening the card")
            try check(model.copyIdentity(copy) == nil && model.cards.map(\.id) == order,
                      "\(mode.rawValue) retaining a copy removes hidden identity without rewriting card order")
        }
    }

    @MainActor static func animationChecks() throws {
        let host = NSHostingView(rootView: WorkhorseDot(kind: .executing, reduceMotionOverride: false).padding(16).frame(width: 48, height: 48)
            .background(DeckTheme.panel).transaction { $0.disablesAnimations = true })
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 48, height: 48), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil); pump(0.2)
        defer { window.orderOut(nil); window.contentView = nil }
        let first = pixels(host); pump(0.22); let second = pixels(host)
        try check(first != second, "execution pixels keep changing even when a keyboard transaction disables UI transitions")
        let staticHost = NSHostingView(rootView: WorkhorseDot(kind: .executing, reduceMotionOverride: true).padding(16).frame(width: 48, height: 48)
            .background(DeckTheme.panel))
        window.contentView = staticHost; pump(0.15)
        let staticFirst = pixels(staticHost); pump(0.22)
        try check(staticFirst == pixels(staticHost), "reduced-motion execution ring is visibly static rather than a hidden spinner")
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        let background = CommandLine.arguments.contains("--background")
        guard !background || CommandLine.arguments.contains("--layout-only") else {
            print("FAIL --background requires --layout-only; other checks need foreground input")
            exit(2)
        }
        _ = NSApplication.shared; NSApp.setActivationPolicy(background ? .prohibited : .accessory); NSApp.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runbo-quiet-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            if CommandLine.arguments.contains("--refinements-only") {
                try refinementChecks(root.appendingPathComponent("refinements"))
                print("\(count) REFINEMENT CHECKS PASSED")
                return
            }
            try layoutFeedbackChecks(root.appendingPathComponent("layout-feedback"))
            if !CommandLine.arguments.contains("--layout-only") {
                try refinementChecks(root.appendingPathComponent("refinements"))
                try modelChecks(root.appendingPathComponent("model"))
                try nativeChecks(root.appendingPathComponent("native"))
                try animationChecks()
            }
            print("\(count) QUIET PRECISION CHECKS PASSED")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}

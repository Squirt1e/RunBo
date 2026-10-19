import AppKit
import SwiftUI
import Core
@testable import App

@main
struct VerifySettingsShortcuts {
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else {
            throw NSError(domain: "SettingsShortcutVerification", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: label])
        }
        print("PASS \(label)")
    }

    @MainActor static func pump() {
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                           inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Local AppKit events, without moving the global pointer or requiring Accessibility permission.
    @MainActor static func click(_ point: CGPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                          clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
        pump()
    }

    @MainActor static func verify(splitMode: Bool, sidebarWidth: Double = 198) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-shortcut-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DataStore(directory: root)
        let card = PresetCard(id: "card", title: "Keep card", command: "true")
        let temp = TempTerminal(id: "temp", title: "Keep terminal")
        try store.save(card)
        try store.save(temp)
        for (id, kind, owner) in [("done-card", SessionKind.preset, card.id), ("done-temp", .temp, temp.id)] {
            try store.save(SessionRecord(id: id, kind: kind, ownerId: owner, title: id, shell: "/bin/zsh",
                                         startedAt: Date().addingTimeInterval(-10), endedAt: Date(), termination: .normal))
            try store.append([SessionEvent(sessionId: id, sequence: 0, kind: .output, data: Data("finished".utf8))])
        }
        let model = AppModel(store: store)
        // Add the unfinished fixture after launch reconciliation; no shell is started by these UI checks.
        try store.save(SessionRecord(id: "live", kind: .preset, ownerId: card.id, title: "Live", shell: "/bin/zsh"))
        let liveEvent = SessionEvent(sessionId: "live", sequence: 0, timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                                     kind: .output, data: Data("running".utf8))
        try store.append([liveEvent])
        if splitMode {
            model.enterSplitMode()
            model.setSidebarRatio(sidebarWidth / 1100, persist: false)
        }
        model.beginEditCard(card)
        model.editorTitle = "Unsaved draft"
        model.loadHistoryEntries(for: OwnerKey(kind: .preset, ownerId: card.id))
        let before = try store.historyUsage().eventBytes
        let keptCards = try store.cards(), keptTemps = try store.temps()
        let view = splitMode ? AnyView(SplitRootView(model: model)) : AnyView(AppSidebar(model: model))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: splitMode ? 1100 : 198, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        pump()
        host.layoutSubtreeIfNeeded()
        let mode = splitMode ? "split \(Int(sidebarWidth))pt" : "card"
        try check(NSApp.isActive && window.isKeyWindow, "\(mode): isolated window received native input focus")
        // Window coordinates are bottom-up; the action occupies the trailing 30×28pt of the footer.
        let shortcut = CGPoint(x: splitMode ? sidebarWidth - 33 : 169, y: splitMode ? 27 : 29)
        click(shortcut, in: window)
        try check(model.alert?.destructive == true && model.page == .editor && model.editorTitle == "Unsaved draft",
                  "\(mode): shortcut requests confirmation without navigating or discarding the draft")
        try check(try store.historyUsage().eventBytes == before, "\(mode): requesting clear does not delete history")
        model.alert = nil // Same dismissal as the root alert's Cancel button.
        try check(try store.historyUsage().eventBytes == before, "\(mode): cancel keeps history")
        click(CGPoint(x: shortcut.x + 12, y: shortcut.y), in: window)
        try check(model.alert != nil, "\(mode): shortcut remains available across its hit area after cancellation")
        guard let confirmation = model.alert else {
            throw NSError(domain: "SettingsShortcutVerification", code: 2)
        }
        model.alert = nil
        confirmation.action()
        try check(try store.session(id: "done-card") == nil && store.session(id: "done-temp") == nil,
                  "\(mode): confirming clears finished preset and terminal history")
        try check(try store.events(sessionId: "live") == [liveEvent], "\(mode): unfinished session output survives")
        try check(try store.cards() == keptCards && store.temps() == keptTemps, "\(mode): cards and terminals survive")
        try check(model.page == .editor && model.editorTitle == "Unsaved draft" && model.historyEntries.isEmpty,
                  "\(mode): clear refreshes history without leaving the editor")
        pump() // Usage is refreshed on the store queue, then published back on the main actor.
        try check(model.historyUsage.eventBytes == Int64(liveEvent.data.count) && model.notice == "历史记录已清理。",
                  "\(mode): usage and completion feedback are refreshed")
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        do {
            try verify(splitMode: false)
            for width in [240.0, 296.0, 460.0] { try verify(splitMode: true, sidebarWidth: width) }
            print("ALL SETTINGS SHORTCUT CHECKS PASSED")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }
}

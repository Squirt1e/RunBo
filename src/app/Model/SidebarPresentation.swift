import AppKit
import Combine
import SwiftUI
import Core
import class SwiftTerm.TerminalView

/// One window's ephemeral reveal state; only `mode` is persisted. No navigation or session actions.
@MainActor
final class SidebarPresentation: ObservableObject {
    @Published private(set) var mode: SidebarMode = .pinned
    @Published private(set) var peeking = false
    @Published private(set) var focusRequest: SidebarNode?
    @Published private(set) var focusToggleGeneration = 0
    @Published private(set) var inputSource: InputSource = .automatic
    private(set) var pointerInside = false
    private var focusOwners: Set<String> = []
    private var lastInput: InputSource = .automatic
    var keyboardInside: Bool { !focusOwners.isEmpty }
    private(set) var dragging = false
    private var menuDepth = 0
    private var hoverTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    var persist: ((SidebarMode) -> Bool)?
    var businessLock: (() -> Bool)?

    var expanded: Bool { mode == .pinned || peeking }
    var locked: Bool { dragging || menuDepth > 0 || businessLock?() == true }
    var animation: Animation? { inputSource.animation(entering: peeking) }

    func restore(_ mode: SidebarMode) {
        cancelTimers(); self.mode = mode; peeking = false; focusOwners = []; focusRequest = nil
    }

    @discardableResult
    func setMode(_ mode: SidebarMode, source: InputSource = .automatic) -> Bool {
        guard self.mode != mode else { return true }
        guard mode != .collapsed || !locked else { return false }
        guard persist?(mode) ?? true else { return false }
        cancelTimers(); inputSource = source
        let returnFocus = keyboardInside && mode == .collapsed && !(NSApp.keyWindow?.firstResponder is TerminalView)
        self.mode = mode; peeking = false; focusRequest = nil
        if mode == .collapsed { pointerInside = false; focusOwners = [] }
        if returnFocus { focusToggleGeneration += 1 }
        return true
    }

    func pointerChanged(_ inside: Bool) {
        guard pointerInside != inside else { return }
        pointerInside = inside
        if inside {
            leaveTask?.cancel()
            guard mode == .collapsed, !peeking else { return }
            hoverTask?.cancel()
            hoverTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(SidebarLayout.hoverDelay)) } catch { return }
                guard let self, self.pointerInside, self.mode == .collapsed, !self.locked else { return }
                self.inputSource = .pointer; self.peeking = true
            }
        } else { hoverTask?.cancel(); scheduleClose() }
    }

    func keyboardFocusChanged(_ inside: Bool, owner: String = "navigation") {
        if inside && (owner == "transfer" || lastInput != .pointer) { focusOwners.insert(owner) }
        else { focusOwners.remove(owner) }
        if keyboardInside {
            cancelTimers()
            if mode == .collapsed { inputSource = .keyboard; peeking = true }
        } else { scheduleClose() }
    }

    func focus(_ node: SidebarNode) {
        lastInput = .keyboard
        keyboardFocusChanged(true, owner: "transfer")
        focusRequest = node
    }

    func finishFocusTransfer(_ node: SidebarNode) {
        if focusRequest == node {
            focusRequest = nil
            keyboardFocusChanged(false, owner: "transfer")
        }
    }

    func headerFocusChanged(_ focused: Bool) {
        // Tab onto the compact toggle must not itself reveal the panel again after Escape.
        if expanded || !focused { keyboardFocusChanged(focused, owner: "header") }
    }

    @discardableResult
    func consumeEscape() -> Bool {
        guard mode == .collapsed, peeking, keyboardInside, !locked else { return false }
        cancelTimers(); inputSource = .keyboard; focusOwners = []; focusRequest = nil
        peeking = false; focusToggleGeneration += 1
        return true
    }

    func noteInput(_ source: InputSource) {
        lastInput = source
        if source == .pointer { focusOwners = []; focusRequest = nil }
    }

    func contentPressed() {
        hoverTask?.cancel()
        // Do not swallow the click. Let the actual target blur/commit a title before rechecking locks.
        focusOwners = []; focusRequest = nil
        guard mode == .collapsed, peeking, !locked else { scheduleClose(); return }
        inputSource = .pointer; peeking = false
    }

    func interactionChanged() {
        objectWillChange.send()
        if pointerInside, mode == .collapsed, !peeking, !locked {
            pointerInside = false; pointerChanged(true)
        } else { scheduleClose() }
    }
    func setDragging(_ value: Bool) { dragging = value; interactionChanged() }
    func menuTracking(_ begins: Bool) {
        menuDepth = max(0, menuDepth + (begins ? 1 : -1)); interactionChanged()
    }

    func windowInactive() {
        cancelTimers(); pointerInside = false; focusOwners = []; focusRequest = nil
        menuDepth = 0; dragging = false
        if !locked { inputSource = .automatic; peeking = false }
    }

    private func scheduleClose() {
        leaveTask?.cancel()
        guard mode == .collapsed, peeking, !pointerInside, !keyboardInside, !locked else { return }
        leaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(SidebarLayout.leaveDelay)) } catch { return }
            guard let self, !self.pointerInside, !self.keyboardInside, !self.locked, self.mode == .collapsed else { return }
            self.inputSource = .pointer; self.peeking = false
        }
    }

    private func cancelTimers() { hoverTask?.cancel(); leaveTask?.cancel() }
}

extension AppModel {
    /// Keep the original sidebar mounted through menus, rename, drag and farewell/reflow clocks.
    var sidebarInteractionLocked: Bool {
        alert != nil || quickNavigationPresented || tagPicker != nil || pendingDeletion != nil
        || renamingKey != nil || !vanishing.isEmpty || !removingCopies.isEmpty
        || !retainingCopies.isEmpty || copyReflowing
    }

    func toggleSidebar(source: InputSource? = nil) {
        if !sidebar.setMode(sidebar.mode == .pinned ? .collapsed : .pinned, source: source ?? .current), sidebar.locked {
            showNotice("请先完成当前编辑、菜单、拖动或确认，再折叠菜单栏。")
        }
    }
}

/// Window-local observation only: never consumes mouse input or changes first responder.
/// The representable covers just the currently visible sidebar, including a floating peek.
struct SidebarEventProbe: NSViewRepresentable {
    let presentation: SidebarPresentation
    func makeNSView(context: Context) -> Probe { Probe(presentation: presentation) }
    func updateNSView(_ view: Probe, context: Context) {}
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: NSView {
        let presentation: SidebarPresentation
        private var monitor: Any?
        init(presentation: SidebarPresentation) { self.presentation = presentation; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard let window else { return }
            window.acceptsMouseMovedEvents = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.type == .keyDown { self.presentation.noteInput(.keyboard); return event }
                let inside = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                if event.type == .leftMouseDown || event.type == .rightMouseDown { self.presentation.noteInput(.pointer) }
                self.presentation.pointerChanged(inside)
                if !inside, event.type == .leftMouseDown || event.type == .rightMouseDown {
                    self.presentation.contentPressed()
                }
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }
}

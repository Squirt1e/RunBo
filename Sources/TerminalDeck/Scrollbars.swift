import AppKit
import SwiftTerm
import SwiftUI

/// Logical pixels (AppKit points / CSS px), not backing pixels: 4pt is 8 pixels on Retina.
enum DeckScrollbarStyle {
    static let width: CGFloat = 4
    // The gutter is NOT the painted width. Transparent side insets keep panel
    // strokes/rounded clip masks away from the complete 4pt capsules.
    static let edgeInset: CGFloat = 2
    static let gutterWidth = width + edgeInset * 2
    static let endInset: CGFloat = 2
    static let minimumThumbLength: CGFloat = 24
    static let hideDelay: TimeInterval = 1.1

    /// WebKit paints its own scrollbars, not NSScroller. Apply the same capsule geometry
    /// to the static preview without enabling JavaScript or changing the source file.
    static let htmlStyle = """
    <style id="runbo-scrollbars">
    * { scrollbar-width: auto !important; scrollbar-color: auto !important; }
    *::-webkit-scrollbar { width: \(Int(gutterWidth))px !important; height: \(Int(gutterWidth))px !important; background: transparent !important; }
    *::-webkit-scrollbar-track { margin: \(Int(max(0, endInset - edgeInset)))px !important; border: \(Int(edgeInset))px solid transparent !important; border-radius: \(Int(gutterWidth / 2))px !important; background: color-mix(in srgb, currentColor 10%, transparent) !important; background-clip: padding-box !important; box-shadow: none !important; }
    *::-webkit-scrollbar-thumb { min-width: \(Int(minimumThumbLength))px !important; min-height: \(Int(minimumThumbLength))px !important; border: \(Int(edgeInset))px solid transparent !important; border-radius: \(Int(gutterWidth / 2))px !important; background: color-mix(in srgb, currentColor 50%, transparent) !important; background-clip: padding-box !important; box-shadow: none !important; }
    *::-webkit-scrollbar-button { display: none !important; }
    *::-webkit-scrollbar-corner { background: transparent !important; }
    </style>
    """
}

/// AppKit owns scrolling, paging and dragging; this class alone owns the pixels and
/// auto-hide. Never opt into NSScroller's system layer renderer: its metrics and masks
/// are wider than 4pt, and `draw(_:)` is bypassed on layer-backed SwiftUI scroll views.
final class DeckScroller: NSScroller {
    static let width = DeckScrollbarStyle.width
    static let gutterWidth = DeckScrollbarStyle.gutterWidth

    override var doubleValue: Double {
        didSet { needsDisplay = true }
    }

    override var knobProportion: CGFloat {
        didSet { needsDisplay = true }
    }

    private var contentObserver: NSObjectProtocol?
    private var revealWorkItem: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?
    private var hovering = false
    private var dragging = false
    private var revealed = false

    // Both are necessary: opting out of overlay metrics does not opt out of the
    // layer-backed system drawing path. A 4pt frame alone produces a clipped hairline.
    override class var isCompatibleWithOverlayScrollers: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    override var scrollerStyle: NSScroller.Style {
        get { .legacy }
        set { if super.scrollerStyle != .legacy { super.scrollerStyle = .legacy } }
    }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                     scrollerStyle: NSScroller.Style) -> CGFloat {
        gutterWidth
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        alphaValue = 0
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        alphaValue = 0
    }

    deinit {
        if let contentObserver { NotificationCenter.default.removeObserver(contentObserver) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeContent()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeContent()
        if window == nil { hideNow() } else { refreshVisibility() }
    }

    /// The terminal owns its scroller outside an NSScrollView; managed scroll views
    /// report scrolling through their clip view so the thumb can appear on demand.
    private func observeContent() {
        if let contentObserver {
            NotificationCenter.default.removeObserver(contentObserver)
            self.contentObserver = nil
        }
        guard let scrollView = superview as? NSScrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        contentObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.reveal()
        }
    }

    private var isVertical: Bool { bounds.height >= bounds.width }

    override func rect(for part: NSScroller.Part) -> NSRect {
        // Do not use super.rect: AppKit's overlay metrics assume a wider system
        // scroller. Own the complete track and thumb geometry in both directions.
        let inset = DeckScrollbarStyle.endInset
        var slot = bounds.insetBy(dx: isVertical ? 0 : inset, dy: isVertical ? inset : 0)
        guard !slot.isEmpty else { return .zero }
        if isVertical {
            slot.size.width = min(Self.width, slot.width)
            slot.origin.x = bounds.midX - slot.width / 2
        } else {
            slot.size.height = min(Self.width, slot.height)
            slot.origin.y = bounds.midY - slot.height / 2
        }
        if part == .knobSlot { return slot }

        let length = isVertical ? slot.height : slot.width
        let thumbLength = min(length, max(DeckScrollbarStyle.minimumThumbLength, length * min(1, max(0, knobProportion))))
        let position = CGFloat(min(1, max(0, doubleValue)))
        let offset = (length - thumbLength) * (isVertical && !isFlipped ? 1 - position : position)
        var thumb = slot
        if isVertical {
            thumb.origin.y += offset
            thumb.size.height = thumbLength
        } else {
            thumb.origin.x += offset
            thumb.size.width = thumbLength
        }
        if part == .knob { return thumb }

        // Native hit testing and page clicks must use the same custom geometry.
        guard part == .decrementPage || part == .incrementPage else { return .zero }
        var page = slot
        let fromMin = (part == .decrementPage) == (!isVertical || isFlipped)
        if isVertical {
            page.origin.y = fromMin ? slot.minY : thumb.maxY
            page.size.height = fromMin ? thumb.minY - slot.minY : slot.maxY - thumb.maxY
        } else {
            page.origin.x = fromMin ? slot.minX : thumb.maxX
            page.size.width = fromMin ? thumb.minX - slot.minX : slot.maxX - thumb.maxX
        }
        return page
    }

    override func testPart(_ point: NSPoint) -> NSScroller.Part {
        let localPoint = convert(point, from: nil)
        guard bounds.contains(localPoint) else { return .noPart }
        for part in [NSScroller.Part.knob, .decrementPage, .incrementPage] {
            if rect(for: part).contains(localPoint) { return part }
        }
        return .noPart
    }

    private var isVisible: Bool { revealed }

    override func draw(_ dirtyRect: NSRect) {
        // Draw complete paths; the graphics context already clips the invalidated area.
        // Intersecting a path with dirtyRect first would manufacture square end caps.
        drawKnobSlot(in: rect(for: .knobSlot), highlight: false)
        drawKnob()
    }

    private var ink: NSColor {
        switch knobStyle {
        case .light: return .white // The terminal/image backdrop is always dark.
        case .dark: return .black
        default:
            return effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
        }
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        fillCapsule(rect(for: .knobSlot), opacity: 0.1)
    }

    override func drawKnob() {
        fillCapsule(rect(for: .knob), opacity: 0.5)
    }

    private func fillCapsule(_ rect: NSRect, opacity: CGFloat) {
        guard isEnabled, isVisible, !rect.isEmpty else { return }
        ink.withAlphaComponent(opacity).setFill()
        let radius = min(rect.width, rect.height) / 2
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        reveal()
        defer { dragging = false; scheduleHide() }
        super.mouseDown(with: event)
    }

    /// An auto-hidden scroller must not swallow clicks in the transparent gutter.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isVisible ? super.hitTest(point) : nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Never trap the wheel in the transparent gutter.
        if let scrollView = superview as? NSScrollView {
            scrollView.scrollWheel(with: event)
        } else if let nextResponder {
            nextResponder.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func layout() {
        super.layout()
        if !isEnabled { hideNow() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        reveal()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        scheduleHide()
    }

    func reveal() {
        guard isEnabled else { return }
        isHidden = false
        revealWorkItem?.cancel()
        revealWorkItem = nil
        if !revealed {
            revealed = true
            needsDisplay = true
        }
        alphaValue = 1
        scheduleHide()
    }

    func hideNow() {
        revealWorkItem?.cancel()
        revealWorkItem = nil
        guard revealed || alphaValue != 0 else { return }
        revealed = false
        alphaValue = 0
        needsDisplay = true
    }

    func refreshVisibility() {
        if !isEnabled {
            hideNow()
        } else if hovering {
            reveal()
        }
    }

    private func scheduleHide() {
        revealWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.hovering, !self.dragging else { return }
            self.hideNow()
        }
        revealWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + DeckScrollbarStyle.hideDelay, execute: item)
    }

    static func install(in scrollView: NSScrollView) {
        var installed: [DeckScroller] = []
        if scrollView.hasVerticalScroller, !(scrollView.verticalScroller is DeckScroller) {
            let scroller = DeckScroller(frame: NSRect(x: 0, y: 0, width: gutterWidth, height: 100))
            scrollView.verticalScroller = scroller
            installed.append(scroller)
        }
        if scrollView.hasHorizontalScroller, !(scrollView.horizontalScroller is DeckScroller) {
            let scroller = DeckScroller(frame: NSRect(x: 0, y: 0, width: 100, height: gutterWidth))
            scrollView.horizontalScroller = scroller
            installed.append(scroller)
        }
        guard !installed.isEmpty else { return }
        for scroller in installed {
            scroller.knobStyle = .default
        }
        scrollView.tile()
        installed.forEach { $0.refreshVisibility() }
    }
}

/// Place inside SwiftUI scroll content to configure its enclosing native scroll view.
private struct DeckScrollbarProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.configureLater() }

    final class ProbeView: NSView {
        private var pending = false
        private weak var observedScrollView: NSScrollView?
        private var observations: [NSKeyValueObservation] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureLater()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureLater()
        }

        override func layout() {
            super.layout()
            configureLater()
        }

        func configureLater() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                // The modifier belongs on scroll CONTENT. Never guess a nearby scroll
                // view by intersecting frames from different coordinate systems: that
                // can style the file tree instead of the sidebar (or an outer editor).
                guard let scrollView = self.enclosingScrollView else {
                    self.observations = []
                    self.observedScrollView = nil
                    return
                }
                if self.observedScrollView !== scrollView {
                    self.observedScrollView = scrollView
                    // SwiftUI may enable or replace an indicator AFTER mounting the
                    // probe, including when a short document first becomes scrollable.
                    self.observations = [
                        scrollView.observe(\.hasVerticalScroller) { [weak self] _, _ in self?.configureLater() },
                        scrollView.observe(\.hasHorizontalScroller) { [weak self] _, _ in self?.configureLater() },
                        scrollView.observe(\.verticalScroller) { [weak self] _, _ in self?.configureLater() },
                        scrollView.observe(\.horizontalScroller) { [weak self] _, _ in self?.configureLater() },
                    ]
                }
                DeckScroller.install(in: scrollView)
            }
        }
    }
}

extension View {
    /// Attach to the content inside ScrollView, not to ScrollView or ScrollViewReader.
    func deckScrollbars() -> some View {
        background(DeckScrollbarProbe())
    }
}

/// SwiftTerm's private scroller uses fixed system metrics. Keep its terminal intact
/// and place the same 4pt painted capsules beside it with transparent safety insets.
final class TerminalScrollContainer: NSView {
    let terminal: TerminalView
    let scroller = DeckScroller(frame: NSRect(x: 0, y: 0, width: DeckScroller.gutterWidth, height: 100))
    private var scrollMonitor: Any?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.frame)
        // On macOS 14+, NSView does not clip by default. Keep this container's
        // background and subviews from painting over the SwiftUI panel title bar.
        clipsToBounds = true
        terminal.clipsToBounds = true
        terminal.subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = true }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.knobStyle = .light
        scroller.target = self
        scroller.action = #selector(scrollTerminal)
        addSubview(terminal)
        addSubview(scroller)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminal.trailingAnchor.constraint(equalTo: scroller.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroller.widthAnchor.constraint(equalToConstant: DeckScroller.gutterWidth),
        ])
        syncScroller()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor); self.scrollMonitor = nil }
        guard window != nil else { return }
        // SwiftTerm owns scrollWheel on its non-open TerminalView, so observe the
        // window-local event without consuming it; the terminal still scrolls normally.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point), !self.isHiddenOrHasHiddenAncestor {
                self.flashScroller()
            }
            return event
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        terminal.nativeBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func scrollWheel(with event: NSEvent) {
        // The hidden overlay scroller lets wheel events fall through to this gutter;
        // keep scrolling the terminal when the pointer is over the narrow edge.
        flashScroller()
        terminal.scrollWheel(with: event)
    }

    override func layout() {
        super.layout()
        fitTerminalToViewport()
        syncScroller()
    }

    /// Replay resize events describe the recorded screen, not the visible viewport. Ask
    /// SwiftTerm to recompute its grid from its actual frame after replay or remounting.
    /// The setter only notifies a live PTY when the calculated rows/columns really change.
    func fitTerminalToViewport() {
        guard window != nil, terminal.bounds.width > 0, terminal.bounds.height > 0 else { return }
        terminal.setFrameSize(terminal.frame.size)
    }

    func syncScroller() {
        let scrollable = terminal.canScroll
        scroller.isEnabled = scrollable
        scroller.knobProportion = terminal.scrollThumbsize
        scroller.doubleValue = terminal.scrollPosition
        if scrollable {
            scroller.refreshVisibility()
        } else {
            scroller.hideNow()
        }
    }

    /// Reveal the thumb while the pointer is over the terminal and it is scrolling,
    /// then let `DeckScroller` hide it instead of leaving a permanent 4pt bar.
    func flashScroller() {
        syncScroller()
        guard terminal.canScroll else { return }
        scroller.reveal()
    }

    @objc private func scrollTerminal() {
        switch scroller.hitPart {
        case .knob:
            terminal.scroll(toPosition: scroller.doubleValue)
        case .decrementPage:
            terminal.scrollUp(lines: terminal.getTerminal().rows)
        case .incrementPage:
            terminal.scrollDown(lines: terminal.getTerminal().rows)
        default:
            break
        }
        flashScroller()
    }
}

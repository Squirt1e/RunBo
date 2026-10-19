import AppKit
import SwiftUI
import Core

/// The entire preview is local to the sidebar. Nothing is written until mouse-up.
struct CardDrag {
    let token = UUID()
    let card: PresetCard
    let originFrame: CGRect
    let grabOffset: CGPoint
    var location: CGPoint
    var destination: CardDropDestination
    var valid = true
    var dropping = false
    var landingPending = false

    var offset: CGPoint {
        CGPoint(x: location.x - grabOffset.x, y: location.y - grabOffset.y)
    }
}

/// The divider must not push its resize cursor on top of the drag's closed-hand cursor.
struct CardDraggingKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct CardDropFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
    static func header(_ id: String) -> String { "header:" + id }
    static func row(_ id: String) -> String { "row:" + id }
    static let placeholder = "placeholder"
}

extension View {
    func cardDropFrame(_ id: String, coordinateSpace: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: CardDropFrameKey.self,
                                       value: [id: proxy.frame(in: .named(coordinateSpace))])
            }
        }
    }
}

/// Once lifted, track the mouse at the viewport, not at the source row. That row can change
/// groups, disappear from a lazy stack, or scroll offscreen without cancelling the drag.
/// The transparent view never intercepts clicks, buttons, context menus or scrolling.
struct DragCapture: NSViewRepresentable {
    var active: Bool
    var onPress: (CGPoint) -> Void
    var onMove: (CGPoint, CGSize) -> Void
    var onEnd: (CGPoint, CGSize) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.installMonitor()
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.active = active
        view.onPress = onPress
        view.onMove = onMove
        view.onEnd = onEnd
        view.onCancel = onCancel
    }

    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.removeMonitor() }

    final class CaptureView: NSView {
        var active = false
        var onPress: ((CGPoint) -> Void)?
        var onMove: ((CGPoint, CGSize) -> Void)?
        var onEnd: ((CGPoint, CGSize) -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                guard let self, let window = self.window else { return event }
                if event.type == .leftMouseDown, event.window === window {
                    self.onPress?(self.convert(event.locationInWindow, from: nil))
                    return event
                }
                guard self.active else { return event }
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return event }
                    self.onCancel?()
                    return nil
                }
                guard event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if event.type == .leftMouseUp {
                    self.onEnd?(point, self.bounds.size)
                } else {
                    self.onMove?(point, self.bounds.size)
                }
                // Let the original long-press recognizer receive mouse-up and reset.
                return event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}

/// Native, incremental edge scrolling keeps the lifted card under the pointer. A scrollTo
/// animation would fight direct pointer tracking and jump a whole row at a time.
final class DragScrollDriver {
    weak var scrollView: NSScrollView?

    @discardableResult
    func scroll(at point: CGPoint, viewport: CGSize) -> Bool {
        guard point.x >= 0, point.x <= viewport.width, point.y >= 0, point.y <= viewport.height,
              let scrollView, let document = scrollView.documentView else { return false }
        let edge: CGFloat = 36
        let step: CGFloat
        if point.y < edge {
            step = -10 * (1 - point.y / edge)
        } else if point.y > viewport.height - edge {
            step = 10 * (1 - (viewport.height - point.y) / edge)
        } else {
            return false
        }
        let clip = scrollView.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        let y = min(max(clip.bounds.minY + step, 0), maximum)
        guard abs(y - clip.bounds.minY) > 0.1 else { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
        return true
    }
}

struct DragScrollProbe: NSViewRepresentable {
    let driver: DragScrollDriver
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.driver = driver
        view.resolveLater()
    }

    final class Probe: NSView {
        weak var driver: DragScrollDriver?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveLater()
        }
        func resolveLater() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.driver?.scrollView = self.enclosingScrollView
            }
        }
    }
}

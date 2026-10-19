import AppKit
import QuartzCore
import SwiftUI
import Core

/// The approved rail material. Status colours deliberately do not tint the group containers or initials.
enum SidebarRailTheme {
    static let group = Theme.adaptive(light: 0xE7EAE2, dark: 0x2A302A)
    static let groupLine = Theme.adaptive(light: 0xCDD5C5, dark: 0x47533F)
    static let tile = Theme.adaptive(light: 0xFAFBF7, dark: 0x202622)
    static let idle = Theme.adaptive(light: 0xADB7A6, dark: 0x75846B)
    static let selected = Theme.adaptive(light: 0xD9DFD2, dark: 0x434D3D)
    static let orbitBase = Theme.adaptive(light: 0xBEA076, dark: 0x80643F)
}

struct SidebarRailTile: View {
    let monogram: String
    let kind: StatusDot
    var motionEnabled = true
    /// Injectable for isolated rendering; nil always follows the real system preference.
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    private var border: SidebarRailBorder { .init(kind) }
    private var colour: Color {
        switch kind {
        case .executing: return reduceMotion ? Theme.accent : SidebarRailTheme.orbitBase
        case .live, .liveBusy: return SplitTheme.green
        case .failed, .unresponsive: return SplitTheme.red
        case .starting: return Theme.accent
        case .idle: return SidebarRailTheme.idle
        }
    }

    var body: some View {
        Text(monogram)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.text)
            .frame(width: SidebarLayout.tileSize, height: SidebarLayout.tileSize)
            .background(SidebarRailTheme.tile, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(colour, style: StrokeStyle(lineWidth: border.lineWidth, dash: border.isDashed ? [3, 2] : []))
            }
            .overlay {
                if border.showsRunningLight {
                    SidebarBorderLight(lineWidth: border.lineWidth, dark: colorScheme == .dark,
                                       enabled: motionEnabled && !reduceMotion)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) { mark }
            .accessibilityHidden(true) // The owning button supplies the real title and precise state.
    }

    @ViewBuilder private var mark: some View {
        switch kind {
        case .executing:
            Image(systemName: "play.fill").font(.system(size: 5))
                .foregroundStyle(Theme.accent).padding(3)
        case .liveBusy:
            Circle().fill(SplitTheme.green).frame(width: 4, height: 4).padding(3)
        case .idle: EmptyView()
        default:
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(SidebarRailTheme.tile)
                switch kind {
                case .live: Circle().fill(SplitTheme.green).frame(width: 4, height: 4)
                case .starting:
                    Circle().trim(from: 0.12, to: 0.88).stroke(Theme.accent, lineWidth: 1)
                        .frame(width: 6, height: 6)
                default:
                    Text("!").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(SplitTheme.red)
                }
            }
            .frame(width: 10, height: 10).offset(x: 2, y: 2)
        }
    }
}

struct SidebarBorderLight: NSViewRepresentable {
    let lineWidth: CGFloat
    let dark: Bool
    let enabled: Bool
    func makeNSView(context: Context) -> SidebarBorderLightView { SidebarBorderLightView(frame: .zero) }
    func updateNSView(_ view: SidebarBorderLightView, context: Context) {
        view.configure(lineWidth: lineWidth, dark: dark, enabled: enabled)
    }
    static func dismantleNSView(_ view: SidebarBorderLightView, coordinator: ()) { view.stop() }
}

/// A compositor-only rotation inside a stationary rounded ring. No TimelineView, display link,
/// model publication, terminal layout or per-frame SwiftUI work. The view never receives input.
final class SidebarBorderLightView: NSView {
    static let animationKey = "sidebar.clockwise-border"
    let lightLayer = CAGradientLayer()
    let ringLayer = CAShapeLayer()
    private let clippedLayer = CALayer()
    private var observers: [NSObjectProtocol] = []
    private(set) var motionEnabled = false
    private(set) var lineWidth: CGFloat = 2
    private var dark: Bool?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        // Positive Z rotation in this explicitly y-down coordinate system is clockwise.
        layer?.isGeometryFlipped = true
        layer?.addSublayer(clippedLayer)
        clippedLayer.mask = ringLayer
        clippedLayer.addSublayer(lightLayer)
        ringLayer.fillColor = nil
        ringLayer.strokeColor = NSColor.white.cgColor
        lightLayer.type = .conic
        lightLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        lightLayer.endPoint = CGPoint(x: 0.5, y: 0)
        let degrees: [Double] = [0, 244, 266, 312, 345, 356, 360]
        lightLayer.locations = degrees.map { NSNumber(value: $0 / 360) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(lineWidth: CGFloat, dark: Bool, enabled: Bool) {
        self.lineWidth = lineWidth
        motionEnabled = enabled
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if self.dark != dark {
            self.dark = dark
            let tail = NSColor(hex: dark ? 0xCF9B4D : 0xBE813B).withAlphaComponent(dark ? 0.08 : 0.09)
            lightLayer.colors = [NSColor.clear, .clear, tail,
                                 NSColor(hex: dark ? 0xD39A51 : 0xD49A4C),
                                 NSColor(hex: dark ? 0xF3C77F : 0x9D541A),
                                 NSColor(hex: dark ? 0xFFF1C9 : 0xFFE4A3), .clear].map(\.cgColor)
        }
        clippedLayer.isHidden = !enabled
        CATransaction.commit()
        needsLayout = true
        refreshVisibility()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clippedLayer.frame = bounds
        ringLayer.frame = bounds
        ringLayer.lineWidth = lineWidth
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        ringLayer.path = CGPath(roundedRect: rect, cornerWidth: max(0, 7 - lineWidth / 2),
                                cornerHeight: max(0, 7 - lineWidth / 2), transform: nil)
        lightLayer.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.width * 2.2, height: bounds.height * 2.2))
        lightLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let scale = window?.backingScaleFactor ?? 2
        [layer, clippedLayer, ringLayer, lightLayer].forEach { $0?.contentsScale = scale }
        CATransaction.commit()
        refreshVisibility()
    }

    static func clockwiseAnimation() -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = Double.pi * 2
        animation.duration = SidebarRailBorder.orbitDuration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        return animation
    }

    /// Visibility is separate from state so changing selection never restarts a running orbit.
    func updateAnimation(visible: Bool) {
        guard motionEnabled, visible, bounds.width > 0, bounds.height > 0 else {
            lightLayer.removeAnimation(forKey: Self.animationKey)
            return
        }
        if lightLayer.animation(forKey: Self.animationKey) == nil {
            lightLayer.add(Self.clockwiseAnimation(), forKey: Self.animationKey)
        }
    }

    private func refreshVisibility() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        // On macOS 14+ an unclipped NSView's visibleRect may lie wholly outside its bounds.
        // Test intersection, not merely non-emptiness, when a tile scrolls offscreen.
        updateAnimation(visible: visible && !isHiddenOrHasHiddenAncestor && visibleRect.intersects(bounds))
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeVisibility() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeVisibility() }
    override func viewDidHide() { super.viewDidHide(); refreshVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); refreshVisibility() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }

    private func observeVisibility() {
        removeObservers()
        guard let window else { refreshVisibility(); return }
        let centre = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didResizeNotification] {
            observers.append(centre.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.refreshVisibility() })
        }
        var ancestor = superview
        while let view = ancestor {
            view.postsBoundsChangedNotifications = true
            view.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(centre.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in self?.refreshVisibility() })
            }
            ancestor = view.superview
        }
        refreshVisibility()
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    func stop() { motionEnabled = false; updateAnimation(visible: false); removeObservers() }
    deinit { removeObservers() }
}

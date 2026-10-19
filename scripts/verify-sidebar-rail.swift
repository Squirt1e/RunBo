import AppKit
import QuartzCore
import SwiftUI
import TerminalDeckKit
@testable import TerminalDeck

/// Never orders a window on screen, activates this process, or sends/posts an input event.
@main struct VerifySidebarRail {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw NSError(domain: "SidebarRail", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        count += 1; print("PASS \(label)"); fflush(stdout)
    }
    @MainActor static func pump(_ seconds: Double = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    @MainActor static func wait(_ label: String, _ condition: () -> Bool) throws {
        let end = Date().addingTimeInterval(12)
        while !condition() && Date() < end { pump(0.02) }
        try check(condition(), label)
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func hiddenWindow<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        return (window, host)
    }
    @MainActor static func fixture(_ root: URL) throws -> AppModel {
        let store = try TerminalDeckStore(directory: root)
        for (index, name) in ["Pi", "Clash", "Scripts 很长的分组名称 🚀", "Empty"].enumerated() {
            try store.save(CardTag(id: "tag-\(index)", name: name, sortOrder: index))
        }
        for (id, title, tag) in [("la", "Learning Agent", "tag-0"), ("td", "Terminal Dashboard", "tag-0"),
                                  ("wt", "Web Tool", "tag-0"), ("au", "Agents Usage", "tag-0"),
                                  ("fa", "Fix AI Clash", "tag-1"), ("ca", "Change AI Clash", "tag-1"),
                                  ("sp", "Start Pi Web", "tag-2"), ("sd", "Start Dsh Web", "tag-2")] {
            try store.save(PresetCard(id: id, title: title, command: "printf RAIL_READY; /bin/sleep 60", workingDirectory: root.path, tagId: tag))
        }
        try store.save(PresetCard(id: "untagged", title: "未加标签示例", command: "true", workingDirectory: root.path))
        try store.save(TempTerminal(id: "terminal", title: "终端 12"))
        let model = AppModel(store: store)
        model.engine.baseEnvironment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
        model.enterWorkhorseMode()
        _ = model.sidebar.setMode(.collapsed, source: .keyboard)
        return model
    }
    @MainActor static func grouping(_ model: AppModel) throws {
        let groups = model.sidebarRailPresetGroups
        try check(groups.map(\.title) == ["Pi", "Clash", "Scripts 很长的分组名称 🚀", "未加标签"], "named groups follow real tag order, include untagged, omit empty tags")
        try check(groups.flatMap(\.owners) == model.sidebarNavigationNodes.compactMap(\.owner).filter { $0.kind == .preset }, "rail groups preserve exactly the original visible project order")
        try check(model.sidebarRailTerminals == [OwnerKey(kind: .temp, ownerId: "terminal")], "terminal owners remain under their own menu")
        model.toggleTagCollapsed("tag-0")
        try check(model.sidebarRailPresetGroups.first?.title == "Pi" && model.sidebarRailPresetGroups.first?.owners.isEmpty == true, "collapsed tags retain a named container but no hidden owners")
        model.toggleTagCollapsed("tag-0")
        model.toggleUntaggedBucketCollapsed()
        try check(model.sidebarRailPresetGroups.last?.title == "未加标签" && model.sidebarRailPresetGroups.last?.owners.isEmpty == true, "untagged bucket keeps existing collapsed semantics")
        model.toggleUntaggedBucketCollapsed()
        model.activateSidebarNode(.menu(.preset))
        try check(model.sidebarRailPresetGroups.isEmpty && !model.sidebarRailTerminals.isEmpty, "collapsed command menu does not resurrect tag containers")
        model.activateSidebarNode(.menu(.preset))
        model.activateSidebarNode(.menu(.temp))
        try check(model.sidebarRailTerminals.isEmpty && !model.sidebarRailPresetGroups.isEmpty, "terminal menu collapse is independent from command groups")
        model.activateSidebarNode(.menu(.temp))
        let key = OwnerKey(kind: .preset, ownerId: "fa")
        model.workhorseSelect(key)
        try check(model.workhorseSelection == key && model.liveRuntime(key) == nil, "selecting a rail owner opens detail without executing a command")
    }

    @MainActor static func layerChecks() throws {
        let light = SidebarBorderLightView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        light.configure(lineWidth: 2, dark: false, enabled: true); light.layoutSubtreeIfNeeded()
        try check(light.hitTest(CGPoint(x: 16, y: 16)) == nil && !light.acceptsFirstResponder, "light layer never intercepts pointer or keyboard input")
        try check(light.layer?.isGeometryFlipped == true, "explicit y-down layer geometry makes positive rotation clockwise")
        try check(light.lightLayer.animationKeys() == nil, "a detached / hidden window never starts a display animation")
        try check(light.ringLayer.lineWidth == 2 && light.ringLayer.fillColor == nil, "fixed rounded ring only masks the 2pt border, not the text")
        let animation = SidebarBorderLightView.clockwiseAnimation()
        try check(animation.keyPath == "transform.rotation.z" && (animation.fromValue as? Double) == 0
                  && abs((animation.toValue as? Double ?? 0) - Double.pi * 2) < 0.0001, "compositor orbit is exactly one clockwise revolution")
        try check(animation.duration == 2.4 && animation.repeatCount.isInfinite, "orbit duration is 2.4 seconds and repeats seamlessly")
        try check(animation.timingFunction == CAMediaTimingFunction(name: .linear), "constant angular speed uses linear timing")
        light.updateAnimation(visible: true)
        try check(light.lightLayer.animationKeys() == [SidebarBorderLightView.animationKey], "a visible executing tile gets one compositor animation")
        let first = light.lightLayer.animation(forKey: SidebarBorderLightView.animationKey)!
        light.updateAnimation(visible: true)
        try check(light.lightLayer.animationKeys()?.count == 1 && light.lightLayer.animation(forKey: SidebarBorderLightView.animationKey)?.beginTime == first.beginTime,
                  "selection / unrelated refreshes do not accumulate or restart orbits")
        light.updateAnimation(visible: false)
        try check(light.lightLayer.animationKeys() == nil, "scrolling out, occlusion and minimization stop compositor work")
        for dark in [false, true] {
            light.configure(lineWidth: 2, dark: dark, enabled: true); light.layoutSubtreeIfNeeded()
            try check(light.lightLayer.colors?.count == 7 && light.lightLayer.locations?.count == 7, "\(dark ? "dark" : "light") gradient has a bright leading tip and a fading tail")
        }
        light.configure(lineWidth: 1.5, dark: true, enabled: true); light.layoutSubtreeIfNeeded()
        try check(light.ringLayer.lineWidth == 1.5, "online-and-busy uses the existing 1.5pt green base geometry")
        light.configure(lineWidth: 2, dark: false, enabled: false); light.updateAnimation(visible: true)
        try check(light.lightLayer.animationKeys() == nil, "reduced motion / expanded rail cannot restart an orbit")
        light.stop()
        try check(!light.motionEnabled && light.lightLayer.animationKeys() == nil, "dismantling removes animation work")
    }

    @MainActor static func snapshot<V: View>(_ name: String, _ host: NSHostingView<V>) throws {
        guard let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try capture(host)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Snapshot", code: 1) }
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        if name == "rail-light" || name == "rail-dark" {
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let rect = CGRect(x: 0, y: 0, width: WorkbenchSidebarLayout.railWidth * scale, height: CGFloat(bitmap.pixelsHigh))
            if let image = bitmap.cgImage?.cropping(to: rect),
               let crop = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try crop.write(to: directory.appendingPathComponent(name + "-detail.png"))
            }
        }
        print("OFFSCREEN_SNAPSHOT \(name)")
    }

    @MainActor static func capture<V: View>(_ host: NSHostingView<V>) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "Snapshot", code: 1) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    @MainActor static func orbitPixels() throws {
        let tile = SidebarRailTile(monogram: "TD", kind: .executing, reduceMotionOverride: false).environment(\.colorScheme, .dark)
        let (window, host) = hiddenWindow(tile, size: CGSize(width: 32, height: 32))
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded(); pump(0.1)
        guard let light = descendants(host).compactMap({ $0 as? SidebarBorderLightView }).first else { throw NSError(domain: "MissingLight", code: 1) }
        light.lightLayer.isHidden = true
        let baseline = try capture(host)
        light.lightLayer.isHidden = false
        var vectors: [CGPoint] = []
        for quarter in 0..<4 {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            light.lightLayer.transform = CATransform3DMakeRotation(CGFloat(quarter) * .pi / 2, 0, 0, 1)
            CATransaction.commit()
            let image = try capture(host)
            var sum = 0.0, dx = 0.0, dy = 0.0
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    let before = baseline.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    let after = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    let delta = max(0, Double(after.greenComponent - before.greenComponent))
                    let weight = delta * delta * delta
                    sum += weight; dx += weight * (Double(x) - Double(image.pixelsWide) / 2)
                    dy += weight * (Double(y) - Double(image.pixelsHigh) / 2)
                }
            }
            try check(sum > 0.01, "native orbit quarter \(quarter) has a visible gradient tip")
            vectors.append(CGPoint(x: dx / sum, y: dy / sum))
            let centre = image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)!
            try check(centre == baseline.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2), "moving light never paints over the tile centre or text")
            try snapshot("orbit-quarter-\(quarter)", host)
        }
        for index in 0..<4 {
            let a = vectors[index], b = vectors[(index + 1) % 4]
            try check(a.x * b.y - a.y * b.x > 0, "rasterized native light moves clockwise through quarter \(index) → \((index + 1) % 4): \(a) → \(b)")
        }
        try check(!window.isVisible && !NSApp.isActive, "pixel-level motion verification stays offscreen")
        window.contentView = nil
    }

    @MainActor static func statusViews() throws {
        for dark in [false, true] {
            for reduceMotion in [false, true] {
                let study = VStack(spacing: 16) {
                    ForEach(WorkhorseStatusDot.allCases, id: \.self) { kind in
                        HStack(spacing: 20) {
                            SidebarRailTile(monogram: "AB", kind: kind, reduceMotionOverride: reduceMotion)
                            Text(kind.rawValue).font(.system(size: 12, design: .monospaced))
                        }.frame(width: 280, alignment: .leading)
                    }
                }
                .padding(24).frame(width: 340, height: 390).background(DeckTheme.background)
                .environment(\.colorScheme, dark ? .dark : .light)
                let (window, host) = hiddenWindow(study, size: CGSize(width: 340, height: 390))
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded(); pump(0.15)
                let lights = descendants(host).compactMap { $0 as? SidebarBorderLightView }
                try check(lights.count == 2, "\(dark ? "dark" : "light") / reduce=\(reduceMotion): only executing and online-busy mount a light")
                try check(lights.allSatisfy { $0.motionEnabled == !reduceMotion && $0.lightLayer.animationKeys() == nil }, "\(dark ? "dark" : "light") / reduce=\(reduceMotion): system motion preference is wired to native layers")
                let correctSize = lights.allSatisfy { view in view.bounds.size == CGSize(width: 32, height: 32) }
                try check(correctSize, "gradient overlays stay inside the 32pt tile")
                try snapshot("states-\(dark ? "dark" : "light")-\(reduceMotion ? "reduced" : "motion")", host)
                try check(!window.isVisible && !window.isKeyWindow && !NSApp.isActive, "status render stays invisible and never owns desktop input")
                window.contentView = nil
            }
        }
    }

    @MainActor static func nativeLayout(_ model: AppModel) throws {
        let key = OwnerKey(kind: .preset, ownerId: "td")
        model.startCard(model.card(for: key.ownerId)!)
        defer { model.engine.endAllSessions(timeout: 1) }
        try wait("isolated fixture has a real ready PTY") { model.liveRuntime(key)?.isReachable == true }
        let session = model.liveRuntime(key)!.sessionId
        let scene = model.liveScene(sessionId: session)
        model.page = .detail(key)
        var frames: [String: CGRect] = [:]
        let root = DeckRootView(model: model).onPreferenceChange(WorkbenchControlFrameKey.self) { frames = $0 }
            .transaction { $0.disablesAnimations = true }
        let (window, host) = hiddenWindow(root, size: CGSize(width: 1100, height: 860))
        window.appearance = NSAppearance(named: .aqua)
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded(); pump(0.5)
        try check(!window.isVisible && !window.isKeyWindow && !NSApp.isActive, "full native workbench stays offscreen and non-active")
        try check(frames["sidebar-panel"]?.width == 56 && frames["workbench-content"]?.minX == 56, "rail and real terminal retain exactly 56pt allocation")
        try snapshot("rail-light", host)
        if let first = frames["rail-group-tag-0"], first.minX < 0 {
            print("LAYOUT_DIAGNOSTIC", frames.filter { $0.key.hasPrefix("rail-") })
            for view in descendants(host) {
                let rect = view.convert(view.bounds, to: host)
                if view is NSScrollView || view is NSClipView || (rect.width < 90 && rect.maxX < 90) {
                    print("VIEW_DIAGNOSTIC", type(of: view), "frame", rect, "bounds", view.bounds, "enclosing", String(describing: view.enclosingScrollView))
                }
            }
        }
        for group in model.sidebarRailPresetGroups {
            guard let rect = frames["rail-group-" + group.id] else { throw NSError(domain: "MissingRailGroup", code: 1, userInfo: [NSLocalizedDescriptionKey: group.title]) }
            try check(abs(rect.width - 44) < 1 && rect.minX >= 0 && rect.maxX <= 56, "named group fits 56pt rail: \(group.title) \(rect)")
            for owner in group.owners {
                guard let row = frames["rail-owner-" + owner.ownerId] else { throw NSError(domain: "MissingOwner", code: 1) }
                try check(row.width == 40 && row.height == 44 && row.minX >= rect.minX && row.maxX <= rect.maxX,
                          "grouped owner retains a 40×44pt hit target: \(owner.ownerId)")
            }
        }
        try check(frames["rail-sidebar-menu-preset"] != nil && frames["rail-sidebar-menu-temp"] != nil && frames["rail-sidebar-settings"] != nil,
                  "command, terminal and settings entry points remain present")
        window.appearance = NSAppearance(named: .darkAqua); pump(0.2)
        try snapshot("rail-dark", host)
        let content = frames["workbench-content"]!, terminal = scene.view.convert(scene.view.bounds, to: host), parent = scene.container.superview
        var resizes = 0
        let originalResize = scene.onResize
        scene.onResize = { cols, rows in resizes += 1; originalResize?(cols, rows) }
        model.sidebar.pointerChanged(true); pump(0.45)
        try check(model.sidebar.peeking, "background state-machine dwell reveals the existing overlay")
        try check(frames["workbench-content"] == content && scene.view.convert(scene.view.bounds, to: host) == terminal
                  && scene.container.superview === parent && resizes == 0, "group and orbit changes preserve hover PTY geometry, mount identity and resize count")
        let lights = descendants(host).compactMap { $0 as? SidebarBorderLightView }
        try check(!lights.isEmpty && lights.allSatisfy { !$0.motionEnabled && $0.lightLayer.animationKeys() == nil }, "hidden rail removes orbit work while full sidebar is peeking")
        model.sidebar.pointerChanged(false); pump(0.4)
        try check(!model.sidebar.peeking, "background pointer exit closes the transient overlay")
        for width in [950.0, 1100.0, 1800.0] {
            window.setContentSize(CGSize(width: width, height: 860)); host.layoutSubtreeIfNeeded(); pump(0.2)
            try check(frames["workbench-content"]?.minX == 56 && frames["workbench-content"]!.maxX <= width + 1,
                      "\(Int(width))pt hidden window keeps the same content allocation")
        }
        guard let runningLight = descendants(host).compactMap({ $0 as? SidebarBorderLightView }).first,
              let railScroll = runningLight.enclosingScrollView else { throw NSError(domain: "MissingRailScroll", code: 1) }
        try check(railScroll.contentView.bounds.width == 56, "compact rail never reserves legacy scroller space")
        window.setContentSize(CGSize(width: 1100, height: 420)); host.layoutSubtreeIfNeeded(); pump(0.2)
        let bottom = max(0, (railScroll.documentView?.bounds.height ?? 0) - railScroll.contentView.bounds.height)
        railScroll.contentView.scroll(to: CGPoint(x: 0, y: bottom)); railScroll.reflectScrolledClipView(railScroll.contentView); pump(0.2)
        try check(bottom > 0 && !runningLight.visibleRect.intersects(runningLight.bounds) && runningLight.lightLayer.animationKeys() == nil,
                  "a running tile scrolled out of a short viewport is invisible and does no animation work; offset=\(bottom), clip=\(railScroll.contentView.bounds), visible=\(runningLight.visibleRect), tile=\(runningLight.convert(runningLight.bounds, to: host))")
        railScroll.contentView.scroll(to: .zero); railScroll.reflectScrolledClipView(railScroll.contentView)
        window.setContentSize(CGSize(width: 1100, height: 860)); host.layoutSubtreeIfNeeded(); pump(0.2)
        try check(runningLight.visibleRect.intersects(runningLight.bounds), "scrolling back restores the tile's visibility without remounting it")
        try check(model.liveRuntime(key)?.sessionId == session, "grouping and status animation never replace the running session")
        model.exitWorkhorseMode(); pump(0.25)
        try check(frames["rail-owner-td"] == nil && frames["rail-sidebar-menu-preset"] != nil, "card mode retains menu-only rail, not workhorse owners")
        try check(!window.isVisible && !NSApp.isActive, "all layout and real PTY checks finish without showing a window")
    }

    @MainActor static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-rail-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try check(!NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      "verifier cannot take foreground ownership")
            let model = try fixture(root)
            try grouping(model)
            try layerChecks()
            try orbitPixels()
            try statusViews()
            try nativeLayout(model)
            try check(!NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      "verification never activates itself or sends desktop input")
            print("\(count) BACKGROUND SIDEBAR RAIL CHECKS PASSED")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}

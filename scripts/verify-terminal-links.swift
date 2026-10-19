import AppKit
import SwiftTerm
import Core
@testable import App

@main
struct VerifyTerminalLinks {
    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw FileBrowserError(label) }
        print("PASS \(label)")
    }

    @MainActor static func rejects(_ handler: TerminalLinkHandler, _ link: String) -> Bool {
        do { _ = try handler.resolve(link); return false } catch { return true }
    }

    @MainActor static func resolver(_ root: URL) throws {
        let handler = TerminalLinkHandler(workingDirectory: root.path)
        for name in ["index.html", "00-overview.png", "01-rail-light.png", "中文 文件.txt", "name%20literal.txt", "file.swift", "literal.txt:12"] {
            try "fixture".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for link in ["index.html", "./index.html", root.appendingPathComponent("index.html").path,
                     root.appendingPathComponent("index.html").absoluteString, "index.html#preview"] {
            try check(try handler.resolve(link).path == root.appendingPathComponent("index.html").path,
                      "resolve session-relative / absolute / file URL / anchor: \(link)")
        }
        try check(try handler.resolve("中文%20文件.txt").lastPathComponent == "中文 文件.txt", "percent-encoded Unicode filename")
        try check(try handler.resolve("name%20literal.txt").lastPathComponent == "name%20literal.txt", "literal percent filename takes priority")
        try check(try handler.resolve("file.swift:12:4").lastPathComponent == "file.swift", "compiler line/column suffix")
        try check(try handler.resolve("literal.txt:12").lastPathComponent == "literal.txt:12", "literal colon filename takes priority")
        let web = "https://example.com/view?a=1&b=2#section"
        try check(try handler.resolve(web).absoluteString == web, "web query and fragment are preserved")
        try check(try handler.resolve(root.path).hasDirectoryPath, "directory is navigable")
        for unsafe in ["file://remote.invalid/tmp/index.html", "javascript:alert(1)", "data:text/html,unsafe", "index.html\n", "missing.html"] {
            try check(rejects(handler, unsafe), "reject invalid/unsafe link: \(unsafe.debugDescription)")
        }
        try "echo unsafe".write(to: root.appendingPathComponent("run.command"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Launch.app"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias.html"), withDestinationURL: root.appendingPathComponent("index.html"))
        for unsafe in ["run.command", "Launch.app", "alias.html"] {
            try check(rejects(handler, unsafe), "opening links cannot execute applications/scripts or follow symlinks: \(unsafe)")
        }
        for (text, hit, expected) in [
            ("[中文预览](<中文 文件.txt>)", "预览", "中文 文件.txt"),
            (#"[预览](report\(test\).html)"#, "report", "report(test).html"),
            ("[预览](report(test).html)", "test", "report(test).html")
        ] {
            let offset = NSRange(text.range(of: hit)!, in: text).location
            try check(TerminalFileLinks.markdownTarget(in: text, at: offset) == expected, "Markdown angle / escaped / balanced-parenthesis destination: \(text)")
        }
        try check(TerminalFileLinks.fileTarget(in: ".hidden.txt,", at: 2) == ".hidden.txt", "bare path preserves leading dot and drops trailing prose punctuation")
        var failure = ""
        handler.onFailure = { failure = $0 }
        handler.open("missing.html")
        try check(failure.contains(root.path) && failure.contains("missing.html"), "missing file reports actionable error instead of silently doing nothing")
    }

    @MainActor static func point(_ needle: String, in view: LinkedTerminalView) throws -> CGPoint {
        let terminal = view.getTerminal(), size = view.getOptimalFrameSize().size
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            var text = "", columns: [Int] = []
            for col in 0..<min(terminal.cols, line.count) {
                let character = terminal.getCharacter(for: line[col])
                if col > 0, character == "\0", line[col - 1].width == 2 { continue }
                let string = character == "\0" ? " " : String(character)
                text += string
                columns += Array(repeating: col, count: string.utf16.count)
            }
            if let range = text.range(of: needle) {
                let offset = NSRange(range, in: text).location
                return CGPoint(x: (CGFloat(columns[offset]) + 0.5) * size.width / CGFloat(terminal.cols),
                               y: view.frame.height - (CGFloat(row) + 0.5) * size.height / CGFloat(terminal.rows))
            }
        }
        throw FileBrowserError("Missing visible target: \(needle)")
    }

    @MainActor static func mouse(_ point: CGPoint, in view: LinkedTerminalView, modifiers: NSEvent.ModifierFlags = .command,
                                drag: Bool = false, count: Int = 1) {
        // A real drag has to move past the click slop; an unmoving drag is a click.
        let draggedPoint = CGPoint(x: point.x + 20, y: point.y)
        for type in drag ? [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] : [.leftMouseDown, .leftMouseUp] {
            let local = drag && type != .leftMouseDown ? draggedPoint : point
            let location = view.convert(local, to: nil)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                          eventNumber: 1, clickCount: count, pressure: type == .leftMouseUp ? 0 : 1)!
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }

    @MainActor static func native(_ root: URL) throws {
        let scene = LiveTerminalScene(sessionId: "fixture", workingDirectory: root.path)
        let view = scene.view as! LinkedTerminalView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scene.container
        scene.container.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }
        var opened: [URL] = [], input: [UInt8] = []
        scene.links.openURL = { opened.append($0) }
        scene.onInput = { input += $0 }
        scene.feed(Array(("## 看效果\r\n![原截图、浅深色方案、状态图例](00-overview.png)\r\n"
            + "- [打开 HTML 预览](index.html)\r\n- [浅色窄栏原尺寸](01-rail-light.png)\r\n"
            + "plain index.html\r\n中文 🐂 e\u{301} `中文 文件.txt`\r\n"
            + "\u{1B}]8;;https://example.com/explicit\u{1B}\\explicit label\u{1B}]8;;\u{1B}\\\r\n"
            + "https://example.com/plain?a=1#section\r\n").utf8))
        for target in ["00-overview.png", "HTML", "浅色", "plain index.html", "中文 文件.txt", "explicit label", "https://example.com/plain"] {
            let location = try point(target, in: view)
            // Put the bare filename hit after the word 'plain '.
            let hit = target == "plain index.html" ? CGPoint(x: location.x + 6 * view.getOptimalFrameSize().width / CGFloat(view.getTerminal().cols), y: location.y) : location
            let before = opened.count
            mouse(hit, in: view, modifiers: [])
            try check(opened.count == before, "ordinary click does not navigate: \(target)")
            mouse(hit, in: view)
            try check(opened.count == before + 1, "native Command-click opens \(target); plain click does not")
        }
        try check(opened.prefix(4).map(\.lastPathComponent) == ["00-overview.png", "index.html", "01-rail-light.png", "index.html"], "screenshot Markdown labels and bare filenames resolve to correct files")
        try check(opened[4].lastPathComponent == "中文 文件.txt", "Unicode / wide / combining cells keep correct click coordinates")
        try check(opened[5].absoluteString == "https://example.com/explicit", "OSC 8 link label retains explicit target")
        try check(opened[6].absoluteString == "https://example.com/plain?a=1#section", "implicit web link still opens")
        let location = try point("00-overview.png", in: view), before = opened.count
        mouse(location, in: view, drag: true)
        mouse(location, in: view, modifiers: [], count: 2)
        try check(opened.count == before, "drag selection and ordinary double-click do not navigate")
        scene.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
        input.removeAll()
        mouse(location, in: view)
        try check(input.isEmpty && opened.count == before + 1, "Command-click works in mouse-reporting TUIs without leaking a press to the shell")
        mouse(CGPoint(x: 10, y: 10), in: view, modifiers: [])
        try check(!input.isEmpty, "ordinary TUI mouse reporting is unchanged")
        scene.feed(Array("\u{1B}[?1000l\u{1B}[?1006l".utf8))
        scene.suspendForHistory()
        mouse(location, in: view)
        try check(opened.count == before + 2, "ended terminal retains link navigation")
        mouse(location, in: view, modifiers: [.command, .capsLock])
        try check(opened.count == before + 3, "Caps Lock does not disable Command-click")

        // Real soft wrap, not newline concatenation; verify after changing font size.
        applyTerminalFont(18, to: view)
        let cols = view.getTerminal().cols
        scene.feed(Array(("\r\n" + String(repeating: " ", count: cols - 8) + "[HTML](index.html)\r\n").utf8))
        let beforeWrap = opened.count
        let wrapPoint = try point("dex.html", in: view)
        let wrapRow = view.getTerminal().getTopVisibleRow()
            + Int((view.frame.height - wrapPoint.y) / (view.getOptimalFrameSize().height / CGFloat(view.getTerminal().rows)))
        mouse(wrapPoint, in: view)
        try check(opened.count == beforeWrap + 1 && opened.last?.lastPathComponent == "index.html", "wrapped Markdown link after font/grid change")
        scene.feed(Array(String(repeating: "scroll filler\r\n", count: 80).utf8))
        view.scroll(toPosition: 0)
        view.scrollDown(lines: wrapRow)
        let beforePartialWrap = opened.count
        mouse(try point("dex.html", in: view), in: view)
        try check(opened.count == beforePartialWrap + 1 && opened.last?.lastPathComponent == "index.html", "wrapped link can start just above the visible viewport")
        view.scroll(toPosition: 0)
        let beforeScroll = opened.count
        mouse(try point("00-overview.png", in: view), in: view)
        try check(opened.count == beforeScroll + 1 && opened.last?.lastPathComponent == "00-overview.png", "link hit testing follows scrollback viewport")
    }

    @MainActor static func inlineLabel(_ root: URL) throws {
        let scene = LiveTerminalScene(sessionId: "inline-label", workingDirectory: root.path)
        let view = scene.view as! LinkedTerminalView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scene.container
        scene.container.layoutSubtreeIfNeeded()
        defer { window.contentView = nil }

        var opened: [URL] = []
        scene.links.openURL = { opened.append($0) }
        let url = "https://example.com/builds/123456789"
        scene.feed(Array("查看打包进度 (\(url))\r\n".utf8))
        let label = try point("打包进度", in: view)
        mouse(label, in: view)
        try check(opened.last?.absoluteString == url,
                  "Command-click on a Markdown-style label opens its parenthesized URL")

        func event(_ type: NSEvent.EventType, at point: CGPoint, modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                               clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }

        let beforeRelease = opened.count
        view.mouseDown(with: event(.leftMouseDown, at: label, modifiers: .command))
        view.mouseUp(with: event(.leftMouseUp, at: label, modifiers: []))
        try check(opened.count == beforeRelease + 1,
                  "releasing Command before the mouse button still opens the link")

        let beforeSlop = opened.count
        let nearby = CGPoint(x: label.x + 1, y: label.y)
        view.mouseDown(with: event(.leftMouseDown, at: label, modifiers: .command))
        view.mouseDragged(with: event(.leftMouseDragged, at: nearby, modifiers: .command))
        view.mouseUp(with: event(.leftMouseUp, at: nearby, modifiers: .command))
        try check(opened.count == beforeSlop + 1,
                  "a one-point trackpad wobble does not cancel Command-click")
    }

    @MainActor static func modelAndArchive(_ root: URL) throws {
        let store = try DataStore(directory: root.appendingPathComponent("store"))
        let card = PresetCard(id: "card", title: "fixture", command: "true", workingDirectory: "/wrong/configuration")
        try store.save(card)
        try store.save(SessionRecord(id: "saved", kind: .preset, ownerId: card.id, title: "saved", shell: "/bin/zsh",
                                     workingDirectory: root.path, endedAt: Date(), termination: .normal))
        try store.append([SessionEvent(sessionId: "saved", sequence: 0, kind: .output, data: Data("[预览](index.html)".utf8))])
        let model = AppModel(store: store)
        let live = model.liveScene(sessionId: "saved"), archive = model.archiveScene(sessionId: "saved")
        try check(live.links.initialDirectory.path == root.path && archive.links.initialDirectory.path == root.path,
                  "both AppModel scene factories use session launch directory, not edited card configuration")
        var opened: URL?
        archive.links.openURL = { opened = $0 }
        let replayDeadline = Date().addingTimeInterval(5)
        while !archive.replayFinished && Date() < replayDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try check(archive.replayFinished, "archive replay completes through the paged loader")
        let view = archive.view as! LinkedTerminalView
        mouse(try point("index.html", in: view), in: view)
        try check(opened?.path == root.appendingPathComponent("index.html").path, "archive replay uses same native file-link path")
        let child = root.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        archive.hostCurrentDirectoryUpdate(source: archive.view, directory: child.absoluteString)
        try check(archive.links.workingDirectory.path == child.path, "local OSC 7 directory used by replay")
        archive.hostCurrentDirectoryUpdate(source: archive.view, directory: "file://remote.invalid/foreign")
        try check(archive.links.workingDirectory.path == child.path, "remote OSC 7 never becomes a local filesystem path")
    }

    @MainActor static func cwd(_ root: URL) throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let plan = try ShellShims.makeLaunchPlan(shell: "/bin/zsh", firstCommand: nil, workingDirectory: root.path,
                                                extraEnvironment: [:], shimRoot: root.appendingPathComponent("shims"),
                                                sessionId: "cwd", baseEnvironment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let session = PTYSession(id: "cwd", plan: plan)
        try session.start()
        defer { session.forceTermination(); _ = session.waitForExit(timeout: 2); session.close() }
        let canonical = home.resolvingSymlinksInPath().path
        func normalizedCwd() -> String? {
            session.currentWorkingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        }
        session.write("cd '\(home.path)'\n")
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline && normalizedCwd() != canonical { Thread.sleep(forTimeInterval: 0.02) }
        try check(normalizedCwd() == canonical, "real PTY cwd follows interactive cd without injecting pwd")
        let handler = TerminalLinkHandler(workingDirectory: root.path)
        handler.currentDirectory = { session.currentWorkingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        try check(handler.workingDirectory.resolvingSymlinksInPath().path == canonical, "live navigation queries current shell/job cwd")
        session.write("/bin/sh -c 'cd ..; exec /bin/sleep 3'\n")
        let jobDeadline = Date().addingTimeInterval(2)
        let jobDirectory = root.resolvingSymlinksInPath().path
        while Date() < jobDeadline && normalizedCwd() != jobDirectory { Thread.sleep(forTimeInterval: 0.02) }
        try check(normalizedCwd() == jobDirectory, "foreground job cwd wins over parent shell cwd")
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-links-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try resolver(root)
            try native(root)
            try inlineLabel(root)
            try modelAndArchive(root)
            try cwd(root)
            print("ALL TERMINAL LINK CHECKS PASSED")
        } catch { print("FAIL \(error)"); exit(1) }
    }
}

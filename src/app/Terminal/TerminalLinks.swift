import AppKit
import SwiftTerm
import Core

/// App-owned navigation: SwiftTerm's default opener resolves relative paths against the
/// GUI process's cwd, which is unrelated to the shell that printed the link.
@MainActor
final class TerminalLinkHandler {
    let initialDirectory: URL
    var currentDirectory: (() -> URL?)?
    var onFailure: ((String) -> Void)?
    /// Injectable so verification never launches a browser or another application.
    var openURL: ((URL) -> Void)?
    private var reportedDirectory: URL?

    init(workingDirectory: String?) {
        initialDirectory = FileBrowserPaths.root(sessionDirectory: workingDirectory, configuredDirectory: nil)
    }

    var workingDirectory: URL { currentDirectory?() ?? reportedDirectory ?? initialDirectory }

    func directoryChanged(_ directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL,
              Self.isLocalFileURL(url), url.path.hasPrefix("/") else { return }
        reportedDirectory = url.standardizedFileURL
    }

    func open(_ link: String) {
        do {
            let url = try resolve(link)
            if let openURL { openURL(url); return }
            if !url.isFileURL || url.hasDirectoryPath {
                guard NSWorkspace.shared.open(url) else { throw FileBrowserError("没有可打开此链接的默认应用。") }
            } else {
                // Open documents with a handler, never launch a path as an executable.
                guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
                    throw FileBrowserError("没有可打开此文件的默认应用。")
                }
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                    if let error { Task { @MainActor in self?.onFailure?("打开链接失败：\(error.localizedDescription)") } }
                }
            }
        } catch {
            onFailure?("打开链接失败：\(error.localizedDescription)")
        }
    }

    func resolve(_ link: String) throws -> URL {
        let raw = link.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw FileBrowserError("链接为空或含有控制字符。")
        }
        let location = raw.range(of: #":[0-9]+(?::[0-9]+)?$"#, options: .regularExpression)
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(), location == nil || raw.contains("://") {
            if url.isFileURL {
                guard Self.isLocalFileURL(url) else { throw FileBrowserError("不能打开远端主机的本地文件链接。") }
                return try checkedFile(url)
            }
            guard ["http", "https", "mailto", "ftp", "ftps", "ssh"].contains(scheme) else {
                throw FileBrowserError("不支持的链接协议：\(scheme)")
            }
            return url
        }

        // Prefer literal filenames (including '%' and ':12') before decoding Markdown
        // escapes, dropping an anchor, or stripping a compiler's line/column suffix.
        var paths = [raw]
        if let location { paths.append(String(raw[..<location.lowerBound])) }
        if let decoded = raw.removingPercentEncoding, decoded != raw { paths.append(decoded) }
        if let anchor = raw.firstIndex(of: "#") { paths.append(String(raw[..<anchor])) }
        for path in paths where !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, relativeTo: workingDirectory).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) { return try checkedFile(url) }
        }
        throw FileBrowserError("文件不存在：\(raw)（工作目录：\(workingDirectory.path)）")
    }

    private func checkedFile(_ url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isExecutableKey, .isPackageKey])
        guard values.isSymbolicLink != true else { throw FileBrowserError("请在 Finder 中检查符号链接后自行打开。") }
        if values.isDirectory == true {
            guard values.isPackage != true, url.pathExtension.lowercased() != "app" else {
                throw FileBrowserError("不能通过终端链接启动应用或安装包。")
            }
            return URL(fileURLWithPath: url.path, isDirectory: true)
        }
        guard values.isRegularFile == true,
              BrowserPreviewKind.canOpenExternally(name: url.lastPathComponent, executable: values.isExecutable == true) else {
            throw FileBrowserError("为避免执行程序或脚本，请在 Finder 中检查后自行打开。")
        }
        return url.standardizedFileURL
    }

    private static func isLocalFileURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        guard url.user == nil, url.password == nil, url.port == nil else { return false }
        return host.isEmpty || host == "localhost" || host == ProcessInfo.processInfo.hostName.lowercased()
    }
}

/// File targets missing from SwiftTerm's implicit detector, notably `[label](index.html)`
/// and bare `00-overview.png`. Ranges use UTF-16; terminal columns are mapped separately.
enum TerminalFileLinks {
    private static let markdown = try! NSRegularExpression(pattern:
        #"!?\[[^\]\r\n]*\]\(\s*(?:<([^>\r\n]+)>|((?:[^\s()\\]|\\.|\([^()\r\n]*\))+))(?:\s+"[^"\r\n]*")?\s*\)"#)
    /// Agents often render Markdown links as `label (url)` instead of `[label](url)`.
    /// The whole phrase is underlined by the TUI, so a click on the label must work too.
    private static let labelWithURL = try! NSRegularExpression(pattern:
        #"([^\s()\[\]<>（）]{1,120})\s*[（(](https?://[^\s()<>（）]+)[）)]"#)
    private static let quoted = try! NSRegularExpression(pattern: #"[`"']([^`"'\r\n]+)[`"']"#)
    private static let token = try! NSRegularExpression(pattern: #"[^\s\[\]()<>"'`]+"#)

    static func markdownTarget(in text: String, at offset: Int) -> String? {
        guard let match = containing(markdown, in: text, at: offset) else { return nil }
        let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
        return (text as NSString).substring(with: range)
            .replacingOccurrences(of: #"\("#, with: "(")
            .replacingOccurrences(of: #"\)"#, with: ")")
            .replacingOccurrences(of: #"\ "#, with: " ")
    }

    static func labelURL(in text: String, at offset: Int) -> String? {
        guard let match = containing(labelWithURL, in: text, at: offset) else { return nil }
        return (text as NSString).substring(with: match.range(at: 2))
    }

    static func fileTarget(in text: String, at offset: Int) -> String? {
        let match = containing(quoted, in: text, at: offset) ?? containing(token, in: text, at: offset)
        guard let match else { return nil }
        let range = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
        var candidate = (text as NSString).substring(with: range)
        while let last = candidate.last, ",.;!".contains(last) { candidate.removeLast() }
        guard candidate.contains("/") || (candidate.contains(".") && candidate.unicodeScalars.contains(where: CharacterSet.letters.contains)) else { return nil }
        return candidate
    }

    private static func containing(_ regex: NSRegularExpression, in text: String, at offset: Int) -> NSTextCheckingResult? {
        regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count))
            .first { NSLocationInRange(offset, $0.range) }
    }
}

/// Keep ordinary selection and TUI mouse input untouched. A deliberate Command-click
/// resolves explicit links, Markdown labels/targets and plain file paths in that order.
final class LinkedTerminalView: TerminalView {
    private var pressedLink: String?
    private var pressPoint: CGPoint?
    private var pressedWithCommand = false
    private var draggedLink = false
    /// System click-vs-drag slop. A trackpad click almost always emits a one-pixel
    /// drag event; treating that as a selection drag would swallow the link click.
    private let dragSlop: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        let point = convert(event.locationInWindow, from: nil)
        pressPoint = point
        pressedWithCommand = modifiers == .command && event.clickCount == 1
        pressedLink = pressedWithCommand ? link(at: point) : nil
        draggedLink = false
        withLocalMouseIfNeeded { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let pressPoint {
            if hypot(point.x - pressPoint.x, point.y - pressPoint.y) > dragSlop { draggedLink = true }
        } else {
            draggedLink = true
        }
        withLocalMouseIfNeeded { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedLink = nil; pressPoint = nil; pressedWithCommand = false; draggedLink = false }
        // Use the modifier state from the press, not the release: releasing Command a
        // fraction before the mouse button is a common way to lose an otherwise valid click.
        if let pressedLink, pressedWithCommand, !draggedLink,
           link(at: convert(event.locationInWindow, from: nil)) == pressedLink {
            terminalDelegate?.requestOpenLink(source: self, link: pressedLink, params: [:])
            return
        }
        withLocalMouseIfNeeded { super.mouseUp(with: event) }
    }

    private func withLocalMouseIfNeeded(_ action: () -> Void) {
        let previous = allowMouseReporting
        if pressedLink != nil { allowMouseReporting = false }
        defer { allowMouseReporting = previous }
        action()
    }

    func link(at point: CGPoint) -> String? {
        let terminal = getTerminal()
        let size = getOptimalFrameSize().size
        let scrollerWidth = subviews.compactMap { $0 as? NSScroller }.first(where: { !$0.isHidden })?.frame.width ?? 0
        let width = (size.width - scrollerWidth) / CGFloat(terminal.cols)
        let height = size.height / CGFloat(terminal.rows)
        guard width > 0, height > 0, bounds.contains(point) else { return nil }
        let col = Int(point.x / width), row = Int((frame.height - point.y) / height)
        guard col >= 0, col < terminal.cols, row >= 0, row < terminal.rows else { return nil }
        let position = Position(col: col, row: row)
        if let explicit = terminal.link(at: .screen(position), mode: .explicitOnly) { return explicit }

        // Join real soft wraps only, not unrelated output lines. Iterate cells rather
        // than String indices so CJK, emoji and combining characters don't shift hits.
        let targetRow = terminal.getTopVisibleRow() + row
        var start = targetRow, end = targetRow
        // Include continuations just outside the viewport, but bound work on enormous
        // soft-wrapped log lines rather than scanning the entire scrollback on a click.
        while start > 0, terminal.bufferLine(atRow: start)?.isWrapped == true {
            guard targetRow - start < 256 else { return nil }
            start -= 1
        }
        while terminal.bufferLine(atRow: end + 1)?.isWrapped == true {
            guard end - start < 256 else { return nil }
            end += 1
        }
        var text = "", offset: Int?
        for y in start...end {
            guard let line = terminal.bufferLine(atRow: y) else { continue }
            for x in 0..<min(terminal.cols, line.count) {
                let cell = line[x]
                let character = terminal.getCharacter(for: cell)
                if x > 0, character == "\0", line[x - 1].width == 2 { continue }
                if y == targetRow, col >= x, col < x + max(1, Int(cell.width)) { offset = text.utf16.count }
                text.append(character == "\0" ? " " : character)
            }
        }
        if let offset, let target = TerminalFileLinks.markdownTarget(in: text, at: offset) { return target }
        if let offset, let target = TerminalFileLinks.labelURL(in: text, at: offset) { return target }
        if let implicit = terminal.link(at: .screen(position), mode: .explicitAndImplicit) { return implicit }
        return offset.flatMap { TerminalFileLinks.fileTarget(in: text, at: $0) }
    }
}

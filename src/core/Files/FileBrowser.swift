import Foundation
import Darwin
import UniformTypeIdentifiers

/// Shared panel geometry; presentation is controlled only by the global pin preference.
public enum FileBrowserLayout {
    public static let defaultWidth = 260.0
    public static func width(_ value: Double) -> Double {
        value.isFinite ? min(360, max(220, value)) : defaultWidth
    }

    /// One drag sample: moving the divider left (negative translation) widens the panel.
    public static func draggedWidth(start: Double, translation: Double) -> Double {
        width(start - translation)
    }
}

public enum FileBrowserPaths {
    /// A recorded launch directory wins even after exit, and even if it no longer exists.
    public static func root(sessionDirectory: String?, configuredDirectory: String?,
                            home: String = NSHomeDirectory(), currentDirectory: String = FileManager.default.currentDirectoryPath) -> URL {
        let raw = sessionDirectory ?? configuredDirectory
        var path = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        if path.isEmpty { path = home }
        if path == "~" { path = home }
        else if path.hasPrefix("~/") { path = home + path.dropFirst() }
        return URL(fileURLWithPath: path, isDirectory: true, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true)).standardizedFileURL
    }

    public static func components(_ relative: String) throws -> [String] {
        if relative.isEmpty { return [] }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else {
            throw FileBrowserError("不允许越出卡片工作目录。")
        }
        return parts
    }
}

public struct FileBrowserError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Where Finder should land when the file panel offers to reveal its root.
/// Opening the root must show the working directory's contents; selecting the folder in its
/// parent hides exactly the files the panel is meant to expose.
public struct BrowserFinderTarget: Equatable, Sendable {
    public enum Mode: String, Sendable { case contents, selectedItem }
    public let url: URL
    public let mode: Mode

    public init(root: URL, entry: BrowserEntry? = nil) {
        if let entry {
            self.url = root.appendingPathComponent(entry.relativePath)
            self.mode = .selectedItem
        } else {
            self.url = root
            self.mode = .contents
        }
    }
}

public struct BrowserEntry: Identifiable, Equatable, Sendable {
    public let relativePath: String
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isRegularFile: Bool
    public let size: Int64
    public let executable: Bool
    public var id: String { relativePath }
    public var expandable: Bool { isDirectory && !isSymbolicLink }
}

/// Descriptor-relative traversal rejects links at every level (including race replacements).
/// The configured root itself may intentionally be a symlink; below that root links are leaves.
public enum BrowserFileSystem {
    public static let textLimit = 1_048_576
    public static let nativePreviewLimit: Int64 = 50 * 1_048_576

    private static func failure(_ action: String) -> FileBrowserError {
        FileBrowserError("\(action)：\(String(cString: strerror(errno)))")
    }

    private static func directory(root: URL, relative: String) throws -> Int32 {
        let parts = try FileBrowserPaths.components(relative)
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        var fd = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法读取工作目录") }
        for part in parts {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let error = errno
            close(fd)
            guard next >= 0 else { errno = error; throw failure("无法读取文件夹") }
            fd = next
        }
        return fd
    }

    public static func list(root: URL, relative: String = "", showHidden: Bool = false) throws -> [BrowserEntry] {
        let fd = try directory(root: root, relative: relative)
        guard let dir = fdopendir(fd) else { close(fd); throw failure("无法读取文件夹") }
        defer { closedir(dir) }
        var result: [BrowserEntry] = []
        while true {
            errno = 0
            guard let record = readdir(dir) else {
                if errno != 0 { throw failure("读取目录失败") }
                break
            }
            let name = withUnsafePointer(to: &record.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." || (!showHidden && name.hasPrefix(".")) { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue } // Removed during enumeration.
            let type = info.st_mode & S_IFMT
            result.append(BrowserEntry(relativePath: relative.isEmpty ? name : relative + "/" + name,
                                       name: name, isDirectory: type == S_IFDIR, isSymbolicLink: type == S_IFLNK,
                                       isRegularFile: type == S_IFREG, size: Int64(info.st_size),
                                       executable: info.st_mode & 0o111 != 0))
        }
        return result.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }

    private static func file(root: URL, relative: String) throws -> (Int32, stat) {
        var parts = try FileBrowserPaths.components(relative)
        guard let name = parts.popLast() else { throw FileBrowserError("请选择普通文件。") }
        let parent = try directory(root: root, relative: parts.joined(separator: "/"))
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw failure("无法读取文件") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd); throw FileBrowserError("只预览普通文件；不读取符号链接、设备或管道。")
        }
        return (fd, info)
    }

    /// No mmap or read-to-end: at most `limit` bytes, even if the file grows while reading.
    public static func read(root: URL, relative: String, limit: Int = textLimit) throws -> (data: Data, truncated: Bool) {
        let (fd, info) = try file(root: root, relative: relative)
        defer { close(fd) }
        let cap = max(0, min(limit, Int(nativePreviewLimit)))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(65_536, max(1, cap)))
        while data.count < cap {
            let count = Darwin.read(fd, &buffer, min(buffer.count, cap - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("读取文件失败")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var end = stat()
        _ = fstat(fd, &end)
        return (data, max(info.st_size, end.st_size) > data.count)
    }

    /// A private disposable copy prevents native preview providers from modifying the original,
    /// and prevents a path replacement after validation from escaping the root boundary.
    public static func nativeSnapshot(root: URL, relative: String) throws -> BrowserNativeSnapshot {
        let (fd, info) = try file(root: root, relative: relative)
        defer { close(fd) }
        guard info.st_size <= nativePreviewLimit else {
            throw FileBrowserError("文件超过 50 MB，未载入原生预览；可用默认应用打开。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runbo-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let snapshot = BrowserNativeSnapshot(directory: directory, extension: (relative as NSString).pathExtension)
        let output = open(snapshot.url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw failure("无法创建临时预览") }
        defer { close(output) }
        var count: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while count < nativePreviewLimit {
            let bytes = Darwin.read(fd, &buffer, min(buffer.count, Int(nativePreviewLimit - count)))
            if bytes < 0 { if errno == EINTR { continue }; throw failure("读取预览失败") }
            if bytes == 0 { break }
            var written = 0
            while written < bytes {
                let n = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: written), bytes - written) }
                if n < 0 { if errno == EINTR { continue }; throw failure("写入临时预览失败") }
                guard n > 0 else { throw FileBrowserError("临时预览写入未完成。") }
                written += n
            }
            count += Int64(bytes)
        }
        var end = stat()
        guard fstat(fd, &end) == 0, end.st_size <= nativePreviewLimit else { throw FileBrowserError("文件增长超过 50 MB，已停止预览。") }
        return snapshot
    }
}

public final class BrowserNativeSnapshot: @unchecked Sendable {
    public let url: URL
    private let directory: URL
    fileprivate init(directory: URL, extension ext: String) {
        self.directory = directory
        self.url = directory.appendingPathComponent("preview").appendingPathExtension(ext)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

public struct BrowserText: Equatable, Sendable {
    public let text: String
    public let truncated: Bool
    public let encoding: String

    public static func load(root: URL, relative: String) throws -> BrowserText {
        let result = try BrowserFileSystem.read(root: root, relative: relative)
        return try decode(result.data, truncated: result.truncated)
    }

    public static func decode(_ data: Data, truncated: Bool) throws -> BrowserText {
        let bytes = [UInt8](data)
        var encoding: String.Encoding = .utf8
        var label = "UTF-8"
        var start = 0
        if bytes.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian; label = "UTF-16 LE"; start = 2 }
        else if bytes.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian; label = "UTF-16 BE"; start = 2 }
        else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start = 3 }
        if encoding == .utf8 && bytes.contains(0) { throw FileBrowserError("二进制文件，无法作为文本预览。") }
        var content = Array(bytes.dropFirst(start))
        if truncated {
            if encoding == .utf8 {
                // Only discard a well-formed *incomplete* UTF-8 sequence, never arbitrary bad bytes.
                if let lead = content.lastIndex(where: { $0 < 0x80 || $0 >= 0xC0 }) {
                    let tail = Array(content[lead...])
                    let first = tail[0]
                    let expected = (0xC2...0xDF).contains(first) ? 2 : (0xE0...0xEF).contains(first) ? 3 : (0xF0...0xF4).contains(first) ? 4 : 0
                    if tail.count < expected, tail.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }),
                       !(tail.count > 1 && ((first == 0xE0 && tail[1] < 0xA0) || (first == 0xED && tail[1] > 0x9F)
                                            || (first == 0xF0 && tail[1] < 0x90) || (first == 0xF4 && tail[1] > 0x8F))) {
                        content.removeSubrange(lead...)
                    }
                }
            } else {
                if content.count % 2 == 1 { content.removeLast() }
                if content.count >= 2 {
                    let a = UInt16(content[content.count - 2]), b = UInt16(content[content.count - 1])
                    let last = encoding == .utf16LittleEndian ? a | b << 8 : a << 8 | b
                    if (0xD800...0xDBFF).contains(last) { content.removeLast(2) }
                }
            }
        }
        if let text = String(data: Data(content), encoding: encoding),
           !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 12, 13].contains($0.value) }) {
            return BrowserText(text: text, truncated: truncated, encoding: label)
        }
        throw FileBrowserError("未知编码或二进制内容；文本支持 UTF-8 和带 BOM 的 UTF-16。")
    }
}

public enum BrowserPreviewKind: Equatable, Sendable {
    case text, html, image, pdf, unsupported
    public static func classify(_ name: String) -> BrowserPreviewKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["html", "htm"].contains(ext) { return .html }
        if ext == "pdf" { return .pdf }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico"].contains(ext) { return .image }
        let code = ["swift", "js", "mjs", "cjs", "jsx", "ts", "tsx", "py", "rb", "sh", "bash", "zsh", "fish", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "java", "kt", "kts", "cs", "php", "vue", "svelte", "css", "scss", "less", "json", "jsonl", "yaml", "yml", "toml", "ini", "conf", "config", "env", "md", "markdown", "txt", "log", "xml", "svg", "sql", "csv", "tsv", "lock", "plist"]
        if code.contains(ext) || ext.isEmpty || UTType(filenameExtension: ext)?.conforms(to: .text) == true { return .text }
        return .unsupported
    }

    /// HTML's primary preview belongs to the user's default browser / document app. The safe
    /// static page preview stays available as an explicit secondary action in the file panel.
    public static func opensExternallyByDefault(name: String, executable: Bool = false,
                                                symbolicLink: Bool = false) -> Bool {
        classify(name) == .html && canOpenExternally(name: name, executable: executable,
                                                      symbolicLink: symbolicLink)
    }

    /// Opening a document must never turn into launching a program, installer or script.
    public static func canOpenExternally(name: String, executable: Bool, symbolicLink: Bool = false) -> Bool {
        guard !executable, !symbolicLink else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        let dangerous = ["app", "command", "sh", "bash", "zsh", "fish", "py", "pyw", "rb", "pl", "php", "js", "mjs", "cjs", "scpt", "applescript", "workflow", "action", "automator", "jar", "pkg", "mpkg", "dmg", "iso", "exe", "bat", "cmd", "ps1", "shortcut", "webloc", "url"]
        guard !dangerous.contains(ext), !ext.isEmpty else { return false }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .executable) || type.conforms(to: .script) { return false }
        return true
    }
}

/// HTML resources are served through a private URL scheme, never through file:// access.
/// The scheme handler reuses descriptor-relative no-symlink reads, scoped to the HTML parent.
public enum BrowserHTMLPolicy {
    public static let scheme = "app-preview"
    public static let csp = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline' app-preview:; img-src app-preview:; font-src app-preview:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; media-src 'none'"
    public static func resourcePath(_ url: URL) throws -> String {
        guard url.scheme == scheme, url.host == "local", url.user == nil, url.password == nil, url.port == nil else {
            throw FileBrowserError("HTML 预览禁止联网与外部导航。")
        }
        let path = String(url.path.dropFirst())
        _ = try FileBrowserPaths.components(path)
        guard !path.isEmpty else { throw FileBrowserError("资源路径无效。") }
        return path
    }
    public static func mimeType(_ path: String, main: String) -> String? {
        if path == main { return "text/html" }
        switch (path as NSString).pathExtension.lowercased() {
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return nil
        }
    }
}

/// State is keyed by card in the app. Root changes reset tree state, not user visibility intent.
public struct BrowserUIState: Sendable {
    public var root: URL
    public var expanded: Set<String> = []
    public var selected: String?
    public var showHidden = false
    public var scrollAnchor: String?
    public init(root: URL) { self.root = root }
    public mutating func changeRoot(_ root: URL) {
        guard self.root != root else { return }
        self = BrowserUIState(root: root)
    }
}

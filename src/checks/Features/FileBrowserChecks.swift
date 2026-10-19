import Foundation
import Darwin
import Core

func registerFileBrowserChecks() {
    register("files.root-priority-is-launch-then-config-then-home-with-no-existence-fallback") {
        try expectEqual(FileBrowserPaths.root(sessionDirectory: "/missing/session", configuredDirectory: "/edited", home: "/home").path,
                        "/missing/session", "ended or deleted session root wins")
        try expectEqual(FileBrowserPaths.root(sessionDirectory: nil, configuredDirectory: "~/项目 $(literal)", home: "/home").path,
                        "/home/项目 $(literal)", "tilde expansion without shell evaluation")
        try expectEqual(FileBrowserPaths.root(sessionDirectory: nil, configuredDirectory: nil, home: "/home").path, "/home", "home")
        try expectEqual(FileBrowserPaths.root(sessionDirectory: nil, configuredDirectory: "../project", currentDirectory: "/app/dir").path,
                        "/app/project", "relative matches launch cwd")
    }
    register("files.shared-panel-width-clamping") {
        try expectEqual(FileBrowserLayout.width(.nan), 260, "nonfinite default")
        try expectEqual(FileBrowserLayout.width(10), 220, "minimum")
        try expectEqual(FileBrowserLayout.width(500), 360, "maximum")
        try expectEqual(FileBrowserLayout.width(300), 300, "shared preferred width")
        try expectEqual(FileBrowserLayout.draggedWidth(start: 260, translation: -40), 300, "drag left widens")
        try expectEqual(FileBrowserLayout.draggedWidth(start: 260, translation: 40), 220, "drag right reaches the minimum")
        try expectEqual(FileBrowserLayout.draggedWidth(start: 300, translation: -200), 360, "drag clamps at the maximum")
    }
    register("files.runtime-state-root-reset-and-same-root-retention") {
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
        var state = BrowserUIState(root: a)
        state.expanded = ["Sources"]; state.selected = "Sources/main.swift"; state.showHidden = true; state.scrollAnchor = "Sources"
        state.changeRoot(a)
        try expectEqual(state.selected, "Sources/main.swift", "same root retains selection")
        state.changeRoot(b)
        try expect(state.expanded.isEmpty && state.selected == nil && !state.showHidden && state.scrollAnchor == nil, "new root resets tree state")
    }
    register("files.new-root-and-entry-finder-targets") {
        let root = URL(fileURLWithPath: "/Users/example/project", isDirectory: true)
        let contents = BrowserFinderTarget(root: root)
        try expectEqual(contents.url, root, "root reveal targets the working directory itself")
        try expectEqual(contents.mode, .contents, "root reveal opens directory contents, not its parent")

        let space = try TempSpace.make("files-finder")
        defer { TempSpace.clean(space) }
        let child = try TempSpace.subdirectory(space, "Sources")
        try TempSpace.write("source", to: child.appendingPathComponent("main.swift"))
        let entry = try BrowserFileSystem.list(root: space, relative: "Sources").first!
        let item = BrowserFinderTarget(root: space, entry: entry)
        try expectEqual(item.url.path, child.appendingPathComponent("main.swift").path, "file reveal targets its absolute path")
        try expectEqual(item.mode, .selectedItem, "file reveal selects the item in Finder")
    }
    register("files.lazy-list-directories-first-natural-order-hidden-and-links") {
        let root = try TempSpace.make("files-list")
        defer { TempSpace.clean(root) }
        let child = try TempSpace.subdirectory(root, "Folder")
        try TempSpace.write("nested", to: child.appendingPathComponent("nested.txt"))
        for name in ["file10.txt", "file2.txt", ".env"] { try TempSpace.write(name, to: root.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: child)
        let entries = try BrowserFileSystem.list(root: root)
        try expectEqual(entries.map(\.name), ["Folder", "file2.txt", "file10.txt", "link"], "one layer, natural order, no hidden")
        try expect(entries.last?.isSymbolicLink == true && entries.last?.expandable == false, "link identity without recursion")
        try expectEqual(try BrowserFileSystem.list(root: root, relative: "Folder").map(\.name), ["nested.txt"], "explicit next layer")
        try expect(try BrowserFileSystem.list(root: root, showHidden: true).contains { $0.name == ".env" }, "hidden toggle reads dots, no gitignore")
    }
    register("files.missing-not-directory-empty-and-permission-errors-are-distinct") {
        let root = try TempSpace.make("files-errors")
        defer { TempSpace.clean(root) }
        let empty = try TempSpace.subdirectory(root, "empty")
        try expectEqual(try BrowserFileSystem.list(root: empty).count, 0, "empty is success")
        _ = try expectThrows("missing root") { try BrowserFileSystem.list(root: root.appendingPathComponent("missing")) }
        let file = root.appendingPathComponent("file.txt")
        try TempSpace.write("data", to: file)
        _ = try expectThrows("file as directory") { try BrowserFileSystem.list(root: file) }
        chmod(empty.path, 0)
        defer { chmod(empty.path, 0o700) }
        if geteuid() == 0 { try skipCheck("root bypasses directory permissions") }
        _ = try expectThrows("permission failure, not empty") { try BrowserFileSystem.list(root: empty) }
    }
    register("files.no-symlink-following-or-parent-traversal-in-list-read-or-snapshot") {
        let root = try TempSpace.make("files-boundary")
        defer { TempSpace.clean(root) }
        let outside = try TempSpace.make("files-outside")
        defer { TempSpace.clean(outside) }
        try TempSpace.write("secret", to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file-link"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        _ = try expectThrows("directory symlink") { try BrowserFileSystem.list(root: root, relative: "escape") }
        for path in ["escape/secret.txt", "file-link", "../secret.txt", "/secret.txt", "a//b", "a/./b", "bad\0path"] {
            _ = try expectThrows("read rejects \(path.debugDescription)") { try BrowserFileSystem.read(root: root, relative: path) }
            _ = try expectThrows("snapshot rejects \(path.debugDescription)") { try BrowserFileSystem.nativeSnapshot(root: root, relative: path) }
        }
        // An explicitly configured root link is allowed, unlike a link encountered in its tree.
        try expectEqual(try BrowserFileSystem.list(root: root.appendingPathComponent("escape")).map(\.name), ["secret.txt"], "intentional root symlink")
    }
    register("files.special-files-never-block-or-read-as-text") {
        let root = try TempSpace.make("files-special")
        defer { TempSpace.clean(root) }
        let fifo = root.appendingPathComponent("pipe.txt")
        try expectEqual(mkfifo(fifo.path, 0o600), 0, "fixture pipe")
        let start = Date()
        _ = try expectThrows("pipe is not a regular file") { try BrowserFileSystem.read(root: root, relative: "pipe.txt") }
        try expect(Date().timeIntervalSince(start) < 1, "FIFO open cannot block UI worker")
    }
    register("files.text-read-one-mib-limit-and-complete-unicode-boundaries") {
        let root = try TempSpace.make("files-limit")
        defer { TempSpace.clean(root) }
        let prefix = String(repeating: "a", count: BrowserFileSystem.textLimit - 2)
        let original = Data((prefix + "🙂tail").utf8)
        try original.write(to: root.appendingPathComponent("large.swift"))
        let read = try BrowserFileSystem.read(root: root, relative: "large.swift")
        try expectEqual(read.data.count, BrowserFileSystem.textLimit, "hard read cap, not read-to-end")
        let text = try BrowserText.load(root: root, relative: "large.swift")
        try expect(text.truncated && text.text == prefix, "no replacement glyph from split UTF-8")
        try expectEqual(try Data(contentsOf: root.appendingPathComponent("large.swift")), original, "read did not modify original")
        let utf16 = try BrowserText.decode(Data([0xFF, 0xFE, 0x41, 0, 0x3D, 0xD8, 0x42]), truncated: true)
        try expectEqual(utf16.text, "A", "split UTF-16 surrogate and odd byte")
        try expectEqual(try BrowserText.decode(Data([0xFE, 0xFF, 0, 0x41]), truncated: false).text, "A", "big endian BOM")
        for bytes: [UInt8] in [[0x61, 0xFF], [0x61, 0], [0x61, 0xE0, 0x80], [0xFF, 0xFE, 0, 0]] {
            _ = try expectThrows("binary or malformed tail") { try BrowserText.decode(Data(bytes), truncated: true) }
        }
        try expectEqual(try BrowserText.decode(Data(), truncated: false).text, "", "empty file is not an error")
    }
    register("files.native-snapshots-are-bounded-private-disposable-and-isolated") {
        let root = try TempSpace.make("files-snapshot")
        defer { TempSpace.clean(root) }
        let original = Data("fixture".utf8)
        try original.write(to: root.appendingPathComponent("image.png"))
        var snapshot: BrowserNativeSnapshot? = try BrowserFileSystem.nativeSnapshot(root: root, relative: "image.png")
        let url = snapshot!.url
        try expectEqual(try Data(contentsOf: url), original, "native component gets a copy")
        try Data("temporary change".utf8).write(to: url)
        try expectEqual(try Data(contentsOf: root.appendingPathComponent("image.png")), original, "original isolated from provider changes")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        try expectEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700, "private temporary directory")
        snapshot = nil
        try expect(!FileManager.default.fileExists(atPath: url.path), "temporary snapshot removed on release")
        let big = root.appendingPathComponent("big.pdf")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(BrowserFileSystem.nativePreviewLimit + 1)); try handle.close()
        _ = try expectThrows("oversize native file") { try BrowserFileSystem.nativeSnapshot(root: root, relative: "big.pdf") }
    }
    register("files.preview-routing-and-external-open-never-execute-scripts") {
        for name in ["main.swift", "script.py", "run.sh", "app.tsx", "README.md", "data.yaml", ".env"] {
            try expectEqual(BrowserPreviewKind.classify(name), .text, "source routing \(name)")
        }
        try expectEqual(BrowserPreviewKind.classify("image.PNG"), .image, "image")
        try expectEqual(BrowserPreviewKind.classify("page.html"), .html, "html")
        try expectEqual(BrowserPreviewKind.classify("manual.pdf"), .pdf, "pdf")
        for name in ["run.command", "run.sh", "main.py", "main.js", "thing.app", "install.pkg", "link.webloc", "binary"] {
            try expect(!BrowserPreviewKind.canOpenExternally(name: name, executable: false), "never launch \(name)")
        }
        try expect(!BrowserPreviewKind.canOpenExternally(name: "pretend.txt", executable: true), "executable bits")
        try expect(!BrowserPreviewKind.canOpenExternally(name: "link.txt", executable: false, symbolicLink: true), "symlink")
        try expect(BrowserPreviewKind.canOpenExternally(name: "document.pdf", executable: false), "safe document entrance")
        for name in ["page.html", "PAGE.HTM"] {
            try expect(BrowserPreviewKind.opensExternallyByDefault(name: name), "HTML default action is the user's app: \(name)")
        }
        for name in ["README.md", "run.js", "data.pdf", "binary"] {
            try expect(!BrowserPreviewKind.opensExternallyByDefault(name: name), "only HTML defaults to an external app: \(name)")
        }
        try expect(!BrowserPreviewKind.opensExternallyByDefault(name: "page.html", executable: true), "executable HTML is not launched")
        try expect(!BrowserPreviewKind.opensExternallyByDefault(name: "page.html", symbolicLink: true), "HTML symlink is not launched")
    }
    register("files.html-private-scheme-paths-mime-and-csp-deny-active-content") {
        try expectEqual(try BrowserHTMLPolicy.resourcePath(URL(string: "app-preview://local/assets/image.png")!), "assets/image.png", "scoped relative resource")
        for raw in ["https://example.com/a", "http://localhost/a", "file:///etc/passwd", "app-preview://other/a", "app-preview://user@local/a", "app-preview://local/%2E%2E/secret", "app-preview://local/a%00b"] {
            _ = try expectThrows("blocked \(raw)") { try BrowserHTMLPolicy.resourcePath(URL(string: raw)!) }
        }
        for path in ["script.js", "frame.html", "image.svg", "secret.txt", "download.zip"] {
            try expectEqual(BrowserHTMLPolicy.mimeType(path, main: "index.html"), nil, "not a permitted static resource")
        }
        try expectEqual(BrowserHTMLPolicy.mimeType("style.css", main: "index.html"), "text/css", "css allowed")
        for directive in ["script-src 'none'", "connect-src 'none'", "frame-src 'none'", "object-src 'none'", "base-uri 'none'", "form-action 'none'"] {
            try expect(BrowserHTMLPolicy.csp.contains(directive), directive)
        }
    }
}

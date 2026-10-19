import AppKit
import SwiftUI
import TerminalDeckKit

@MainActor
final class FileBrowserCard: ObservableObject {
    @Published var state: BrowserUIState
    @Published private(set) var listings: [String: [BrowserEntry]] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loading: Set<String> = []
    private var generation = UUID()

    init(root: URL) { state = BrowserUIState(root: root) }
    func setRoot(_ root: URL) {
        guard state.root != root else { return }
        state.changeRoot(root)
        invalidate()
    }
    private func invalidate() {
        generation = UUID(); listings = [:]; errors = [:]; loading = []
    }
    func refresh() {
        // Keep existing rows during refresh so scrollPosition/selection do not collapse to nil.
        generation = UUID(); errors = [:]; loading = []
        load("")
        for path in state.expanded { load(path) }
    }
    func toggleHidden() {
        state.showHidden.toggle()
        if !state.showHidden {
            state.expanded = state.expanded.filter { !$0.split(separator: "/").contains(where: { $0.hasPrefix(".") }) }
            if let selected = state.selected, selected.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { state.selected = nil }
        }
        refresh()
    }
    func load(_ path: String) {
        guard !loading.contains(path) else { return }
        loading.insert(path); errors[path] = nil
        let root = state.root, hidden = state.showHidden, token = generation
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try BrowserFileSystem.list(root: root, relative: path, showHidden: hidden) }
            }.value
            guard let self, self.generation == token else { return }
            self.loading.remove(path)
            switch result {
            case .success(let entries):
                self.listings[path] = entries
                if let selected = self.state.selected,
                   (selected as NSString).deletingLastPathComponent == path,
                   !entries.contains(where: { $0.id == selected }) { self.state.selected = nil }
            case .failure(let error): self.errors[path] = error.localizedDescription; self.listings[path] = nil
            }
        }
    }
    func open() {
        // Re-read only directories that have actually been expanded, never walk recursively.
        refresh()
    }
    func toggle(_ entry: BrowserEntry) {
        guard entry.expandable else { return }
        if state.expanded.remove(entry.id) == nil {
            state.expanded.insert(entry.id); load(entry.id)
        } else {
            // A collapsed subtree is not visible and will be loaded again on expand.
            // Keeping every descendant listing around made long browsing sessions retain
            // directory snapshots for as long as the card existed.
            let prefix = entry.id + "/"
            state.expanded = state.expanded.filter { $0 != entry.id && !$0.hasPrefix(prefix) }
            listings = listings.filter { $0.key != entry.id && !$0.key.hasPrefix(prefix) }
            if let selected = state.selected,
               selected == entry.id || selected.hasPrefix(prefix) { state.selected = nil }
        }
    }
    struct Row: Identifiable {
        let entry: BrowserEntry
        let depth: Int
        var id: String { entry.id }
    }
    var rows: [Row] {
        func descend(_ path: String, depth: Int) -> [Row] {
            (listings[path] ?? []).flatMap { entry -> [Row] in
                [Row(entry: entry, depth: depth)] + (entry.expandable && state.expanded.contains(entry.id)
                    ? descend(entry.id, depth: depth + 1) : [])
            }
        }
        return descend("", depth: 0)
    }
    var selection: BrowserEntry? { rows.first { $0.id == state.selected }?.entry }
}

struct BrowserPreviewRequest: Identifiable {
    let id = UUID()
    let root: URL
    let entry: BrowserEntry
}

/// One coordinator per app, not per detail view: navigating never loses runtime UI state.
@MainActor
final class FileBrowserCoordinator: ObservableObject {
    /// One presentation preference for every owner, mode and fullscreen state.
    @Published var panelWidth: Double
    @Published private(set) var isPinned: Bool
    @Published private(set) var isVisible: Bool
    @Published private(set) var preview: BrowserPreviewRequest?
    private let store: TerminalDeckStore
    private static let pinnedKey = "file_browser_pinned"
    private static let widthKey = "file_browser_width"
    private(set) var inputSource: DeckInputSource = .automatic
    @Published private(set) var focusTreeGeneration = UUID()
    private(set) var shouldFocusTree = false
    private weak var returnFocusView: NSView?
    private var cards: [OwnerKey: FileBrowserCard] = [:]

    init(store: TerminalDeckStore) {
        self.store = store
        let pinned = (try? store.string(forKey: Self.pinnedKey)) == "true"
        isPinned = pinned
        isVisible = pinned
        panelWidth = FileBrowserLayout.width(Double((try? store.string(forKey: Self.widthKey)) ?? "") ?? FileBrowserLayout.defaultWidth)
    }

    func togglePinned(report: (String) -> Void = { _ in }) {
        do {
            try store.setString(isPinned ? "false" : "true", forKey: Self.pinnedKey)
            // Do not animate a PTY resize or discard the current file-tree state.
            isPinned.toggle()
            shouldFocusTree = true
            focusTreeGeneration = UUID()
        } catch { report("保存文件面板设置失败：\(error)") }
    }

    func saveWidth(report: (String) -> Void) {
        do { try store.setString(String(FileBrowserLayout.width(panelWidth)), forKey: Self.widthKey) }
        catch { report("保存文件面板宽度失败：\(error)") }
    }

    func card(for key: OwnerKey, root: URL) -> FileBrowserCard {
        if let card = cards[key] { return card }
        let card = FileBrowserCard(root: root); cards[key] = card
        return card
    }
    func toggle(requestFocus: Bool = false, source: DeckInputSource? = nil) {
        let source = source ?? .current
        if isVisible { close(source: source); return }
        inputSource = source
        if requestFocus {
            returnFocusView = NSApp.keyWindow?.firstResponder as? NSView
            shouldFocusTree = true
            focusTreeGeneration = UUID()
        }
        withAnimation(isPinned ? nil : source.animation(entering: true)) { isVisible = true }
    }
    func close(source: DeckInputSource? = nil) {
        let source = source ?? .current
        inputSource = source
        withAnimation(isPinned ? nil : source.animation(entering: false)) { isVisible = false }
        shouldFocusTree = false
        focusTreeGeneration = UUID()
        let generation = focusTreeGeneration
        let view = returnFocusView
        returnFocusView = nil
        DispatchQueue.main.async { [weak self, weak view] in
            guard self?.focusTreeGeneration == generation, let view, let window = view.window,
                  window.isKeyWindow else { return }
            window.makeFirstResponder(view)
        }
    }
    func presentationChanged() {
        inputSource = .automatic
        // Navigation and fullscreen never override the user's pin or visibility choice.
        preview = nil
        shouldFocusTree = false
        returnFocusView = nil
        focusTreeGeneration = UUID()
    }
    func remove(_ keys: Set<OwnerKey>) { for key in keys { cards[key] = nil } }
    func showPreview(_ entry: BrowserEntry, root: URL, source: DeckInputSource? = nil) {
        guard entry.isRegularFile, !entry.isSymbolicLink else { return }
        let source = source ?? .current
        inputSource = source
        withAnimation(source.animation(entering: true)) { preview = BrowserPreviewRequest(root: root, entry: entry) }
    }
    func closePreview(source: DeckInputSource? = nil) {
        guard preview != nil else { return }
        let source = source ?? .current
        inputSource = source
        withAnimation(source.animation(entering: false)) { preview = nil }
        shouldFocusTree = true
        focusTreeGeneration = UUID()
    }
    /// Called before the existing rename/fullscreen Escape monitor, so one press has one effect.
    func consumeEscape() -> Bool {
        if preview != nil { closePreview(source: .keyboard); return true }
        if isVisible && !isPinned { close(source: .keyboard); return true }
        return false
    }
}

@MainActor
enum BrowserActions {
    static func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    static func reveal(root: URL, entry: BrowserEntry? = nil) {
        // The root action opens the working directory itself. Merely selecting it in its parent
        // would put the files the panel is showing one level out of reach.
        let target = BrowserFinderTarget(root: root, entry: entry)
        switch target.mode {
        case .contents:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: target.url.path)
        case .selectedItem:
            NSWorkspace.shared.activateFileViewerSelecting([target.url])
        }
    }
    static func open(root: URL, entry: BrowserEntry, failure: @escaping (String) -> Void) {
        guard BrowserPreviewKind.canOpenExternally(name: entry.name, executable: entry.executable,
                                                  symbolicLink: entry.isSymbolicLink), entry.isRegularFile else {
            failure("为避免执行程序或脚本，请在 Finder 中检查后自行操作。")
            return
        }
        // Re-check current metadata: a stale row must not launch a replacement executable/link.
        Task {
            let result = await Task.detached {
                Result { () -> URL in
                    let parent = (entry.relativePath as NSString).deletingLastPathComponent
                    let entries = try BrowserFileSystem.list(root: root, relative: parent, showHidden: true)
                    guard let current = entries.first(where: { $0.id == entry.id }), current.isRegularFile,
                          BrowserPreviewKind.canOpenExternally(name: current.name, executable: current.executable,
                                                               symbolicLink: current.isSymbolicLink) else {
                        throw FileBrowserError("文件已变化或不允许用默认应用打开。")
                    }
                    return root.appendingPathComponent(entry.relativePath)
                }
            }.value
            switch result {
            case .success(let url):
                // Resolve a document handler, never use `open(url)` which can launch executables.
                guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { failure("没有可打开此文件的默认应用。"); return }
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { Task { @MainActor in failure(error.localizedDescription) } }
                }
            case .failure(let error): failure(error.localizedDescription)
            }
        }
    }
}

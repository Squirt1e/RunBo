import AppKit
import SwiftTerm
import SwiftUI
import Core

/// Applies the app's terminal font to a SwiftTerm view.
///
/// SwiftTerm's `font` setter is the whole mechanism: it recomputes the cell size, resizes the
/// terminal to the new column/row count, and reports that through `sizeChanged` — which is how
/// the shell learns about the new size (`TIOCSWINSZ`). Scenes are cached per session and reused
/// across page switches, so the size has to be pushed to the view that is on screen; setting it
/// once at construction would leave every already-open terminal at its old size.
///
/// The comparison keeps an unchanged size from triggering a needless font reset on every update.
@MainActor
func applyTerminalFont(_ points: Double, to view: TerminalView) {
    guard view.font.pointSize != CGFloat(points) else { return }
    view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(points), weight: .regular)
}

/// Owns the SwiftTerm view for one live session.
///
/// The view is cached by session id (never recreated while the session exists) so
/// navigating between the workbench and the detail page keeps the scrollback, and so
/// output keeps accumulating even when the detail page is closed.
@MainActor
final class LiveTerminalScene: NSObject, @preconcurrency TerminalViewDelegate {
    let sessionId: String
    let view: TerminalView
    let container: TerminalScrollContainer
    var onInput: (([UInt8]) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    private(set) var isSuspended = false
    let links: TerminalLinkHandler

    init(sessionId: String, workingDirectory: String? = nil) {
        self.sessionId = sessionId
        self.links = TerminalLinkHandler(workingDirectory: workingDirectory)
        var options = TerminalOptions.default
        options.scrollback = 200_000
        let view = LinkedTerminalView(frame: CGRect(x: 0, y: 0, width: 820, height: 420), options: options)
        self.view = view
        self.container = TerminalScrollContainer(terminal: view)
        super.init()
        view.terminalDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(TerminalFontSize.default), weight: .regular)
        view.nativeBackgroundColor = NSColor(hex: 0x18212C)
        view.nativeForegroundColor = NSColor(hex: 0xDCE8ED)
        view.caretColor = NSColor(hex: 0x84A5FF)
        view.optionAsMetaKey = true
        view.allowMouseReporting = true
        view.toolTip = "按住 ⌘ 点击打开网址或文件链接；普通点击与拖动用于选择文本。"
    }

    /// Terminal output from the session.
    func feed(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        view.feed(byteArray: bytes[...])
        container.syncScroller()
    }

    /// Session ended: keep the content, stop accepting input.
    func suspendForHistory() {
        isSuspended = true
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !isSuspended else { return }
        onInput?(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        container.syncScroller()
        guard !isSuspended else { return }
        onResize?(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // Titles come from the shell's own escape sequences; the app shows the card
        // name instead, so nothing to do here.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        links.directoryChanged(directory)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        links.open(link)
    }

    func scrolled(source: TerminalView, position: Double) {
        container.syncScroller()
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        // Only used when `notifyUpdateChanges` is enabled.
    }
}

/// Read-only replay of a saved session.
///
/// A long shell history can be tens of megabytes. Feeding it in one synchronous loop
/// blocks the main run loop for seconds and freezes the whole App, so replay is split
/// into small output chunks and yields between them. The UI keeps painting while the
/// archive is being reconstructed.
@MainActor
final class ArchiveTerminalScene: NSObject, ObservableObject, @preconcurrency TerminalViewDelegate {
    let sessionId: String
    let view: TerminalView
    let container: TerminalScrollContainer
    let links: TerminalLinkHandler
    @Published private(set) var isReplaying = false
    /// True once `finishReplay()` has run; used by native verification fixtures.
    private(set) var replayFinished = false

    private enum ReplayPhase { case idle, feeding, finished }
    private var phase: ReplayPhase = .idle
    /// Output is parsed in bounded slices so ARC and SwiftTerm cannot build one huge
    /// intermediate array, and so a frame can be drawn between slices.
    private static let replayChunkSize = 16 * 1024

    init(sessionId: String, workingDirectory: String? = nil) {
        self.sessionId = sessionId
        self.links = TerminalLinkHandler(workingDirectory: workingDirectory)
        var options = TerminalOptions.default
        options.scrollback = 200_000
        let view = LinkedTerminalView(frame: CGRect(x: 0, y: 0, width: 820, height: 420), options: options)
        self.view = view
        self.container = TerminalScrollContainer(terminal: view)
        super.init()
        view.terminalDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(TerminalFontSize.default), weight: .regular)
        view.nativeBackgroundColor = NSColor(hex: 0x18212C)
        view.nativeForegroundColor = NSColor(hex: 0xDCE8ED)
        view.toolTip = "按住 ⌘ 点击打开链接；文件按当前磁盘内容打开，并非历史快照。"
    }

    /// Starts a replay exactly once. Returns false when this scene already has one.
    func beginReplay() -> Bool {
        guard phase == .idle else { return false }
        phase = .feeding
        replayFinished = false
        isReplaying = true
        return true
    }

    /// Feeds one page of events. Call between `beginReplay` and `finishReplay`.
    /// `isActive` lets the page pause between 16 KiB slices when the user navigates to
    /// another card; the partial terminal state is kept and resumes when it returns.
    func appendReplay(_ events: [SessionEvent],
                      isActive: @escaping @MainActor () -> Bool = { true }) async {
        guard phase == .feeding else { return }
        var chunk: [UInt8] = []
        chunk.reserveCapacity(Self.replayChunkSize)
        for event in events {
            if Task.isCancelled { return }
            switch event.kind {
            case .output:
                let bytes = [UInt8](event.data)
                guard !bytes.isEmpty else { continue }
                var offset = 0
                while offset < bytes.count {
                    guard await waitUntilActive(isActive) else { return }
                    let take = min(Self.replayChunkSize - chunk.count, bytes.count - offset)
                    chunk.append(contentsOf: bytes[offset..<(offset + take)])
                    offset += take
                    if chunk.count >= Self.replayChunkSize {
                        await flush(&chunk)
                        if Task.isCancelled { return }
                    }
                }
            case .resize:
                guard event.cols > 0, event.rows > 0 else { continue }
                await flush(&chunk)
                guard await waitUntilActive(isActive) else { return }
                view.resize(cols: event.cols, rows: event.rows)
                await Task.yield()
            }
        }
        await flush(&chunk)
    }

    private func waitUntilActive(_ isActive: @MainActor () -> Bool) async -> Bool {
        while !isActive() {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return !Task.isCancelled
    }

    /// Finishes a replay: hides the cursor, fits the recorded grid to the live viewport,
    /// and snaps to the bottom.
    func finishReplay() async {
        guard phase == .feeding else { return }
        guard !Task.isCancelled else { cancelReplay(); return }
        phase = .finished
        isReplaying = false
        replayFinished = true
        // A replay is a record, not a live shell: hide the cursor so the last prompt
        // does not look like it is still accepting input.
        view.getTerminal().hideCursor()
        container.layoutSubtreeIfNeeded()
        container.fitTerminalToViewport()
        view.scroll(toPosition: 1.0)
        container.syncScroller()
    }

    func cancelReplay() {
        guard phase != .finished else { return }
        phase = .idle
        isReplaying = false
        replayFinished = false
    }

    /// Convenience for deterministic fixtures. Production pages the database in
    /// `AppModel` so a large history is never all resident at once.
    func load(_ events: [SessionEvent]) async {
        guard beginReplay() else { return }
        await appendReplay(events)
        guard !Task.isCancelled else { cancelReplay(); return }
        await finishReplay()
    }

    private func flush(_ chunk: inout [UInt8]) async {
        guard !chunk.isEmpty else { return }
        view.feed(byteArray: chunk[...])
        chunk.removeAll(keepingCapacity: true)
        // Let the main run loop deliver frames and input between slices.
        await Task.yield()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {}

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { container.syncScroller() }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { links.directoryChanged(directory) }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { links.open(link) }

    func scrolled(source: TerminalView, position: Double) { container.syncScroller() }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// A live session's terminal, wrapped for SwiftUI.
struct LiveTerminalHost: NSViewRepresentable {
    let scene: LiveTerminalScene
    /// Points the terminal is drawn at; taken straight from the settings-backed model value.
    var fontPoints: Double = TerminalFontSize.default

    func makeNSView(context: Context) -> TerminalScrollContainer { scene.container }

    func updateNSView(_ nsView: TerminalScrollContainer, context: Context) {
        applyTerminalFont(fontPoints, to: nsView.terminal)
        nsView.fitTerminalToViewport()
        nsView.syncScroller()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalScrollContainer, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 240))
    }
}

/// Archive host plus a quiet loading badge while a long history is reconstructed.
struct ArchiveTerminalPane: View {
    @ObservedObject var scene: ArchiveTerminalScene
    var fontPoints: Double = TerminalFontSize.default

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ArchiveTerminalHost(scene: scene, fontPoints: fontPoints)
            if scene.isReplaying {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在载入历史记录…")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.terminalBarText)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.42)))
                .padding(10)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: scene.isReplaying)
    }
}

/// A saved session's read-only terminal, wrapped for SwiftUI.
struct ArchiveTerminalHost: NSViewRepresentable {
    let scene: ArchiveTerminalScene
    /// Read-only replay follows the same setting as the live terminal, so a session does not
    /// change size when the user opens its history.
    var fontPoints: Double = TerminalFontSize.default

    func makeNSView(context: Context) -> TerminalScrollContainer { scene.container }

    func updateNSView(_ nsView: TerminalScrollContainer, context: Context) {
        applyTerminalFont(fontPoints, to: nsView.terminal)
        nsView.fitTerminalToViewport()
        nsView.syncScroller()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalScrollContainer, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 240))
    }
}

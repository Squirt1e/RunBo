import SwiftUI
import TerminalDeckKit

struct SessionDetailView: View {
    @ObservedObject var model: AppModel
    let key: OwnerKey

    /// Rename must claim focus or keystrokes would go to the terminal.
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Fullscreen drops the page chrome and lets the panel take the whole content area.
            // The panel bar and Command-Shift-F remain available; terminal Escape is input.
            if !isFullscreen {
                // 牛马模式的列表常驻在左侧，没有「返回」这个去处；卡片界面保持原样。
                if !model.workhorseMode.isOn { backButton }
                header
            }

            FileBrowserWorkspace(
                coordinator: model.fileBrowser,
                card: model.fileBrowser.card(for: key, root: model.fileBrowserRoot(for: key)),
                root: model.fileBrowserRoot(for: key),
                report: { model.showError($0) }
            ) { filesAction in
                if let runtime = model.liveRuntime(key), runtime.status.isAlive {
                    TerminalPanel(
                        title: panelTitle,
                        subtitle: panelSubtitle,
                        status: Self.connectionState(for: runtime.status),
                        historyAction: historyAction,
                        isFullscreen: isFullscreen,
                        fullscreenAction: { model.toggleFullscreen(key) },
                        backgroundTap: renameDismissAction,
                        filesAction: filesAction,
                        taskControl: primaryControl,
                        copyMenu: CopyDetailMenu(model: model, key: key)
                    ) {
                        LiveTerminalHost(
                            scene: model.liveScene(sessionId: runtime.sessionId),
                            fontPoints: model.terminalFontSize
                        )
                    }
                } else if let replayId = replaySessionId {
                    TerminalPanel(
                        title: panelTitle,
                        subtitle: panelSubtitle,
                        status: finishedConnectionState(for: key),
                        historyAction: historyAction,
                        isFullscreen: isFullscreen,
                        fullscreenAction: { model.toggleFullscreen(key) },
                        backgroundTap: renameDismissAction,
                        filesAction: filesAction,
                        taskControl: primaryControl,
                        copyMenu: CopyDetailMenu(model: model, key: key)
                    ) {
                        ArchiveTerminalPane(
                            scene: model.archiveScene(sessionId: replayId),
                            fontPoints: model.terminalFontSize
                        )
                    }
                } else {
                    TerminalPanel(
                        title: panelTitle,
                        subtitle: panelSubtitle,
                        status: TerminalPanelStatus(label: "未启动", tone: .idle),
                        historyAction: historyAction,
                        isFullscreen: isFullscreen,
                        fullscreenAction: { model.toggleFullscreen(key) },
                        backgroundTap: renameDismissAction,
                        filesAction: filesAction,
                        taskControl: primaryControl,
                        copyMenu: CopyDetailMenu(model: model, key: key)
                    ) {
                        Text("终端尚未启动，请使用右上角的启动按钮。")
                            .font(.system(size: 13))
                            .foregroundStyle(DeckTheme.terminalBarText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, isFullscreen ? 12 : 18)
        .padding(.bottom, isFullscreen ? 14 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Clicking anywhere outside the rename field — including the padding around the
        // terminal — saves it. The terminal view itself is an AppKit view, so it takes
        // its own clicks; TerminalPanel shields them while a rename is in progress.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.renamingKey == key { model.commitRename() }
                }
        }
        // No Escape handling on this page, deliberately. The terminal is an AppKit view that
        // processes its own keys, so a page-level handler would be unreliable — and Escape is
        // load-bearing inside a terminal (vim, less, the shell's vi mode). `DeckRootView` watches
        // it at window level, cancelling app-owned transients without hijacking PTY Escape.
        .onChange(of: isRenamingTitle) { _, renaming in
            renameFieldFocused = renaming
        }
        .onChange(of: renameFieldFocused) { _, focused in
            if !focused, isRenamingTitle { model.commitRename() }
        }
        .onDisappear {
            if isRenamingTitle { model.commitRename() }
        }
        .onAppear {
            renameFieldFocused = isRenamingTitle
        }
    }

    /// 卡片界面里详情是「一整页」，所以需要一个回列表的去处。
    private var backButton: some View {
        Button {
            if model.renamingKey == key { model.commitRename() }
            model.page = model.listPage(for: key)
        } label: {
            Text(key.kind == .preset ? "← 返回快捷指令" : "← 返回终端")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DeckTheme.accent)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var title: String {
        switch key.kind {
        case .preset: return model.card(for: key.ownerId)?.title ?? "快捷指令"
        case .temp: return model.temp(for: key.ownerId)?.title ?? "终端"
        }
    }

    private var runtime: SessionRuntime? { model.detailRuntime(key) }

    /// One explicit lifecycle action in the panel bar, available even when page chrome is hidden.
    private var primaryControl: TerminalTaskControl {
        let live = model.liveRuntime(key)
        let enabled = !model.copyIsBusy(key) && !model.engine.isQuitting
        if live?.needsForceTermination == true {
            return TerminalTaskControl(title: "强制终止", symbol: "bolt.fill", tint: DeckTheme.red,
                                       enabled: enabled, action: { model.forceStop(key) })
        }
        if live?.status == .starting || live?.status == .stopping {
            return TerminalTaskControl(title: live?.status == .starting ? "正在启动" : "正在结束",
                                       symbol: "hourglass", tint: DeckTheme.muted, enabled: false, action: {})
        }
        if let live, live.status == .running, key.kind == .temp || live.isCommandRunning {
            return TerminalTaskControl(title: "终止", symbol: "stop.fill", tint: DeckTheme.red,
                                       enabled: enabled, action: { model.stop(key) })
        }
        if key.kind == .temp, model.temp(for: key.ownerId)?.launchConfiguration == nil {
            return TerminalTaskControl(title: "新建终端", symbol: "plus", tint: DeckTheme.accent,
                                       enabled: enabled, action: { model.createTempTerminal() })
        }
        return TerminalTaskControl(title: live == nil ? "启动" : "重新运行", symbol: "play.fill", tint: DeckTheme.green,
                                   enabled: enabled, action: { model.activatePrimaryAction(key) })
    }

    private var isFullscreen: Bool { model.isFullscreen(key) }
    private var isRenamingTitle: Bool { model.isRenaming(key, in: .detail) }

    /// The panel bar carries what used to sit next to the status: shell and working
    /// directory. Fullscreen also keeps the current title visible at the front.
    private var panelTitle: String { isFullscreen ? title : shellName }
    private var panelSubtitle: String {
        let path = (workingDirectory as NSString).abbreviatingWithTildeInPath
        return isFullscreen ? "\(shellName) · \(path)" : path
    }

    private var historyAction: (() -> Void)? {
        guard key.kind == .preset else { return nil }
        return { model.openHistory(for: key) }
    }

    private var renameDismissAction: (() -> Void)? {
        guard model.renamingKey == key else { return nil }
        return { model.commitRename() }
    }

    private var shellName: String {
        let shell = runtime?.shell ?? model.storedLastSession[key]?.shell
            ?? model.card(for: key.ownerId)?.shellOverride
            ?? model.temp(for: key.ownerId)?.launchConfiguration?.shell ?? model.defaultShell
        return (shell as NSString).lastPathComponent
    }

    private var workingDirectory: String {
        model.fileBrowserRoot(for: key).path
    }

    private var replaySessionId: String? {
        if let runtime = model.detailRuntime(key) { return runtime.sessionId }
        return model.storedLastSession[key]?.id
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isRenamingTitle {
                        TextField("终端标题", text: $model.renameText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 22, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(DeckTheme.panel)
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(DeckTheme.accent, lineWidth: 1))
                            )
                            .frame(maxWidth: 360)
                            .focused($renameFieldFocused)
                            .onSubmit { model.commitRename() }
                            .onExitCommand { model.cancelRename() }
                            .accessibilityLabel("终端标题，按回车保存")
                    } else {
                        Text(title)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(DeckTheme.text)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                            // 分身卡片不认双击重命名：名字归原卡，这里只留铅笔按钮这条明确的路。
                            .onTapGesture(count: 2) {
                                if !model.isDisposableCopy(key) { model.beginRename(key) }
                            }
                            .help(model.isDisposableCopy(key) ? "分身卡片沿用原卡的名字" : "双击可重命名")
                        Button { model.beginRename(key) } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(DeckTheme.accent)
                                .frame(width: 29, height: 29)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("编辑标题")
                        .accessibilityLabel("编辑 \(title) 的标题")
                    }
                }
            }
            Spacer(minLength: 8)
        }
    }

    /// State of a session that is no longer live but whose last screen is still on show.
    /// Ordinary ad-hoc shells are 已失效; presets and retained launch cards are 未运行
    /// because their configuration can start a new session. Failures keep their own wording.
    private func finishedConnectionState(for key: OwnerKey) -> TerminalPanelStatus {
        guard let session = model.storedLastSession[key] else {
            return TerminalPanelStatus(label: "未启动", tone: .idle)
        }
        if session.launchFailed { return TerminalPanelStatus(label: "启动失败", tone: .failed) }
        if session.unexpectedExit { return TerminalPanelStatus(label: "意外退出", tone: .failed) }
        let expired = key.kind == .temp && model.temp(for: key.ownerId)?.launchConfiguration == nil
        return TerminalPanelStatus(label: expired ? "已失效" : "未运行", tone: .idle)
    }

    /// The panel bar is the one place a terminal's state is shown, and it reports the
    /// connection only: shell alive or not. It says nothing about the network — the shells
    /// are local — so it uses the same 在线 wording as the sidebar count.
    private static func connectionState(for status: SessionStatus) -> TerminalPanelStatus {
        switch status {
        case .starting: return TerminalPanelStatus(label: "正在启动", tone: .busy)
        case .running: return TerminalPanelStatus(label: "在线", tone: .live)
        case .stopping: return TerminalPanelStatus(label: "正在结束", tone: .busy)
        case .stopped: return TerminalPanelStatus(label: "已失效", tone: .idle)
        case .failed: return TerminalPanelStatus(label: "意外退出", tone: .failed)
        }
    }
}

struct HistoryPageView: View {
    @ObservedObject var model: AppModel
    let key: OwnerKey
    let sessionId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            // Like the detail page: an expanded panel keeps the whole content area, so the back
            // button and page title step aside. The panel bar still carries the way out.
            if !isFullscreen {
                backButton
                pageTitle
            }

            if let sessionId {
                if model.historyEntries.contains(where: { $0.id == sessionId }) {
                    TerminalPanel(
                        title: isFullscreen ? "【\(title)】" : title,
                        status: TerminalPanelStatus(label: "只读", tone: .idle),
                        historyAction: { model.backFromHistory(for: key, sessionId: sessionId) },
                        isFullscreen: isFullscreen,
                        fullscreenAction: { model.toggleFullscreen(key) },
                        historyTitle: "返回历史"
                    ) {
                        ArchiveTerminalPane(
                            scene: model.archiveScene(sessionId: sessionId),
                            fontPoints: model.terminalFontSize
                        )
                    }
                } else {
                    emptyHistory
                }
            } else if model.historyEntries.isEmpty {
                emptyHistory
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(model.historyEntries.enumerated()), id: \.element.id) { index, session in
                            Button {
                                model.showHistoryRecord(session.id, for: key)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("记录 \(model.historyEntries.count - index)")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(DeckTheme.text)
                                        Text(historySubtitle(session))
                                            .font(.system(size: 12))
                                            .foregroundStyle(DeckTheme.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(DeckTheme.muted)
                                }
                                .padding(13)
                                .background(
                                    RoundedRectangle(cornerRadius: DeckTheme.cornerRadius)
                                        .fill(DeckTheme.panel)
                                        .overlay(RoundedRectangle(cornerRadius: DeckTheme.cornerRadius)
                                            .stroke(DeckTheme.line, lineWidth: 1))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .deckScrollbars()
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, isFullscreen ? 12 : 18)
        .padding(.bottom, isFullscreen ? 14 : 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: key) {
            model.loadHistoryEntries(for: key)
        }
    }

    private var isFullscreen: Bool {
        sessionId.map { id in model.historyEntries.contains { $0.id == id } } == true
            && model.isFullscreen(key)
    }

    private var pageTitle: some View {
        Text(sessionId == nil ? "\(title) · 历史记录" : "历史记录 · \(title)")
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(DeckTheme.text)
    }

    private var backButton: some View {
        Button {
            model.backFromHistory(for: key, sessionId: sessionId)
        } label: {
            Text(sessionId == nil ? "← 返回终端" : "← 历史记录")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DeckTheme.accent)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var title: String {
        switch key.kind {
        case .preset: return model.card(for: key.ownerId)?.title ?? "快捷指令"
        case .temp: return model.temp(for: key.ownerId)?.title ?? "终端"
        }
    }

    private var emptyHistory: some View {
        Text("暂无历史记录。")
            .font(.system(size: 13))
            .foregroundStyle(DeckTheme.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func historySubtitle(_ session: SessionRecord) -> String {
        var parts = [Self.dateFormatter.string(from: session.startedAt)]
        if session.launchFailed {
            parts.append("启动失败")
        } else if session.unexpectedExit {
            parts.append("意外退出")
        } else {
            parts.append("正常结束")
        }
        if session.lastCommandStatusUnknown {
            parts.append(key.kind == .preset ? "上次任务结果未知" : "上次命令结果未知")
        }
        if let status = session.lastCommandExitStatus, status != 0 {
            parts.append("上次命令退出码 \(status)")
        }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// What the terminal panel is showing: a live shell, one on its way in or out, or
/// a record of a finished session. Shown as a badge in the panel bar.
struct TerminalPanelStatus {
    enum Tone { case live, busy, idle, failed }

    let label: String
    let tone: Tone

    var color: Color {
        switch tone {
        case .live: return DeckTheme.terminalBarLive
        case .busy: return DeckTheme.terminalBarBusy
        case .idle: return DeckTheme.terminalBarIdle
        case .failed: return DeckTheme.terminalBarFailed
        }
    }
}

private struct TerminalTaskControl {
    let title: String
    let symbol: String
    let tint: Color
    let enabled: Bool
    let action: () -> Void
}

private struct TerminalPanel<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let status: TerminalPanelStatus
    let historyAction: (() -> Void)?
    /// Whether this panel currently fills the content area, and the way back out.
    var isFullscreen: Bool = false
    var fullscreenAction: (() -> Void)? = nil
    /// Set while an inline field outside the panel owns focus: the first click inside
    /// the terminal then saves that field instead of reaching the terminal.
    var backgroundTap: (() -> Void)? = nil
    var filesAction: (() -> Void)? = nil
    var historyTitle = "历史记录"
    var taskControl: TerminalTaskControl? = nil
    var copyMenu: CopyDetailMenu? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
              ViewThatFits(in: .horizontal) {
                  toolbar(showsText: true).frame(minWidth: 560)
                  toolbar(showsText: false)
              }
              if let subtitle {
                  Label(subtitle, systemImage: "folder")
                      .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                      .lineLimit(1).truncationMode(.middle).help(subtitle)
              }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(DeckTheme.background)
            .overlay(alignment: .bottom) { Divider().overlay(DeckTheme.line) }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: TerminalToolbarHeightKey.self, value: geometry.size.height)
                }
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DeckTheme.terminalBackground)
                .overlay {
                    if let backgroundTap {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: backgroundTap)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DeckTheme.terminalBackground)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(DeckTheme.line, lineWidth: 1))
        .layoutPriority(1)
        .workbenchControlFrame("terminal-panel")
    }

    private func toolbar(showsText: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(DeckTheme.text)
                .lineLimit(1).truncationMode(.middle).help(title)
                .frame(minWidth: 40, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                statusBadge
                if let control = taskControl {
                    TerminalBarButton(title: control.title, symbol: control.symbol, showsText: showsText,
                                      tint: control.tint,
                                      help: control.title == "重新运行" ? "重新运行任务（会重建当前终端）" : control.title,
                                      action: control.action)
                        .disabled(!control.enabled)
                        .accessibilityIdentifier("terminal-primary-action")
                }
                if let historyAction {
                    TerminalBarButton(title: historyTitle, symbol: "clock.arrow.circlepath", showsText: showsText,
                                      action: historyAction)
                }
                if let filesAction {
                    TerminalBarButton(title: "文件", symbol: "folder", showsText: showsText, action: filesAction)
                }
                if let fullscreenAction {
                    TerminalBarButton(title: isFullscreen ? "还原" : "展开",
                                      symbol: isFullscreen ? "arrow.down.right.and.arrow.up.left"
                                          : "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
                                      showsText: showsText,
                                      help: isFullscreen ? "还原终端面板（⌘⇧F）" : "展开终端面板（⌘⇧F）",
                                      action: fullscreenAction)
                }
                if let copyMenu { copyMenu }
            }
            .fixedSize()
        }
    }

    /// The state badge: a dot and a word, coloured by what the panel is showing.
    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.tone == .failed ? DeckTheme.red : status.tone == .live ? WorkhorseTheme.green : DeckTheme.muted)
                .frame(width: 5, height: 5)
            Text(status.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(status.tone == .failed ? DeckTheme.red : DeckTheme.muted)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(DeckTheme.panelSecondary))
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("终端\(status.label)")
    }
}

/// The same 28pt target in both responsive variants; only the label changes, never the action.
private struct TerminalBarButton: View {
    let title: String
    let symbol: String
    var showsText = true
    var tint: Color? = nil
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    .accessibilityHidden(true)
                if showsText { Text(title).font(.system(size: 11.5, weight: .medium)) }
            }
            .foregroundStyle(tint ?? (hovering ? DeckTheme.text : DeckTheme.muted))
            .padding(.horizontal, showsText ? 9 : 0)
            .frame(minWidth: 28, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? WorkhorseTheme.hover : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DeckTheme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(DeckIconPressStyle())
        .focusEffectDisabled(false)
        .onHover { hovering = $0 }
        .help(help ?? title)
        .accessibilityLabel(help ?? title)
        .workbenchControlFrame(title)
    }
}

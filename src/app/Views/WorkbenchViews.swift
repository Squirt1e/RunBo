import AppKit
import SwiftUI
import class SwiftTerm.TerminalView
import Core

/// Sidebar and the current content page.
struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    /// Escape cancels app-owned transients first. With terminal focus, a bare Escape
    /// goes to the PTY; the expanded panel has its own Command-Shift-F shortcut.
    ///
    /// `.onExitCommand` cannot: the terminal is an AppKit view that handles its own key events
    /// through `interpretKeyEvents`, and whether an Escape press reaches SwiftUI's command
    /// handler before the terminal depends on what inside the terminal holds focus — so the
    /// same key would work over some terminals and not others. Escape is also load-bearing
    /// inside a terminal (vim, less, the shell's vi mode), so the one rule that must hold is
    /// that an expanded panel alone must never swallow a focused terminal's Escape.
    @State private var escapeMonitor: Any?

    var body: some View {
        let presentedAlertID = model.alert?.id
        content
            .background(Theme.background)
            .background(WindowChrome())
            .allowsHitTesting(!model.quickNavigationPresented)
            .disabled(model.quickNavigationPresented)
            .accessibilityHidden(model.quickNavigationPresented)
        // Root-owned so regrouping a card cannot remove its picker, and the panel stays in-app.
        .overlay { TagPickerLayer(model: model) }
        .overlay { QuickNavigationLayer(model: model) }
        .coordinateSpace(name: TagPickerLayer.coordinateSpace)
        .onPreferenceChange(CardFrameKey.self) { model.publishCardFrames($0) }
        .focusEffectDisabled()
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(
                get: { model.alert != nil },
                set: { if !$0, model.alert?.id == presentedAlertID { model.alert = nil } }
            ),
            presenting: model.alert
        ) { alert in
            if alert.destructive {
                Button(alert.confirmTitle, role: .destructive) { runAlert(alert) }
            } else {
                Button(alert.confirmTitle) { runAlert(alert) }
            }
            if let saveAction = alert.saveAction {
                Button("保存并继续") { runAlert(alert, action: saveAction) }
            }
            Button("取消", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { alert in
            Text(alert.message)
        }
        .onAppear {
            model.openWindowAction = { openWindow(id: "main") }
            installEscapeMonitor()
        }
        .onDisappear {
            removeEscapeMonitor()
            model.closeQuickNavigation(restoringFocus: false)
            model.closeTagPicker()
        }
        // Leaving the page also dismisses its card's picker.
        .onChange(of: model.page) { _, _ in model.closeTagPicker() }
    }

    /// 两套界面在同一个窗口里二选一：卡片界面（原样）与牛马模式。
    ///
    /// 分叉只在最外层发生——数据、会话、动作全在 `AppModel`，所以切换模式不重启任何终端，
    /// 也不会让两套界面看到不同的东西。
    @ViewBuilder
    private var content: some View {
        if model.splitMode.isOn {
            SplitRootView(model: model)
        } else {
            cardLayout
        }
    }

    private var cardLayout: some View {
        SplitWorkbenchView(model: model) {
            AppSidebar(model: model)
        } content: {
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .appFeedback(model: model)
        }
    }

    private func runAlert(_ alert: AppAlert, action: (() -> Void)? = nil) {
        if model.alert?.id == alert.id { model.alert = nil }
        // A follow-up confirmation has a new identity; dismissing this alert must not erase it.
        DispatchQueue.main.async { (action ?? alert.action)() }
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window == NSApp.keyWindow else { return event }
            // Return defaults to the safe cancel button. Preserve Escape as a second cancel
            // binding for this app-owned alert, without touching a covered operation or PTY.
            if event.keyCode == 53, model.alert != nil {
                model.alert = nil
                return nil
            }
            if event.keyCode == 1, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .option],
               model.alert == nil, !model.quickNavigationPresented, model.tagPicker == nil {
                model.toggleSidebar(source: .keyboard)
                return nil
            }
            if event.keyCode == 40, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               model.alert == nil {
                if model.quickNavigationPresented { model.closeQuickNavigation() } else { model.openQuickNavigation() }
                return nil
            }
            guard event.keyCode == 53, model.alert == nil,
                  model.tagPicker == nil || model.quickNavigationPresented else { return event }
            if model.quickNavigationPresented,
               (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            let terminalHasFocus = event.window?.firstResponder is TerminalView
            return model.consumeAppEscape(terminalHasFocus: terminalHasFocus) ? nil : event
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    @ViewBuilder
    private var main: some View {
        switch model.page {
        case .presets:
            CardListView(model: model, kind: .preset)
        case .temps:
            CardListView(model: model, kind: .temp)
        case .detail(let key):
            SessionDetailView(model: model, key: key)
                .id("detail-" + key.ownerId)
        case .history(let key, let sessionId):
            HistoryPageView(model: model, key: key, sessionId: sessionId)
                .id("history-" + key.ownerId)
        case .editor:
            CardEditorView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }

}

struct AppSidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var presentation: SidebarPresentation
    @FocusState private var focused: SidebarNode?

    init(model: AppModel) { self.model = model; self._presentation = ObservedObject(wrappedValue: model.sidebar) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            QuickNavigationButton(model: model).padding(.bottom, 16)
                .focused($focused, equals: .search)
            VStack(spacing: 4) {
                SidebarNavButton(
                    title: "快捷指令",
                    icon: "square.stack.3d.up",
                    count: model.executingCount(for: .preset),
                    isActive: model.selectedKind == .preset,
                    countMeans: "正在执行"
                ) { model.navigate(to: .presets) }
                .focused($focused, equals: .menu(.preset))
                SidebarNavButton(
                    title: "终端",
                    icon: "terminal",
                    count: model.onlineCount(for: .temp),
                    isActive: model.selectedKind == .temp,
                    countMeans: "在线"
                ) { model.navigate(to: .temps) }
                .focused($focused, equals: .menu(.temp))
            }

            Spacer()

            CopyGlobalPanel(model: model)

            HStack(spacing: 0) {
                SidebarNavButton(title: "设置", icon: "gearshape", count: 0, isActive: isSettings) {
                    model.navigate(to: .settings)
                }
                .focused($focused, equals: .settings)
                ClearCacheButton(model: model)
                    .padding(.trailing, 4)
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panelSecondary)
        .onChange(of: focused) { _, node in presentation.keyboardFocusChanged(node != nil) }
        .onChange(of: presentation.focusRequest) { _, node in
            guard let node else { return }
            DispatchQueue.main.async {
                guard presentation.focusRequest == node else { return }
                focused = node; presentation.finishFocusTransfer(node)
            }
        }
    }

    private var isSettings: Bool {
        if case .settings = model.page { return true }
        return false
    }

}

private struct SidebarNavButton: View {
    let title: String
    let icon: String
    let count: Int
    let isActive: Bool
    /// What the number counts, in the sidebar's own words ("正在执行" / "在线"). The two
    /// menus deliberately count different things, so the accessible label has to say which.
    var countMeans: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: Theme.menuIconSize, weight: .regular))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                HStack(spacing: 4) {
                    Text(title)
                    if count > 0 {
                        Text("· \(count)")
                            .foregroundStyle(Theme.accent)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isActive ? Theme.text : Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(isActive ? Theme.navSelection : hovering ? Theme.panel : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard count > 0, !countMeans.isEmpty else { return title }
        return "\(title)，\(count) 个\(countMeans)"
    }
}

struct CardListView: View {
    @ObservedObject var model: AppModel
    let kind: SessionKind

    @State private var hoveringRow: String?
    @State private var hoveringMode: CardDisplayMode?

    private let listHorizontalPadding: CGFloat = 30
    private let modeSegmentWidth: CGFloat = 32
    private let modeSegmentHeight: CGFloat = 24

    private var mode: CardDisplayMode { model.displayMode(for: kind) }

    /// Terminals stay in their existing order in one flat grid. Presets use nonempty tag blocks.
    private var sections: [TagSection<PresetCardOrTemp>] {
        if kind == .temp {
            return [TagSection(tag: nil, items: model.temps.map(PresetCardOrTemp.temp))]
        }
        return model.tagSections(for: kind)
    }

    /// An untagged-only preset list needs no category heading or separator.
    private var showsTagHeaders: Bool {
        kind == .preset && sections.contains { $0.tag != nil }
    }

    var body: some View {
        Group {
            if isEmpty {
                emptyState
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            sectionHeader
                            ForEach(sections) { section in
                                TagBlockView(
                                    model: model,
                                    kind: kind,
                                    section: section,
                                    showsHeader: showsTagHeaders,
                                    mode: mode
                                )
                            }
                        }
                        .padding(.horizontal, listHorizontalPadding)
                        .padding(.top, 25)
                        .padding(.bottom, 34)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .appScrollbars()
                    }
                    .onChange(of: model.newlyCreatedCopyID) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.22)) { scroller.scrollTo(id, anchor: .center) } }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: "card-list")
        // Escape backs out of the on-card confirmation, the way it did the old alert.
        // (The tag picker swallows Escape itself while it is open.)
        .onExitCommand { model.cancelDeletion() }
    }

    private var isEmpty: Bool { kind == .preset ? model.cards.isEmpty : model.temps.isEmpty }
    private var title: String { kind == .preset ? "快捷指令" : "终端" }
    private var count: Int { kind == .preset ? model.cards.count : model.temps.count }
    private var buttonTitle: String { kind == .preset ? "＋ 添加快捷指令" : "＋ 新建终端" }

    private func addItem() {
        if kind == .preset { model.beginNewCard() } else { model.createTempTerminal() }
    }

    private var sectionHeader: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .medium))
            CountPill(count: count)
            Spacer()
            modeSwitcher
            // Sized by its label: a fixed minimum width left the shorter title ("＋ 新建终端")
            // with padding the longer one did not have.
            Button(buttonTitle, action: addItem)
                .buttonStyle(PressButtonStyle(variant: .small, controlHeight: 30, fontSize: 13))
        }
        .padding(.bottom, 10)
    }

    /// Both layouts stay visible so the selected one is clear before and after switching.
    /// Icon-only, with a white thumb — the system segmented control's language. The words
    /// live in the tooltips: drawing "详细 / 精简" next to glyphs that already spell them out
    /// made the header two boxes wider than it needed to be, and the track was wider than the
    /// button it sat next to.
    private var modeSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(CardDisplayMode.allCases, id: \.self) { option in
                Button {
                    model.setDisplayMode(option, for: kind)
                } label: {
                    CardModeGlyph(mode: option)
                        .foregroundStyle(mode == option ? Theme.text : Theme.muted)
                        .frame(width: modeSegmentWidth, height: modeSegmentHeight)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(hoveringMode == option && mode != option
                                      ? Color.black.opacity(0.05) : Color.clear)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { inside in hoveringMode = inside ? option : nil }
                .help("\(option.label)卡片（只影响本菜单）")
                .accessibilityLabel("\(option.label)卡片")
                .accessibilityValue(mode == option ? "已选中" : "未选中")
            }
        }
        // The thumb sits behind the glyphs, the track behind the thumb.
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.panel)
                .shadow(color: Color.black.opacity(0.12), radius: 1.5, y: 0.5)
                .frame(width: modeSegmentWidth, height: modeSegmentHeight)
                .offset(x: mode == .wide ? 0 : modeSegmentWidth)
                .animation(.easeInOut(duration: 0.18), value: mode)
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 8).fill(Theme.navSelection)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("卡片形态")
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: kind == .preset ? "square.stack.3d.up" : "terminal")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.muted)
            Text(kind == .preset ? "还没有快捷指令" : "还没有终端")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(kind == .preset ? "保存常用命令，随时启动任务。" : "新建一个终端，直接输入命令。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            Button(buttonTitle, action: addItem)
                .buttonStyle(PressButtonStyle(variant: .primary))
                .padding(.top, 7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

/// Each card's frame in the root view, so the tag picker can sit beside it.
struct CardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Native hit-test geometry for responsive controls, in the same root space as card frames.
struct ControlFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func workbenchControlFrame(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ControlFrameKey.self,
                                   value: [id: proxy.frame(in: .named(TagPickerLayer.coordinateSpace))])
        })
    }
}

/// A card grid with an optional tag header. Without a header, the cards always stay visible.
private struct TagBlockView: View {
    @ObservedObject var model: AppModel
    let kind: SessionKind
    let section: TagSection<PresetCardOrTemp>
    let showsHeader: Bool
    let mode: CardDisplayMode

    private var collapsed: Bool {
        guard showsHeader, let tag = section.tag else { return false }
        return model.isTagCollapsed(tag.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                TagSectionHeader(
                    section: section,
                    collapsed: collapsed,
                    usageCount: section.items.count,
                    onToggle: {
                        guard let tag = section.tag else { return }
                        model.toggleTagCollapsed(tag.id)
                    },
                    onRename: { model.renameTag(section.tag?.id ?? "", to: $0) },
                    onMove: { model.moveTag(section.tag?.id ?? "", by: $0) },
                    onDelete: { model.deleteTag(section.tag?.id ?? "") }
                )
            }
            if !collapsed {
                CardGridLayout(mode: mode) {
                    ForEach(section.items) { item in
                        tile(for: item).id(item.id)
                    }
                }
                .padding(.top, showsHeader ? 14 : 0)
                .padding(.bottom, 26)
            } else {
                // A folded block still needs its own rhythm below the header.
                Color.clear.frame(height: 14)
            }
        }
    }

    @ViewBuilder
    private func tile(for item: PresetCardOrTemp) -> some View {
        switch item {
        case .preset(let card):
            let key = OwnerKey(kind: .preset, ownerId: card.id)
            Group {
                switch mode {
                case .wide:
                    PresetCardTile(model: model, card: card)
                case .square:
                    SquarePresetTile(model: model, card: card)
                }
            }
            .copyCard(model: model, key: key, square: mode == .square)
            .cardFrame(card.id)
            .cardContextMenu(model: model, key: key, kind: .preset)
            .deleteConfirmation(for: key, model: model)
        case .temp(let temp):
            let key = OwnerKey(kind: .temp, ownerId: temp.id)
            Group {
                switch mode {
                case .wide:
                    TempTerminalTile(model: model, temp: temp)
                case .square:
                    SquareTempTile(model: model, temp: temp)
                }
            }
            .copyCard(model: model, key: key, square: mode == .square)
            .cardFrame(temp.id)
            .cardContextMenu(model: model, key: key, kind: .temp)
            .deleteConfirmation(for: key, inline: mode == .wide, model: model)
        }
    }
}

/// The block header: colour dot, tag name, count, and the collapse control. It is the only
/// place a tag is shown in the list — cards never carry their tag.
private struct TagSectionHeader: View {
    let section: TagSection<PresetCardOrTemp>
    let collapsed: Bool
    let usageCount: Int
    let onToggle: () -> Void
    let onRename: (String) -> Void
    let onMove: (Int) -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var menuOpen = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var confirmingDelete = false
    @State private var hoveringRow: String?
    @FocusState private var renameFocused: Bool

    private var tag: CardTag? { section.tag }
    private var isUntagged: Bool { tag == nil }
    private var tone: TagTone { tag.map(TagTone.of) ?? .untagged }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isUntagged {
                // Not a tag: a hairline says "the rest", so it never reads as another category.
                Divider().overlay(Theme.line).padding(.bottom, 12)
            }
            headerContent
            if confirmingDelete { deleteConfirm }
        }
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            if let tag {
                Circle().fill(tone.foreground).frame(width: 8, height: 8)
                headerTitle(tag)
            } else {
                Circle().fill(Theme.muted).frame(width: 6, height: 6)
                Text(TagVocabulary.untaggedTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            CountPill(count: usageCount)
            Spacer(minLength: 8)
            if let tag, hovering || menuOpen || renaming {
                blockMenu(tag)
            }
            if !isUntagged {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 18)
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { if !isUntagged { onToggle() } }
        .onHover { hovering = $0 }
        .help(isUntagged ? "没有标签的卡片统一放在这里" : "点击折叠或展开「\(tag?.name ?? "")」")
    }

    @ViewBuilder
    private func headerTitle(_ tag: CardTag) -> some View {
        if renaming {
            TextField("标签名", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 150)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.panelSecondary)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 1))
                )
                .focused($renameFocused)
                .onSubmit {
                    onRename(draft)
                    renaming = false
                }
                .onExitCommand { renaming = false }
                .onAppear {
                    draft = tag.name
                    renameFocused = true
                }
        } else {
            Text(tag.name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
        }
    }

    private func blockMenu(_ tag: CardTag) -> some View {
        Menu {
            Button("重命名") { renaming = true }
            Button("上移") { onMove(-1) }
            Button("下移") { onMove(1) }
            Divider()
            Button("删除标签…") {
                confirmingDelete = true
                menuOpen = false
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(menuOpen ? Theme.panelSecondary : Color.clear)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { menuOpen = $0 }
        .help("管理标签「\(tag.name)」")
    }

    private var deleteConfirm: some View {
        HStack(spacing: 10) {
            Text(usageCount > 0
                 ? "删除「\(tag?.name ?? "")」？\(usageCount) 张卡片会退回「未加标签」，卡片本身不会删。"
                 : "删除「\(tag?.name ?? "")」？目前没有卡片在用它。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Button("取消") { confirmingDelete = false }
                .buttonStyle(PressButtonStyle(variant: .small, fontSize: 12))
            Button("删除") {
                onDelete()
                confirmingDelete = false
            }
            .buttonStyle(PressButtonStyle(variant: .smallDanger, fontSize: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.redBackground)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.redBorder, lineWidth: 1))
        )
        .padding(.top, 10)
    }
}

/// Reports a card's frame in the same top-left coordinate space as the root-owned picker.
struct CardFrameReporter: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CardFrameKey.self,
                    value: [id: proxy.frame(in: .named(TagPickerLayer.coordinateSpace))]
                )
            }
        )
    }
}

/// The card's own menu, drawn by AppKit so a right-click lands on the same items the "…"
/// button shows. Menu items carry the same actions as the in-grid menu used to.
struct CardContextMenu: ViewModifier {
    @ObservedObject var model: AppModel
    let key: OwnerKey
    let kind: SessionKind

    func body(content: Content) -> some View {
        content.contextMenu { CardOperationsMenu(model: model, key: key) }
    }
}

extension View {
    func cardContextMenu(model: AppModel, key: OwnerKey, kind: SessionKind) -> some View {
        modifier(CardContextMenu(model: model, key: key, kind: kind))
    }
}

extension View {
    /// 上报这一项相对根视图的位置，让标签选择器靠右、顶边对齐；牛马模式的列表项也共用。
    func cardFrame(_ id: String) -> some View {
        modifier(CardFrameReporter(id: id))
    }
}

/// The two card silhouettes used in the layout switcher.
private struct CardModeGlyph: View {
    let mode: CardDisplayMode

    var body: some View {
        Group {
            switch mode {
            case .wide:
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1)
                        .strokeBorder(lineWidth: 1)
                        .frame(width: 12, height: 5)
                    RoundedRectangle(cornerRadius: 1)
                        .strokeBorder(lineWidth: 1)
                        .frame(width: 12, height: 5)
                }
            case .square:
                VStack(spacing: 2) {
                    HStack(spacing: 2) { square; square }
                    HStack(spacing: 2) { square; square }
                }
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }

    private var square: some View {
        RoundedRectangle(cornerRadius: 1)
            .strokeBorder(lineWidth: 1)
            .frame(width: 5, height: 5)
    }
}

/// Card body shared by preset cards and temporary terminals.
private struct CardShell<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let presentation: SessionStatusPresentation
    /// Set while this card is being deleted: the card fades out under the particle burst.
    var vanish: CardVanish? = nil
    /// Inset from the card's edge to its content. The wide card and the square card use
    /// slightly different ones.
    var padding: CGFloat = 15
    let onTap: () -> Void
    @ViewBuilder var content: Content

    /// This card's farewell, seeded from `vanish` and never cleared again.
    ///
    /// Reading `vanish` directly was not enough: `AppModel` clears its record the moment the
    /// card leaves the list, but SwiftUI can still be rendering the tile for a frame or two
    /// while the grid animates the gap closed. The tile then re-rendered with a nil record —
    /// i.e. opacity 1, animated — so the deleted card faded back in before disappearing.
    @State private var leaving: CardVanish?

    init(
        presentation: SessionStatusPresentation,
        vanish: CardVanish? = nil,
        padding: CGFloat = 15,
        onTap: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.presentation = presentation
        self.vanish = vanish
        self.padding = padding
        self.onTap = onTap
        self.content = content()
        _leaving = State(initialValue: vanish)
    }

    @State private var hovering = false
    /// The band is mounted while it fades out, not just while the command runs:
    /// removing it in one frame is what made 执行中 → 成功 blink.
    @State private var waveMounted = false
    @State private var waveLit = false
    @State private var waveTask: Task<Void, Never>?

    /// How long the fill's band takes to fade, in or out.
    private static var waveFade: Duration { .milliseconds(160) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .fill(background)
                    // The state colour settles with the band instead of cutting.
                    .animation(Self.stateChange, value: presentation.tone)
                // The executing state moves its background, not its border: a
                // band of light rolling under the content.
                if waveMounted {
                    ExecutingCardWave()
                        .opacity(waveLit ? 1 : 0)
                        .animation(Self.stateChange, value: waveLit)
                }
            }
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .stroke(border, lineWidth: 1)
                .animation(Self.stateChange, value: presentation.tone)
        }
        // The farewell: the card fades (a plain SwiftUI animation) while the particles are
        // drawn over it from their own clock. A deleted card no longer responds to clicks.
        .opacity(leaving?.startedAt == nil ? 1 : 0)
        .animation(fadeAnimation, value: leaving?.startedAt)
        .onChange(of: vanish?.startedAt) { _, _ in
            if leaving == nil { leaving = vanish }
        }
        .overlay {
            if let leaving, let startedAt = leaving.startedAt {
                GeometryReader { proxy in
                    DeleteBurstView(burst: leaving.burst, startedAt: startedAt, cardSize: proxy.size)
                        .offset(x: -DeleteBurstView.margin, y: -DeleteBurstView.margin)
                }
            }
        }
        .allowsHitTesting(leaving == nil)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onTapGesture(perform: onTap)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hovering)
        .onHover { hovering = $0 }
        .onAppear { syncWave(for: presentation.tone, animated: false) }
        .onChange(of: presentation.tone) { _, tone in syncWave(for: tone, animated: true) }
        .onDisappear { waveTask?.cancel() }
    }

    private static var stateChange: Animation { .easeOut(duration: 0.16) }

    /// The farewel's fade, once the transition's clock has actually started.
    private var fadeAnimation: Animation? {
        guard leaving?.startedAt != nil, let fade = leaving?.burst.fade else { return nil }
        return .linear(duration: fade)
    }

    /// Runs the band while a command runs, and keeps it mounted through its
    /// fade-out so the card never blinks on the way to 成功 / 失败.
    private func syncWave(for tone: SessionStatusPresentation.Tone, animated: Bool) {
        waveTask?.cancel()
        guard tone == .executing else {
            waveLit = false
            guard animated else {
                waveMounted = false
                return
            }
            waveTask = Task { @MainActor in
                try? await Task.sleep(for: Self.waveFade)
                guard !Task.isCancelled, !waveLit else { return }
                waveMounted = false
            }
            return
        }
        guard !waveMounted else {
            waveLit = true
            return
        }
        waveMounted = true
        waveLit = false
        waveTask = Task { @MainActor in
            // A frame later, so the fade-in has a starting opacity to animate from.
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            waveLit = true
        }
    }

    private var background: Color {
        switch presentation.tone {
        case .executing: return Theme.panel
        case .running, .failed: return Theme.panel
        case .idle, .busy: return Theme.panel
        }
    }

    private var border: Color {
        switch presentation.tone {
        case .executing, .running, .failed, .idle, .busy: return hovering ? SplitTheme.divider : Theme.line
        }
    }
}

/// A band of accent light rolling across the fill of an executing card. The
/// band starts and ends completely outside the card, so the loop restarts
/// without a jump; with "reduce motion" on the card simply stays still — the
/// static border, the status dot and the label already carry the state.
private struct ExecutingCardWave: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    /// Travel and width are multiples of the card width. `travel` moves the
    /// band from just off one edge to just off the other.
    private let bandWidth: CGFloat = 1.4
    private let travel: CGFloat = 2.4
    private let duration: Double = 3.6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let phase = reduceMotion ? 0 : elapsed.truncatingRemainder(dividingBy: duration) / duration
            band(phase: CGFloat(phase))
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .allowsHitTesting(false)
    }

    /// Derive each frame from time so an interrupted animation or a reappearing card
    /// cannot strand the band beyond the card's edge.
    private func band(phase: CGFloat) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // Horizontal on purpose. A diagonal gradient only reaches zero opacity at the
            // corners, so the band's own rectangular edge stays faintly visible where it
            // crosses the card — barely there on a wide card, an obvious vertical line on a
            // square one. Running it along the x axis puts the fade exactly on the band's
            // left and right edges, where it belongs.
            LinearGradient(
                stops: [
                    .init(color: tint(0), location: 0),
                    .init(color: tint(0.35), location: 0.34),
                    .init(color: tint(1), location: 0.5),
                    .init(color: tint(0.35), location: 0.66),
                    .init(color: tint(0), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width * bandWidth)
            .offset(x: -width * bandWidth + phase * width * travel)
        }
    }

    /// A pale wash in light mode, where the card sits on white, and a fuller one
    /// in dark mode, where the same alpha would barely register.
    private func tint(_ factor: Double) -> Color {
        Theme.accent.opacity((colorScheme == .dark ? 0.34 : 0.12) * factor)
    }
}

/// Action row shared by preset cards and temporary terminals.
struct CardActionRow: View {
    @ObservedObject var model: AppModel
    let key: OwnerKey
    let title: String
    let kind: SessionKind
    let runtime: SessionRuntime?

    var body: some View {
        HStack(spacing: 4) {
            Spacer()
            if kind == .preset || model.temp(for: key.ownerId)?.launchConfiguration != nil {
                primaryAction
            }
            IconButton(systemName: "terminal.fill", help: "查看 \(title) 的详情", tint: Theme.accent) {
                model.page = .detail(key)
            }
            if kind == .preset {
                CardMenuButton(model: model, key: key, title: title)
            } else {
                IconButton(systemName: "trash.fill", help: "删除 \(title)", tint: Theme.destructive) {
                    if let temp = model.temp(for: key.ownerId) { model.requestDeleteTemp(temp) }
                }
            }
        }
    }

    /// No button flips between start and stop while the session is still coming up or
    /// shutting down: it shows progress instead (and the forced stop when unresponsive).
    ///
    /// Once the preset command has failed the task is over, so the card offers 启动
    /// again (which replaces the still-alive shell) instead of 终止: one state, one
    /// meaning per button.
    @ViewBuilder
    private var primaryAction: some View {
        switch runtime?.status {
        case .starting, .stopping:
            HStack(spacing: 2) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                if runtime?.needsForceTermination == true {
                    IconButton(systemName: "bolt.fill", help: "强制终止 \(title)", tint: Theme.red) {
                        model.forceStop(key)
                    }
                }
            }
            .frame(minWidth: 34, minHeight: 30)
        case .running:
            // 执行中 = the command line is still running, so the action is to stop it;
            // once the task finished (成功/失败/结果未知) the action is to run it again.
            if kind == .preset && runtime?.isCommandRunning != true {
                IconButton(systemName: "play.fill", help: "启动 \(title)", tint: Theme.green) {
                    if let card = model.card(for: key.ownerId) { model.startCard(card) }
                }
            } else {
                IconButton(systemName: "stop.fill", help: "终止 \(title)", tint: Theme.red) {
                    model.stop(key)
                }
            }
        default:
            IconButton(systemName: "play.fill", help: "启动 \(title)", tint: Theme.green) {
                model.restart(key)
            }
        }
    }

}

/// The "…" trigger of a preset card.
///
/// It is painted like the icon buttons beside it (same 34×30 well, same hover fill) and
/// reports its frame and hover state to the list, which draws the menu above the grid.
/// The "…" trigger of a preset card: a native menu with 标签 first, then 编辑 / 删除.
///
/// It is drawn in the same 34x30 well as the icon buttons beside it and keeps the hover
/// fill, so the row still reads as one set of controls. The menu itself is AppKit's, and it
/// is the same list of actions the card's right-click menu shows — two ways in, one menu.
private struct CardMenuButton: View {
    @ObservedObject var model: AppModel
    let key: OwnerKey
    let title: String
    var vertical = false
    var well: CGFloat = 34

    @State private var hovering = false

    var body: some View {
        if !model.isDisposableCopy(key) { menu }
    }

    private var menu: some View {
        Menu {
            CardOperationsMenu(model: model, key: key)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
                .rotationEffect(.degrees(vertical ? 90 : 0))
                .frame(width: well, height: well == 34 ? 30 : well)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(hovering ? Theme.panelSecondary : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("标签、编辑或删除 \(title)")
        .accessibilityLabel("标签、编辑或删除 \(title)")
    }
}

struct PresetCardTile: View {
    @ObservedObject var model: AppModel
    let card: PresetCard

    private var key: OwnerKey { OwnerKey(kind: .preset, ownerId: card.id) }

    var body: some View {
        let runtime = model.liveRuntime(key)
        let presentation = model.presentation(for: key)
        CardShell(presentation: presentation, vanish: model.vanishing[key]) {
            model.openDetail(key)
        } content: {
            HStack(spacing: 10) {
                if model.isDisposableCopy(key) { CardCopyBadge() }
                Text(card.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                StatusLabel(presentation: presentation, isTask: true)
            }
            Text(card.command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
                .help(card.command)
            // The footer is an overlay: changing actions cannot move text or following cards.
            Spacer(minLength: 40)
        }
        .frame(height: CardDisplay.cardHeight)
        .overlay(alignment: .bottomTrailing) {
            CardActionRow(model: model, key: key, title: card.title, kind: .preset, runtime: runtime)
                .fixedSize()
                .padding(15)
        }
    }
}

struct TempTerminalTile: View {
    @ObservedObject var model: AppModel
    let temp: TempTerminal

    private var key: OwnerKey { OwnerKey(kind: .temp, ownerId: temp.id) }

    var body: some View {
        let presentation = model.presentation(for: key)
        CardShell(presentation: presentation, vanish: model.vanishing[key]) {
            model.openDetail(key)
        } content: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    if model.isDisposableCopy(key) { CardCopyBadge() }
                    Text(temp.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                StatusLabel(presentation: presentation)
            }
            // Reserve a stable action gutter, not an action HStack in the text flow.
            .padding(.trailing, 140)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 4) {
                if temp.launchConfiguration != nil {
                    IconButton(systemName: model.isRunning(key) ? "stop.fill" : "play.fill",
                                   help: model.isRunning(key) ? "终止 \(temp.title)" : "启动 \(temp.title)",
                                   tint: model.isRunning(key) ? Theme.red : Theme.green) {
                        if model.isRunning(key) { model.stop(key) } else { model.restart(key) }
                    }
                }
                CardMenuButton(model: model, key: key, title: temp.title)
                IconButton(systemName: "terminal.fill", help: "查看 \(temp.title) 的详情", tint: Theme.accent) {
                    model.openDetail(key)
                }
                IconButton(systemName: "trash.fill", help: "删除 \(temp.title)", tint: Theme.destructive) {
                    model.requestDeleteTemp(temp)
                }
            }
            .padding(.trailing, 15)
        }
    }
}

// MARK: - Square cards

/// The measurements the square card is drawn to. The side comes from `CardDisplay.cardHeight`
/// so both layouts keep the same row rhythm; the rest is what fits inside it.
private enum SquareCard {
    static let side = CardDisplay.cardHeight
    static let padding: CGFloat = 14
    /// Tap target around the three dots; the dots themselves hug the padding corner.
    static let menuTarget: CGFloat = 24
    /// Room the title leaves so it never runs under the dots.
    static let menuGutter: CGFloat = 16
    static let titleSize: CGFloat = 16
    static let button: CGFloat = 40
    /// Apple's minimum comfortable target; the circle itself stays 40 across.
    static let buttonTarget: CGFloat = 44
}

/// The one round action on a square card: frosted glass, unchanged across states — only the
/// glyph inside it moves, so its place under the thumb is a habit rather than a guess.
private struct RoundCardButton: View {
    enum Glyph { case play, stop, wait, force, trash }

    let glyph: Glyph
    let tint: Color
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // At rest: no fill, just a hairline ring in the icon's own colour — the card's
                // own background shows through, and the ring is what says "this is a button".
                Circle()
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
                    .opacity(hovering ? 0 : 1)
                if hovering {
                    HoverGlass()
                }
                symbol
            }
            .frame(width: SquareCard.button, height: SquareCard.button)
            .frame(width: SquareCard.buttonTarget, height: SquareCard.buttonTarget)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.16), value: hovering)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var symbol: some View {
        switch glyph {
        case .play:
            Image(systemName: "play.fill").font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
        case .stop:
            Image(systemName: "stop.fill").font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
        case .force:
            Image(systemName: "bolt.fill").font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
        case .trash:
            Image(systemName: "trash.fill").font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
        case .wait:
            ProgressView().controlSize(.small).scaleEffect(0.75)
        }
    }
}

/// What the round button turns into under the pointer.
///
/// On macOS 26 and later this is Apple's Liquid Glass; older systems get the closest
/// material SwiftUI offered before it, so the button never loses its boundary.
private struct HoverGlass: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Circle()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            Circle()
                .fill(.regularMaterial)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.16), radius: 6, y: 2)
        }
    }
}

/// Title on the top padding line, status in the bottom-left corner, round action in the
/// bottom-right. Shared by both card kinds; only the action differs.
private struct SquareCardBody<Action: View>: View {
    let title: String
    let presentation: SessionStatusPresentation
    var menu: AnyView?
    var isCopy = false
    var isTask = false
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                if isCopy { CardCopyBadge() }
                Text(title)
                    .font(.system(size: SquareCard.titleSize, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, menu == nil || isCopy ? 0 : SquareCard.menuGutter)
            }
            Spacer(minLength: 6)
            StatusLabel(presentation: presentation, showsBadge: false, isTask: isTask)
                .padding(.trailing, SquareCard.buttonTarget + 4)
        }
        .overlay(alignment: .bottomTrailing) {
            // A stable action layer: neither the glyph nor its target participates in text sizing.
            action.padding(.trailing, -2).padding(.bottom, -2)
        }
        .overlay(alignment: .topTrailing) {
            if !isCopy, let menu { menu.padding(.trailing, -2).padding(.top, -2) }
        }
    }
}

struct SquarePresetTile: View {
    @ObservedObject var model: AppModel
    let card: PresetCard

    private var key: OwnerKey { OwnerKey(kind: .preset, ownerId: card.id) }

    var body: some View {
        let runtime = model.liveRuntime(key)
        let presentation = model.presentation(for: key)
        CardShell(
            presentation: presentation,
            vanish: model.vanishing[key],
            padding: SquareCard.padding
        ) {
            model.openDetail(key)
        } content: {
            SquareCardBody(title: card.title, presentation: presentation, menu: AnyView(
                CardMenuButton(model: model, key: key, title: card.title, vertical: true, well: 15)
            ), isCopy: model.isDisposableCopy(key), isTask: true) {
                actionButton(runtime: runtime)
            }
        }
        .frame(width: SquareCard.side, height: SquareCard.side)
        // The command has no room on a square card; a tooltip keeps it one hover away.
        .help(card.command)
    }

    /// One button, one meaning: 启动 until the shell is up, then 终止 while the command runs,
    /// and 强制终止 when the terminal has stopped answering.
    @ViewBuilder
    private func actionButton(runtime: SessionRuntime?) -> some View {
        switch runtime?.status {
        case .starting, .stopping:
            if runtime?.needsForceTermination == true {
                RoundCardButton(glyph: .force, tint: Theme.red,
                                help: "强制终止 \(card.title)") { model.forceStop(key) }
            } else {
                RoundCardButton(glyph: .wait, tint: Theme.muted, help: "\(card.title) 正在启动") {}
            }
        case .running:
            if runtime?.isCommandRunning == true {
                RoundCardButton(glyph: .stop, tint: Theme.red,
                                help: "终止 \(card.title)") { model.stop(key) }
            } else {
                RoundCardButton(glyph: .play, tint: Theme.green,
                                help: "启动 \(card.title)") {
                    if let card = model.card(for: key.ownerId) { model.startCard(card) }
                }
            }
        default:
            RoundCardButton(glyph: .play, tint: Theme.green,
                            help: "启动 \(card.title)") { model.restart(key) }
        }
    }
}

struct SquareTempTile: View {
    @ObservedObject var model: AppModel
    let temp: TempTerminal

    private var key: OwnerKey { OwnerKey(kind: .temp, ownerId: temp.id) }

    var body: some View {
        let presentation = model.presentation(for: key)
        CardShell(
            presentation: presentation,
            vanish: model.vanishing[key],
            padding: SquareCard.padding
        ) {
            model.openDetail(key)
        } content: {
            SquareCardBody(title: temp.title, presentation: presentation, menu: AnyView(
                CardMenuButton(model: model, key: key, title: temp.title, vertical: true, well: 15)
            ), isCopy: model.isDisposableCopy(key)) {
                if temp.launchConfiguration != nil {
                    RoundCardButton(glyph: model.isRunning(key) ? .stop : .play, tint: Theme.green,
                                    help: model.isRunning(key) ? "终止 \(temp.title)" : "启动 \(temp.title)") {
                        if model.isRunning(key) { model.stop(key) } else { model.restart(key) }
                    }
                } else {
                    RoundCardButton(glyph: .trash, tint: Theme.destructive,
                                    help: "删除 \(temp.title)") { model.requestDeleteTemp(temp) }
                }
            }
        }
        .frame(width: SquareCard.side, height: SquareCard.side)
    }
}


// MARK: - Delete confirmation

/// The delete confirmation, drawn on the card it is about: a Liquid Glass sheet over that
/// card's own content, with the two answers as glass circles. The card's position answers
/// "which one", so the sheet carries no title.
///
/// Only the destructive side is tinted — red glass is the one strong colour here, and the
/// cancel side stays clear glass with a grey glyph. Nothing scales: the sheet fades in and
/// the buttons answer with colour, so no part of this moves under the pointer.
struct DeleteConfirmOverlay: View {
    /// Wide terminal cards are only ~96pt tall; there the answers sit in one row with the
    /// note beside them instead of under them.
    let inline: Bool
    let running: Bool
    /// 被确认的那个东西的圆角。默认是卡片的 14；牛马模式的列表项只有 7——
    /// 轮廓对不上，玻璃看起来就像「贴上去的一块」，而不是「这一项变成了玻璃」。
    var cornerRadius: CGFloat = Theme.cardRadius
    /// 圆钮直径。牛马模式的固定 44pt 列表项用 26pt 圆钮，为说明与上下留白留出空间。
    var buttonSize: CGFloat?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var resolvedButtonSize: CGFloat {
        buttonSize ?? (inline ? 36 : SquareCard.button)
    }

    var body: some View {
        ZStack {
            ConfirmSheet(cornerRadius: cornerRadius)
            if inline {
                HStack(spacing: buttonSize == nil ? 18 : 10) {
                    buttons(size: resolvedButtonSize)
                    if running { note }
                }
            } else {
                VStack(spacing: 10) {
                    buttons(size: resolvedButtonSize)
                    if running { note }
                }
            }
        }
        // Anywhere but the two buttons means "never mind".
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onTapGesture(perform: onCancel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(running
                            ? "确认删除这张卡片？会先结束运行中的终端"
                            : "确认删除这张卡片？")
    }

    private func buttons(size: CGFloat) -> some View {
        HStack(spacing: size == 36 ? 14 : 16) {
            ConfirmButton(size: size, isDestructive: false, action: onCancel)
            ConfirmButton(size: size, isDestructive: true, action: onConfirm)
        }
    }

    private var note: some View {
        Text("会先结束运行中的终端")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.muted)
    }
}

/// The glass the sheet is made of.
private struct ConfirmSheet: View {
    var cornerRadius: CGFloat = Theme.cardRadius

    var body: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Theme.line, lineWidth: 1)
                }
        }
    }
}

/// One answer: a glass circle, tinted only when it deletes.
private struct ConfirmButton: View {
    var size: CGFloat = SquareCard.button
    let isDestructive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            glyph
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(isDestructive ? "删除（正在运行的终端会先结束）" : "取消")
        .accessibilityLabel(isDestructive ? "删除" : "取消")
    }

    private var icon: some View {
        Image(systemName: isDestructive ? "trash" : "xmark")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isDestructive ? Color.white : Theme.muted)
            .frame(width: size, height: size)
            .contentShape(Circle())
    }

    @ViewBuilder private var glyph: some View {
        if #available(macOS 26.0, *) {
            icon.glassEffect(isDestructive
                             ? .regular.tint(hovering
                                             ? Theme.destructive
                                             : Theme.destructive.opacity(0.82))
                             : .regular,
                             in: .circle)
        } else {
            icon.background(.regularMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(
                        isDestructive ? Color.white.opacity(0.35) : Theme.line,
                        lineWidth: 1
                    )
                }
        }
    }
}

struct DeleteConfirmation: ViewModifier {
    let key: OwnerKey
    /// Short cards lay the confirmation out in one row.
    let inline: Bool
    /// 被确认对象自己的圆角与圆钮直径（见 `DeleteConfirmOverlay`）。
    var cornerRadius: CGFloat = Theme.cardRadius
    var buttonSize: CGFloat?
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content.overlay {
            if let pending = model.pendingDeletion, pending.key == key {
                DeleteConfirmOverlay(
                    inline: inline,
                    running: pending.running,
                    cornerRadius: cornerRadius,
                    buttonSize: buttonSize,
                    onCancel: { model.cancelDeletion() },
                    onConfirm: { model.confirmDeletion() }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.pendingDeletion)
    }
}

extension View {
    func deleteConfirmation(for key: OwnerKey, inline: Bool = false,
                            cornerRadius: CGFloat = Theme.cardRadius,
                            buttonSize: CGFloat? = nil,
                            model: AppModel) -> some View {
        modifier(DeleteConfirmation(key: key, inline: inline, cornerRadius: cornerRadius,
                                    buttonSize: buttonSize, model: model))
    }
}

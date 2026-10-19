import AppKit
import SwiftUI
import Core

struct CardEditorView: View {
    @ObservedObject var model: AppModel
    @State private var shellPopUp = PopUpState()
    @State private var directoryCompletion = DirectoryCompletionState()
    @FocusState private var titleFocused: Bool

    /// Minimum 950-point window minus the 198-point sidebar and its divider.
    private static let canvasWidth: CGFloat = 751
    private static let textAreaHeight: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return ceil(NSLayoutManager().defaultLineHeight(for: font)) * 6
    }()

    /// One shell drop-down per page: the control measures itself in this space
    /// and the menu is drawn over the page in it.
    private static let popUpSpace = "card-editor"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                backButton
                Spacer()
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: Self.canvasWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider().overlay(Theme.line) }

            ScrollViewReader { scroller in
              ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.editorPageTitle)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text(model.editorEditingCardId.flatMap { model.card(for: $0)?.copy?.runID } != nil
                             ? "保存修改不等于保留分身；仅本次有效，点保留后下次打开仍在。"
                             : "保存后出现在「快捷指令」菜单，随时可以一键启动。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.bottom, 18)
                    if let id = model.editorEditingCardId {
                        CopyDetailBar(model: model, key: OwnerKey(kind: .preset, ownerId: id))
                            .padding(.bottom, 12)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        field(label: "名称", error: model.editorTitleError) { titleField }
                            .id("editor-title")
                        field(
                            label: "启动命令",
                            hint: "命令结束后，终端仍可继续输入。",
                            error: model.editorCommandError
                        ) { commandField }
                        .id("editor-command")

                        Divider().overlay(Theme.line)

                        HStack(alignment: .top, spacing: 14) {
                            field(label: "Shell") {
                                PopUpControl(
                                    options: shellOptions,
                                    selection: $model.editorShell,
                                    state: $shellPopUp,
                                    coordinateSpace: Self.popUpSpace,
                                    name: "Shell"
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            field(label: "工作目录") {
                                workingDirectoryField
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text("环境变量")
                                    .font(.system(size: 13, weight: .medium))
                                Text("每行 KEY=VALUE")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.muted)
                            }
                            environmentField
                        }
                        Toggle(isOn: $model.editorAutoRun) {
                            Text("启动 App 时自动运行").font(.system(size: 13))
                        }
                        .toggleStyle(EditorCheckboxStyle())
                    }
                }
                .frame(maxWidth: Self.canvasWidth - 60, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .center)
                .appScrollbars()
              }
              .task(id: model.editorValidationAttempt) {
                  if model.editorTitleError != nil {
                      scroller.scrollTo("editor-title", anchor: .top)
                      titleFocused = true
                  } else if model.editorCommandError != nil {
                      scroller.scrollTo("editor-command", anchor: .top)
                  }
              }
            }

            footer
        }
        .background(Theme.background)
        .coordinateSpace(name: Self.popUpSpace)
        .onPreferenceChange(PopUpAnchorKey.self) { anchor in
            if shellPopUp.anchor != anchor { shellPopUp.anchor = anchor }
        }
        .onPreferenceChange(DirectoryCompletionAnchorKey.self) { anchor in
            if directoryCompletion.anchor != anchor { directoryCompletion.anchor = anchor }
        }
        // Outside the ScrollView, so an open menu is never clipped by it.
        .overlay {
            PopUpMenu(
                options: shellOptions,
                selection: $model.editorShell,
                state: $shellPopUp
            )
        }
        .overlay { DirectoryCompletionMenu(state: $directoryCompletion) }
    }

    private var backButton: some View {
        Button {
            model.requestCancelEditor()
        } label: {
            Text(model.splitMode.isOn ? "← 返回" : (model.editorSourceTempId == nil ? "← 返回快捷指令" : "← 返回终端"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    // MARK: - Fields

    private var titleField: some View {
        TextField("例如 DeepSeek Harness", text: $model.editorTitle)
            .focused($titleFocused)
            .accessibilityLabel("名称")
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(inputBackground)
    }

    /// Card-level shell: the default one, or an explicit override. Option titles
    /// double as the control's label, so the two can never drift apart.
    private var shellOptions: [PopUpOption<String>] {
        [
            PopUpOption(title: "使用默认 Shell (\(model.defaultShell))", value: "default"),
            PopUpOption(title: ShellKind.zsh.rawValue, value: ShellKind.zsh.rawValue),
            PopUpOption(title: ShellKind.bash.rawValue, value: ShellKind.bash.rawValue),
        ]
    }

    private var workingDirectoryField: some View {
        DirectoryCompletionField(text: $model.editorWorkingDirectory, state: $directoryCompletion)
            .frame(height: 18)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(inputBackground)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: DirectoryCompletionAnchorKey.self,
                        value: proxy.frame(in: .named(Self.popUpSpace))
                    )
                }
            )
    }

    /// The preset command is shell input, so it uses the same surface as the app's
    /// terminal: a title bar with the shell name, a prompt glyph and a monospace line
    /// with macOS text substitution disabled.
    private var commandField: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(shellName) · 启动后执行的第一条命令")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.terminalBarText)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Theme.terminalBackground)
            .overlay(alignment: .bottom) {
                Divider().overlay(Theme.terminalBarLine)
            }

            HStack(alignment: .top, spacing: 9) {
                Text("❯")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.green)
                    .offset(y: -2)
                ShellTextEditor(
                    text: $model.editorCommand,
                    textColor: NSColor(Theme.terminalText),
                    fontSize: 12,
                    placeholder: "例如 dsh",
                    placeholderColor: NSColor(Theme.terminalText).withAlphaComponent(0.4),
                    focusRequest: model.editorTitleError == nil && model.editorCommandError != nil
                        ? model.editorValidationAttempt : 0
                )
                // Fill the box: a text view that only covers its own line makes the
                // rest of the field dead to clicks.
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: Self.textAreaHeight)
            }
            .padding(.top, 8)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.terminalBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11).stroke(Theme.line, lineWidth: 1)
        )
    }

    private var environmentField: some View {
        ShellTextEditor(
            text: $model.editorEnvironment,
            textColor: .labelColor,
            placeholder: "NODE_ENV=development\nAPI_BASE='https://example.com'",
            placeholderColor: NSColor(Theme.muted).withAlphaComponent(0.55)
        )
        .frame(height: Self.textAreaHeight)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(inputBackground)
    }
    // MARK: - Chrome

    private var shellName: String {
        model.editorShell == "default" ? model.defaultShell : model.editorShell
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.editorError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(error)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { model.requestCancelEditor() }
                    .buttonStyle(PressButtonStyle())
                Button("保存快捷指令") { model.saveEditor() }
                    .buttonStyle(PressButtonStyle(variant: .primary))
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 10)
        .frame(maxWidth: Self.canvasWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(Theme.background)
        .overlay(alignment: .top) { Divider().overlay(Theme.line) }
    }

    private func field<Content: View>(
        label: String,
        hint: String? = nil,
        error: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 13, weight: .medium))
            content()
            if let error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
    }
}

private struct EditorCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isOn ? Theme.accent : Theme.panel)
                    .frame(width: 16, height: 16)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(configuration.isOn ? Theme.accent : Theme.line, lineWidth: 1)
                    }
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "已选中" : "未选中")
    }
}

/// A sibling of settings navigation, not a nested button: clearing must not change pages.
/// “缓存” here is finished terminal history, with the same confirmation as Settings.
struct ClearCacheButton: View {
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        IconButton(
            systemName: "eraser",
            help: "清除缓存：仅清理已结束终端的历史记录，不影响运行中的终端",
            tint: hovering ? Theme.accent : Theme.muted,
            wellWidth: 30,
            wellHeight: 28
        ) { model.requestClearHistory() }
        .onHover { hovering = $0 }
        .accessibilityLabel("清除缓存")
        .accessibilityHint("需要确认；仅清理已结束终端的历史记录，保留卡片和运行中的终端")
        .accessibilityIdentifier("clear-cache")
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var shellPopUp = PopUpState()

    /// Same drop-down as the card editor, measured and drawn over this page.
    private static let popUpSpace = "settings"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("设置")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text("调整工作台视图、终端默认值，管理标签与会话记录。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.bottom, 22)

                // Groups are cards: one row per fact, label left, value or control
                // right. Rows that carry no control say so with a muted value
                // instead of pretending to be form fields.
                VStack(alignment: .leading, spacing: 20) {
                    group("工作台") {
                        card {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("牛马模式").font(.system(size: 13, weight: .medium))
                                    Text("标准模式用卡片浏览，牛马模式用常驻列表操作；两者共用数据、配色与面板宽度。")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 12)
                                if model.splitMode.isOn {
                                    Text("已开启")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(SplitTheme.accentText)
                                        .padding(.horizontal, 8)
                                        .frame(height: 20)
                                        .background(Capsule().fill(SplitTheme.accentSoft))
                                        .accessibilityLabel("牛马模式已开启")
                                }
                                Button(model.splitMode.isOn ? "切换到标准模式" : "切换到牛马模式") {
                                    if model.splitMode.isOn {
                                        model.exitSplitMode()
                                    } else {
                                        model.enterSplitMode()
                                    }
                                }
                                .buttonStyle(PressButtonStyle(variant: .small))
                                .fixedSize()
                                .help("立即进入目标视图，不重启运行中的终端；也可按 ⌘K 搜索「模式」")
                                .accessibilityIdentifier("settings-switch-mode")
                                .workbenchControlFrame("switch-mode")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                    }

                    group("终端") {
                        card {
                            row {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("默认 Shell").font(.system(size: 13))
                                    Text("用于新启动的会话；快捷指令可单独指定")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 12)
                                PopUpControl(
                                    options: defaultShellOptions,
                                    selection: defaultShell,
                                    state: $shellPopUp,
                                    coordinateSpace: Self.popUpSpace,
                                    name: "默认 Shell"
                                )
                                .frame(width: 170)
                            }
                            cardDivider
                            fontSizeRow
                        }
                    }

                    group("历史记录") {
                        card {
                            row {
                                Text("当前占用").font(.system(size: 13))
                                Spacer(minLength: 12)
                                Text(usageText)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.text)
                                    .monospacedDigit()
                            }
                            cardDivider
                            VStack(alignment: .leading, spacing: 6) {
                                Text("保留策略").font(.system(size: 13)).foregroundStyle(Theme.text)
                                Text("快捷指令与终端卡片均只保留本次和上次共 \(RetentionPolicy.sessionHistoryLimit) 次会话；普通终端结束后，距最后输入或输出满 24 小时自动清理。")
                                Text("未保留分身仅本次 App 运行有效；已保留的启动卡不受 24 小时清理限制。")
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            cardDivider
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("清理历史记录")
                                        .font(.system(size: 13, weight: .medium))
                                    Text("仅清理已结束的会话记录，不删除卡片，也不影响在线终端")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 12)
                                Button("清理") { model.requestClearHistory() }
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.red)
                                    .padding(.horizontal, 11)
                                    .frame(height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Theme.redBackground)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Theme.redBorder, lineWidth: 1)
                                    )
                                    .buttonStyle(.plain)
                                    .focusEffectDisabled()
                                    .accessibilityLabel("清理历史记录")
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }

                        // History is the only thing here that writes to disk, so its
                        // failure report belongs next to it rather than at page end.
                        if let error = model.historyError {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.red)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                                        .fill(Theme.redBackground)
                                )
                        }
                    }

                    group("标签") {
                        TagManagementCard(model: model)
                    }

                    group("窗口与退出") {
                        card {
                            row {
                                Text("关闭窗口").font(.system(size: 13))
                                Spacer(minLength: 12)
                                Text("终端继续运行")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.muted)
                            }
                            cardDivider
                            row {
                                Text("退出 App").font(.system(size: 13))
                                Spacer(minLength: 12)
                                Text("结束全部运行中的终端")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, 22)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .center)
            .appScrollbars()
        }
        .background(Theme.background)
        .task {
            // Usage changes while sessions run; make sure the row is current.
            model.refreshUsage()
        }
        .coordinateSpace(name: Self.popUpSpace)
        .onPreferenceChange(PopUpAnchorKey.self) { anchor in
            if shellPopUp.anchor != anchor { shellPopUp.anchor = anchor }
        }
        // Outside the ScrollView, so an open menu is never clipped by it.
        .overlay {
            PopUpMenu(
                options: defaultShellOptions,
                selection: defaultShell,
                state: $shellPopUp
            )
        }
    }

    /// The control and its menu edit the same value: the choice is stored (and
    /// announced) as soon as it is picked, as the previous picker did.
    private var defaultShell: Binding<String> {
        Binding(
            get: { model.defaultShell },
            set: { model.setDefaultShell($0) }
        )
    }

    private var defaultShellOptions: [PopUpOption<String>] {
        [
            PopUpOption(title: ShellKind.zsh.rawValue, value: ShellKind.zsh.rawValue),
            PopUpOption(title: ShellKind.bash.rawValue, value: ShellKind.bash.rawValue),
        ]
    }

    private var usageText: String {
        model.historyUsage.humanReadableBytes
    }

    // MARK: - Terminal font size

    /// Three named sizes as one-click segments, plus a fourth that turns into a field for any
    /// whole point. The point of the row is that neither case costs the other anything:
    /// the common sizes never need typing, and 你话事 stays one click away.
    private var fontSizeRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("终端字号").font(.system(size: 13))
                Text("终端与历史回放，改完立即生效")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            TerminalFontSizeControl(
                points: model.terminalFontSize,
                isCustom: model.terminalFontSizeIsCustom,
                onChange: { model.setTerminalFontSize($0, isCustom: $1) }
            )
        }
    }

    // MARK: - Grouped-card chrome

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
                .padding(.leading, 2)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            )
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
    }

    /// Inset like a list row separator, so the card reads as one column of facts.
    private var cardDivider: some View {
        Divider().overlay(Theme.line).padding(.leading, 14)
    }
}

/// 设置 › 标签: the one place every tag can be managed.
///
/// Rows are the same "one fact per row" card the rest of Settings uses. Each row carries the
/// tag pill, how many cards are using it, a reorder handle and a menu; the count is a live
/// figure, so a tag that has fallen to zero still shows here (that is how it gets deleted).
private struct TagManagementCard: View {
    @ObservedObject var model: AppModel

    @State private var renamingId: String?
    @State private var draft = ""
    @State private var confirmingDeleteId: String?
    @State private var adding = false
    @State private var newName = ""
    @State private var hoveringId: String?
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggingId: String?
    @State private var dragOriginIndex = 0
    @State private var dragTargetIndex = 0
    @State private var dragTranslation: CGFloat = 0

    private static let rowHeight: CGFloat = 46
    private static let rowStride: CGFloat = 47
    private static let dragSpace = "tag-management-drag"
    private var reorderAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)
    }

    private var usage: [String: Int] { model.tagUsageCount() }

    /// Inset like a list row separator, matching the rest of Settings.
    private var cardDivider: some View {
        Divider().overlay(Theme.line).frame(height: 1).padding(.leading, 14)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.tags.isEmpty && !adding {
                emptyRow
            } else {
                ForEach(Array(model.tags.enumerated()), id: \.element.id) { index, tag in
                    VStack(spacing: 0) {
                        if index > 0 { cardDivider }
                        tagRow(tag, index: index)
                            .offset(y: rowOffset(tag, index: index))
                        if confirmingDeleteId == tag.id {
                            cardDivider
                            deleteConfirm(tag)
                        }
                    }
                    .zIndex(draggingId == tag.id ? 1 : 0)
                }
            }
            if adding {
                if !model.tags.isEmpty { cardDivider }
                addRow
            } else {
                if !model.tags.isEmpty { cardDivider }
                addButton
            }
        }
        .coordinateSpace(name: Self.dragSpace)
        .onDisappear { resetDrag() }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        )
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("还没有标签")
                .font(.system(size: 13))
            Text("在卡片菜单里选「标签…」随时新建；这里管理它们的名字和顺序。")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func tagRow(_ tag: CardTag, index: Int) -> some View {
        HStack(spacing: 10) {
            if renamingId == tag.id {
                renameField(tag)
            } else {
                TagChip(tag: tag)
                Text(countText(for: tag))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            if renamingId != tag.id {
                reorderHandle(tag)
                rowMenu(tag, index: index)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: draggingId == tag.id ? 8 : 0)
                .fill(draggingId == tag.id ? Theme.panel :
                      hoveringId == tag.id ? Theme.panelSecondary : Color.clear)
                .shadow(color: .black.opacity(draggingId == tag.id ? 0.14 : 0), radius: 8, y: 3)
        }
        .contentShape(Rectangle())
        .gesture(reorderGesture(tag, index: index))
        .onHover { hoveringId = $0 ? tag.id : nil }
    }

    private func countText(for tag: CardTag) -> String {
        let count = usage[tag.id] ?? 0
        return count == 0 ? "暂无卡片使用" : "\(count) 张卡片"
    }

    @ViewBuilder
    private func renameField(_ tag: CardTag) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("重命名标签")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            TextField("标签名", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.panelSecondary)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.accent, lineWidth: 1))
                )
                .focused($fieldFocused)
                .onSubmit(commitRename(tag))
                .onExitCommand { renamingId = nil }
        }
    }

    private func commitRename(_ tag: CardTag) -> () -> Void {
        {
            model.renameTag(tag.id, to: draft)
            renamingId = nil
        }
    }

    private func reorderHandle(_ tag: CardTag) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(draggingId == tag.id ? Theme.accent : Theme.muted)
            .frame(width: 28, height: 26)
            .background(TagMoveCursorRegion(enabled: model.tags.count > 1 && renamingId == nil && confirmingDeleteId == nil))
            .help("拖动「\(tag.name)」调整顺序")
            .accessibilityLabel("拖动「\(tag.name)」调整顺序")
    }

    /// Keep the actual collection unchanged while dragging: stable row identities let the
    /// grabbed row track the pointer directly while its neighbours spring into vacant slots.
    private func reorderGesture(_ tag: CardTag, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.dragSpace))
            .onChanged { value in
                guard model.tags.count > 1, renamingId == nil, confirmingDeleteId == nil else { return }
                if draggingId == nil {
                    withAnimation(reorderAnimation) {
                        draggingId = tag.id
                        dragOriginIndex = index
                        dragTargetIndex = index
                    }
                }
                guard draggingId == tag.id else { return }
                // Clamp at the ends so the lifted row cannot cover other settings groups.
                let translation = min(max(value.translation.height,
                                          -CGFloat(dragOriginIndex) * Self.rowStride),
                                      CGFloat(model.tags.count - 1 - dragOriginIndex) * Self.rowStride)
                var direct = Transaction()
                direct.disablesAnimations = true
                withTransaction(direct) { dragTranslation = translation }
                let target = dragOriginIndex + Int((translation / Self.rowStride).rounded())
                if target != dragTargetIndex {
                    withAnimation(reorderAnimation) { dragTargetIndex = target }
                }
            }
            .onEnded { _ in
                guard draggingId == tag.id else { return }
                // Commit once on release; animating the layout and clearing the offset in
                // one transaction makes the lifted row settle into its final slot smoothly.
                withAnimation(reorderAnimation) {
                    if dragTargetIndex != dragOriginIndex {
                        model.moveTag(tag.id, by: dragTargetIndex - dragOriginIndex)
                    }
                    resetDrag()
                }
            }
    }

    private func rowOffset(_ tag: CardTag, index: Int) -> CGFloat {
        guard draggingId != nil else { return 0 }
        if draggingId == tag.id { return dragTranslation }
        if dragTargetIndex > dragOriginIndex, index > dragOriginIndex, index <= dragTargetIndex {
            return -Self.rowStride
        }
        if dragTargetIndex < dragOriginIndex, index >= dragTargetIndex, index < dragOriginIndex {
            return Self.rowStride
        }
        return 0
    }

    private func resetDrag() {
        draggingId = nil
        dragTranslation = 0
        dragOriginIndex = 0
        dragTargetIndex = 0
    }

    private func rowMenu(_ tag: CardTag, index: Int) -> some View {
        Menu {
            Button("重命名") {
                draft = tag.name
                renamingId = tag.id
                fieldFocused = true
            }
            Button("上移") { withAnimation(reorderAnimation) { model.moveTag(tag.id, by: -1) } }
                .disabled(index == 0)
            Button("下移") { withAnimation(reorderAnimation) { model.moveTag(tag.id, by: 1) } }
                .disabled(index == model.tags.count - 1)
            Divider()
            Button("删除标签…") { confirmingDeleteId = tag.id }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("管理标签「\(tag.name)」")
    }

    private func deleteConfirm(_ tag: CardTag) -> some View {
        let count = usage[tag.id] ?? 0
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(count > 0 ? "删除「\(tag.name)」？" : "删除「\(tag.name)」？")
                    .font(.system(size: 12.5, weight: .medium))
                Text(count > 0
                     ? "\(count) 张卡片会退回「未加标签」，卡片本身不会删。"
                     : "目前没有卡片在使用它。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Button("取消") { confirmingDeleteId = nil }
                .buttonStyle(PressButtonStyle(variant: .small, fontSize: 12))
            Button("删除") {
                model.deleteTag(tag.id)
                confirmingDeleteId = nil
            }
            .buttonStyle(PressButtonStyle(variant: .smallDanger, fontSize: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.redBackground)
    }

    private var addButton: some View {
        Button {
            draft = ""
            newName = ""
            adding = true
            fieldFocused = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("新建标签")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            TextField("标签名，回车创建", text: $newName)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.panelSecondary)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.accent, lineWidth: 1))
                )
                .focused($fieldFocused)
                .onSubmit(commitNew)
                .onExitCommand { adding = false }
            Button("创建", action: commitNew)
                .buttonStyle(PressButtonStyle(variant: .small, fontSize: 12))
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
    }

    private func commitNew() {
        let name = TagVocabulary.normalized(newName)
        guard !name.isEmpty else { adding = false; return }
        // A name that already exists is not an error here: it just selects what is there.
        if let existing = TagVocabulary.match(name, in: model.tags) {
            model.showNotice("已有标签「\(existing.name)」。")
            adding = false
            return
        }
        model.createTag(named: name)
        adding = false
    }
}

/// An AppKit cursor rectangle keeps the move cursor scoped to the handle, including after
/// scrolling or removing the row. It does not intercept the row's SwiftUI drag gesture.
private struct TagMoveCursorRegion: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ view: CursorView, context: Context) {
        guard view.enabled != enabled else { return }
        view.enabled = enabled
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var enabled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            if enabled { addCursorRect(visibleRect, cursor: Self.moveCursor) }
        }

        // AppKit has no public four-direction move cursor. Draw the familiar move shape
        // with a white outline so it remains visible over both light and dark content.
        private static let moveCursor: NSCursor = {
            let size = NSSize(width: 24, height: 24)
            let image = NSImage(size: size, flipped: false) { _ in
                let path = NSBezierPath()
                let points: [NSPoint] = [
                    .init(x: 12, y: 1), .init(x: 7, y: 6), .init(x: 10, y: 6),
                    .init(x: 10, y: 10), .init(x: 6, y: 10), .init(x: 6, y: 7),
                    .init(x: 1, y: 12), .init(x: 6, y: 17), .init(x: 6, y: 14),
                    .init(x: 10, y: 14), .init(x: 10, y: 18), .init(x: 7, y: 18),
                    .init(x: 12, y: 23), .init(x: 17, y: 18), .init(x: 14, y: 18),
                    .init(x: 14, y: 14), .init(x: 18, y: 14), .init(x: 18, y: 17),
                    .init(x: 23, y: 12), .init(x: 18, y: 7), .init(x: 18, y: 10),
                    .init(x: 14, y: 10), .init(x: 14, y: 6), .init(x: 17, y: 6),
                ]
                path.move(to: points[0])
                points.dropFirst().forEach { path.line(to: $0) }
                path.close()
                NSColor.white.setStroke()
                path.lineWidth = 2
                path.lineJoinStyle = .round
                path.stroke()
                NSColor.black.setFill()
                path.fill()
                return true
            }
            return NSCursor(image: image, hotSpot: .init(x: 12, y: 12))
        }()
    }
}

/// The terminal font size row's control: 小 / 中 / 大 as one-click segments, plus 你话事,
/// which swaps the last segment for a field holding any whole point.
///
/// One highlight slides between the four slots. The custom slot has a saved identity separate
/// from its number, so entering 18px does not silently turn into the 大 preset.
private struct TerminalFontSizeControl: View {
    let points: Double
    let isCustom: Bool
    let onChange: (Double, Bool) -> Void

    /// Only committed values reach the model; a half-typed field stays local.
    @State private var draft = ""
    @State private var editingCustom = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let segmentWidth: CGFloat = 52
    private static let customWidth: CGFloat = 64
    private static let height: CGFloat = 34

    private var selectedIndex: Int {
        if editingCustom || isCustom { return TerminalFontSize.presets.count }
        return TerminalFontSize.presets.firstIndex { $0.name == TerminalFontSize.preset(for: points) }
            ?? 0
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TerminalFontSize.presets, id: \.name) { preset in
                segment(preset.name, isOn: selectedIndex < TerminalFontSize.presets.count
                    && TerminalFontSize.preset(for: points) == preset.name) {
                    selectPreset(preset.points)
                }
            }
            customSegment
        }
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(editingCustom ? Theme.panel : Theme.accent)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(editingCustom ? Theme.accent : Color.clear, lineWidth: 1)
                }
                .frame(
                    width: selectedIndex == TerminalFontSize.presets.count
                        ? Self.customWidth : Self.segmentWidth,
                    height: Self.height - 6
                )
                .offset(x: CGFloat(selectedIndex) * Self.segmentWidth)
                .animation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.18), value: selectedIndex)
        }
        .padding(3)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.panelSecondary)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        )
        .background {
            if editingCustom {
                GeometryReader { proxy in
                    FontSizeOutsideClickMonitor { finishCustomEditing() }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .onDisappear { finishCustomEditing() }
    }

    private func segment(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isOn ? .medium : .regular))
                .foregroundStyle(isOn ? Theme.terminalText : Theme.muted)
                .frame(width: Self.segmentWidth, height: Self.height - 6)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("\(title)（\(Int(TerminalFontSize.presets.first { $0.name == title }?.points ?? 0)) px）")
        .accessibilityLabel("终端字号 \(title)")
    }

    /// The fourth slot: a segment until it is picked, a field afterwards. It keeps its width, so
    /// picking it never reflows the row.
    private var customSegment: some View {
        Group {
            if editingCustom {
                HStack(spacing: 2) {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .focused($fieldFocused)
                        .onSubmit(finishCustomEditing)
                        .onAppear { fieldFocused = true }
                        .frame(width: 30)
                        .accessibilityLabel("终端字号，单位像素")
                    Text("px")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 5)
                .frame(width: Self.customWidth, height: Self.height - 6)
            } else {
                Button(action: beginCustom) {
                    Text(isCustom ? "\(Int(points))px" : "你话事")
                        .font(.system(size: 12))
                        .foregroundStyle(isCustom ? Theme.terminalText : Theme.muted)
                        .frame(width: Self.customWidth, height: Self.height - 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("输入 12–24 之间的任意字号")
                .accessibilityLabel(isCustom ? "终端字号，\(Int(points)) 像素" : "终端字号，你话事")
            }
        }
        .onChange(of: fieldFocused) { _, focused in
            // Let a preset button handle its own click before a focus change can commit the
            // unfinished draft. Tabbing away still commits on the next main-loop turn.
            if !focused {
                DispatchQueue.main.async { finishCustomEditing() }
            }
        }
    }

    private func beginCustom() {
        draft = isCustom ? Self.text(for: points) : ""
        editingCustom = true
    }

    private func selectPreset(_ points: Double) {
        editingCustom = false
        fieldFocused = false
        draft = ""
        onChange(points, false)
    }

    private func finishCustomEditing() {
        guard editingCustom else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        let entered = Int(trimmed).map { TerminalFontSize.clamp(Double($0)) }
        editingCustom = false
        fieldFocused = false
        draft = ""
        if let entered { onChange(entered, true) }
    }

    private static func text(for points: Double) -> String {
        String(Int(TerminalFontSize.clamp(points)))
    }
}

/// Watch the whole App window while the inline field is open. A page-level SwiftUI tap gesture
/// can also fire on the click that opens the field, so it cannot reliably dismiss this editor.
private struct FontSizeOutsideClickMonitor: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onOutsideClick: onOutsideClick) }

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onOutsideClick = onOutsideClick
        context.coordinator.installIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        weak var view: NSView?
        var onOutsideClick: () -> Void
        private var monitor: Any?

        init(onOutsideClick: @escaping () -> Void) {
            self.onOutsideClick = onOutsideClick
        }

        func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let view = self.view, let window = view.window,
                      event.window === window else { return event }
                let location = view.convert(event.locationInWindow, from: nil)
                if !view.bounds.contains(location) { self.onOutsideClick() }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

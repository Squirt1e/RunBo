import AppKit
import SwiftUI
import Core

private enum FileBrowserWorkspaceSpace {
    static let name = "file-browser-workspace"
}

struct FileBrowserWorkspace<Content: View>: View {
    @ObservedObject var coordinator: FileBrowserCoordinator
    @ObservedObject var card: FileBrowserCard
    let root: URL
    let report: (String) -> Void
    @ViewBuilder var content: (@escaping () -> Void) -> Content
    /// Live drag width stays local until mouse-up. Writing the observable coordinator on
    /// every frame re-rendered the whole view tree (terminal included) while the pointer was
    /// still on the moving divider, which made the divider jump back and forth.
    @State private var draggingWidth: Double?
    @State private var dragStart: (width: Double, x: CGFloat)?
    @State private var toolbarHeight: CGFloat = 0
    private var panelWidth: Double { FileBrowserLayout.width(draggingWidth ?? coordinator.panelWidth) }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                content { coordinator.toggle(requestFocus: true) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if coordinator.isVisible && coordinator.isPinned {
                    FileBrowserDivider(
                        width: { panelWidth },
                        dragBegan: { x in
                            guard dragStart == nil else { return }
                            dragStart = (FileBrowserLayout.width(coordinator.panelWidth), x)
                        },
                        dragChanged: { x in
                            guard let start = dragStart else { return }
                            draggingWidth = FileBrowserLayout.draggedWidth(start: start.width, translation: x - start.x)
                        },
                        dragEnded: { x in
                            defer { draggingWidth = nil; dragStart = nil }
                            guard let start = dragStart else { return }
                            coordinator.panelWidth = FileBrowserLayout.draggedWidth(start: start.width, translation: x - start.x)
                            coordinator.saveWidth(report: report)
                        },
                        reset: {
                            draggingWidth = nil
                            dragStart = nil
                            coordinator.panelWidth = FileBrowserLayout.defaultWidth
                            coordinator.saveWidth(report: report)
                        }
                    )
                    panel.frame(width: panelWidth)
                }
            }
            .coordinateSpace(name: FileBrowserWorkspaceSpace.name)
            .overlay(alignment: .trailing) {
                if coordinator.isVisible && !coordinator.isPinned {
                    ZStack(alignment: .trailing) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { coordinator.close() }
                        panel.frame(width: min(panelWidth, geometry.size.width))
                            .shadow(color: .black.opacity(0.2), radius: 12, x: -4, y: 0)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    // Floating and docked use the same panel; only its placement changes.
                    // Measure the entire terminal toolbar, including its directory subtitle.
                    .padding(.top, toolbarHeight)
                }
            }
            .overlay {
                if let request = coordinator.preview {
                    FilePreviewLayer(request: request, close: { coordinator.closePreview() }, report: report)
                        .id(request.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .onPreferenceChange(TerminalToolbarHeightKey.self) { toolbarHeight = $0 }
            .onChange(of: coordinator.isVisible) { _, value in if value { card.open() } }
            .task(id: root) {
                card.setRoot(root)
                coordinator.closePreview()
                if coordinator.isVisible { card.open() }
            }
        }
        .onDisappear { coordinator.presentationChanged() }
    }

    private var panel: some View {
        FileBrowserPanel(card: card, coordinator: coordinator, report: report)
    }
}

struct TerminalToolbarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The 10pt gap stays visually empty until the pointer arrives. On hover it gains the same
/// resize cursor and small grabber as the sidebar, so the width is discoverable without
/// adding a third permanent border between two framed panels.
private struct FileBrowserDivider: View {
    let width: () -> Double
    let dragBegan: (CGFloat) -> Void
    let dragChanged: (CGFloat) -> Void
    let dragEnded: (CGFloat) -> Void
    let reset: () -> Void
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            if hovering {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Theme.muted.opacity(0.5))
                    .frame(width: 5, height: 26)
            }
        }
        .frame(width: 10)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            // A view removed while the pointer is still over it never receives the exit callback.
            if hovering { NSCursor.pop(); hovering = false }
            dragging = false
        }
        // The divider moves while it is dragged. Measuring the gesture in a fixed
        // ancestor space keeps `location` independent of that movement; the default local
        // space fed the divider's own displacement back into the next sample.
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(FileBrowserWorkspaceSpace.name))
            .onChanged { value in
                if !dragging {
                    dragging = true
                    dragBegan(value.startLocation.x)
                }
                dragChanged(value.location.x)
            }
            .onEnded { value in
                dragging = false
                dragEnded(value.location.x)
            })
        .simultaneousGesture(TapGesture(count: 2).onEnded(reset))
        .workbenchControlFrame("file-browser-divider")
        .help("拖动调整文件栏宽度，双击恢复默认")
        .accessibilityElement()
        .accessibilityLabel("文件面板宽度")
        .accessibilityValue("\(Int(width()))")
        .accessibilityHint("拖动调整宽度，双击恢复默认")
    }
}

private struct FileBrowserPanel: View {
    @ObservedObject var card: FileBrowserCard
    @ObservedObject var coordinator: FileBrowserCoordinator
    let report: (String) -> Void
    @FocusState private var treeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Label("文件", systemImage: "folder").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                icon(coordinator.isPinned ? "pin.fill" : "pin", coordinator.isPinned ? "取消固定，悬浮显示" : "固定在终端右侧") {
                    coordinator.togglePinned(report: report)
                }
                .foregroundStyle(coordinator.isPinned ? Theme.accent : Theme.muted)
                .background(coordinator.isPinned ? Theme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .accessibilityValue(coordinator.isPinned ? "已固定" : "悬浮")
                .accessibilityIdentifier("file-browser-pin")
                .workbenchControlFrame("file-browser-pin")
                icon("arrow.clockwise", "刷新文件目录") { card.refresh() }
                Menu {
                    Button(card.state.showHidden ? "隐藏点号文件" : "显示隐藏文件") { card.toggleHidden() }
                    Button("全部折叠") { card.state.expanded = [] }
                    Divider()
                    Button("复制根目录路径") { BrowserActions.copy(card.state.root.path) }
                    Button("在 Finder 中打开工作目录") { BrowserActions.reveal(root: card.state.root) }
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("文件目录选项")
                .accessibilityLabel("文件目录选项")
                icon("xmark", "关闭文件栏") { coordinator.close() }
            }
            .padding(12)
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 6) {
                Text("卡片工作目录").font(.system(size: 11)).foregroundStyle(Theme.muted)
                HStack {
                    Text(card.state.root.lastPathComponent.isEmpty ? "/" : card.state.root.lastPathComponent)
                        .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    icon("arrow.up.forward.square", "在 Finder 中打开工作目录") { BrowserActions.reveal(root: card.state.root) }
                }
                Text((card.state.root.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted)
                    .lineLimit(2).truncationMode(.middle)
            }
            .padding(12).help(card.state.root.path)
            Divider().overlay(Theme.line)
            tree
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 6) {
                if let entry = card.selection {
                    Text("\(entry.name) · \(entry.isSymbolicLink ? "符号链接" : entry.isDirectory ? "文件夹" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))")
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.muted)
                    if entry.isRegularFile && !entry.isSymbolicLink {
                        Button(previewHint(entry)) { preview(entry) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                    } else if entry.isSymbolicLink {
                        Text("不跟随链接；可在 Finder 中查看").foregroundStyle(Theme.muted)
                    }
                } else { Text("选择文件以只读预览").foregroundStyle(Theme.muted) }
            }
            .font(.system(size: 11)).padding(12).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        }
        .foregroundStyle(Theme.text)
        .background(Theme.panelSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        .workbenchControlFrame("file-browser-panel")
        .task(id: coordinator.focusTreeGeneration) {
            if coordinator.shouldFocusTree { treeFocused = true }
        }
    }

    private var tree: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    directoryStatus("")
                    ForEach(card.rows) { row in
                        rowView(row)
                            .id(row.id)
                        if row.entry.expandable && card.state.expanded.contains(row.id) {
                            directoryStatus(row.id).padding(.leading, CGFloat(row.depth + 1) * 14)
                        }
                    }
                }
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .scrollTargetLayout()
                .appScrollbars()
            }
            .scrollPosition(id: Binding(get: { card.state.scrollAnchor }, set: { card.state.scrollAnchor = $0 }), anchor: .top)
            .focusable().focused($treeFocused).focusEffectDisabled()
            .onKeyPress(.upArrow) { navigate(-1, proxy: proxy); return .handled }
            .onKeyPress(.downArrow) { navigate(1, proxy: proxy); return .handled }
            .onKeyPress(.rightArrow) {
                guard let entry = card.selection else { return .ignored }
                if entry.expandable && !card.state.expanded.contains(entry.id) { card.toggle(entry) }
                else if entry.expandable, let child = card.listings[entry.id]?.first {
                    card.state.selected = child.id; proxy.scrollTo(child.id)
                }
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard let entry = card.selection else { return .ignored }
                if card.state.expanded.contains(entry.id) { card.toggle(entry) }
                else {
                    let parent = (entry.id as NSString).deletingLastPathComponent
                    if !parent.isEmpty { card.state.selected = parent; proxy.scrollTo(parent) }
                }
                return .handled
            }
            .onKeyPress(.space) {
                guard let entry = card.selection, entry.isRegularFile, !entry.isSymbolicLink else { return .ignored }
                preview(entry); return .handled
            }
            .onKeyPress(.return) {
                guard let entry = card.selection else { return .ignored }
                if entry.expandable { card.toggle(entry) } else { preview(entry) }
                return .handled
            }
        }
    }

    @ViewBuilder private func directoryStatus(_ path: String) -> some View {
        if card.loading.contains(path) {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("读取中…") }.font(.system(size: 11)).padding(6)
        } else if let error = card.errors[path] {
            VStack(alignment: .leading, spacing: 5) {
                Text(error).foregroundStyle(Theme.muted)
                Button("重试") { card.load(path) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            }.font(.system(size: 11)).padding(6)
        } else if card.listings[path]?.isEmpty == true {
            Text("目录为空").font(.system(size: 11)).foregroundStyle(Theme.muted).padding(8)
        }
    }

    private func rowView(_ row: FileBrowserCard.Row) -> some View {
        let entry = row.entry
        return HStack(spacing: 5) {
            Image(systemName: entry.expandable ? (card.state.expanded.contains(entry.id) ? "chevron.down" : "chevron.right") : "")
                .font(.system(size: 8, weight: .semibold)).frame(width: 9)
            Image(systemName: entry.isSymbolicLink ? "link" : entry.isDirectory ? "folder" : "doc.text")
                .foregroundStyle(entry.isDirectory ? Theme.accent : Theme.muted).frame(width: 15)
            Text(entry.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.leading, CGFloat(row.depth) * 14 + 5).padding(.trailing, 5).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 5).fill(card.state.selected == entry.id ? Theme.accent.opacity(treeFocused ? 0.16 : 0.09) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            treeFocused = true; card.state.selected = entry.id
            if !entry.expandable { preview(entry) }
        }
        .onTapGesture {
            treeFocused = true; card.state.selected = entry.id
            if entry.expandable { card.toggle(entry) }
        }
        .contextMenu {
            if entry.isRegularFile && !entry.isSymbolicLink {
                if BrowserPreviewKind.classify(entry.name) == .html {
                    // HTML's primary action is the default app; this keeps the bounded static
                    // page renderer available without making it the double-click surprise.
                    Button("在 App 中预览页面") { coordinator.showPreview(entry, root: card.state.root) }
                } else {
                    Button("快速预览") { preview(entry) }
                }
            }
            Button("复制绝对路径") { BrowserActions.copy(card.state.root.appendingPathComponent(entry.id).path) }
            Button("复制相对路径") { BrowserActions.copy(entry.id) }
            if entry.isRegularFile && BrowserPreviewKind.canOpenExternally(name: entry.name, executable: entry.executable, symbolicLink: entry.isSymbolicLink) {
                Button("默认应用打开") { BrowserActions.open(root: card.state.root, entry: entry, failure: report) }
            }
            Button("在 Finder 中显示") { BrowserActions.reveal(root: card.state.root, entry: entry) }
        }
        .help(entry.id + (entry.isSymbolicLink ? "（符号链接，不跟随）" : ""))
        .accessibilityLabel(entry.name + (entry.isSymbolicLink ? "，符号链接" : entry.isDirectory ? "，文件夹" : ""))
        .accessibilityAddTraits(card.state.selected == entry.id ? .isSelected : [])
    }

    private func navigate(_ delta: Int, proxy: ScrollViewProxy) {
        let rows = card.rows
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex(where: { $0.id == card.state.selected }) ?? (delta > 0 ? -1 : rows.count)
        let selected = rows[min(rows.count - 1, max(0, index + delta))].id
        card.state.selected = selected
        proxy.scrollTo(selected)
    }
    private func preview(_ entry: BrowserEntry) {
        card.state.selected = entry.id
        if BrowserPreviewKind.opensExternallyByDefault(name: entry.name, executable: entry.executable,
                                                       symbolicLink: entry.isSymbolicLink) {
            BrowserActions.open(root: card.state.root, entry: entry, failure: report)
        } else {
            coordinator.showPreview(entry, root: card.state.root)
        }
    }
    private func previewHint(_ entry: BrowserEntry) -> String {
        BrowserPreviewKind.opensExternallyByDefault(name: entry.name, executable: entry.executable,
                                                    symbolicLink: entry.isSymbolicLink)
            ? "空格 / 双击 默认应用打开" : "空格 / 双击 快速预览"
    }
    private func icon(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 20, height: 24) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
}

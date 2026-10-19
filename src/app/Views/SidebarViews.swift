import AppKit
import SwiftUI
import Core

struct SidebarHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: SidebarPresentation
    @FocusState private var toggleFocused: Bool
    @FocusState private var pinFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button { model.toggleSidebar() } label: {
                Image(systemName: presentation.mode == .pinned ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 16)).frame(width: 40, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(IconPressStyle()).focused($toggleFocused)
            .help(presentation.mode == .pinned ? "折叠菜单栏（⌘⌥S）" : "固定展开菜单栏（⌘⌥S）")
            .accessibilityLabel(presentation.mode == .pinned ? "折叠菜单栏" : "固定展开菜单栏")
            .accessibilityValue(presentation.mode == .pinned ? "固定展开" : presentation.peeking ? "临时展开" : "已折叠")
            .workbenchControlFrame("sidebar-toggle")
            if presentation.expanded {
                Text("RunBo").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button { model.toggleSidebar() } label: {
                    Image(systemName: presentation.mode == .pinned ? "pin.fill" : "pin")
                        .font(.system(size: 13)).frame(width: 30, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(IconPressStyle()).focused($pinFocused)
                .foregroundStyle(presentation.mode == .pinned ? Theme.accent : Theme.muted)
                .help(presentation.mode == .pinned ? "取消固定并折叠" : "固定侧栏，内容将重新分配宽度")
                .accessibilityLabel(presentation.mode == .pinned ? "取消固定侧栏" : "固定侧栏")
                .workbenchControlFrame("sidebar-pin")
            }
        }
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 8).frame(height: 48)
        .onChange(of: toggleFocused) { _, value in presentation.headerFocusChanged(value || pinFocused) }
        .onChange(of: pinFocused) { _, value in presentation.headerFocusChanged(value || toggleFocused) }
        .onChange(of: presentation.focusToggleGeneration) { _, _ in toggleFocused = true }
    }
}

/// Condensed navigation only. Commands and destructive actions remain in their existing surfaces.
struct SidebarRail: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: SidebarPresentation
    @FocusState private var focused: SidebarNode?

    var body: some View {
        VStack(spacing: 0) {
            railButton(.search, symbol: "magnifyingglass", title: "查找项目（⌘K）") { model.openQuickNavigation() }
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        if model.splitMode.isOn {
                            navigation(.home)
                            navigation(.menu(.preset))
                            ForEach(model.sidebarRailPresetGroups) { group in railGroup(group) }
                            navigation(.menu(.temp))
                            if !model.sidebarRailTerminals.isEmpty {
                                railGroup(SidebarRailGroup(id: "terminals", title: "", owners: model.sidebarRailTerminals))
                            }
                        } else {
                            navigation(.menu(.preset))
                            navigation(.menu(.temp))
                        }
                    }
                    .frame(width: SidebarLayout.railWidth)
                    .padding(.bottom, 12)
                }
                // Legacy system scrollers would reserve 17pt and clip the 44pt containers.
                // The compact rail scrolls normally; full labels and scrollers remain in the expanded sidebar.
                .scrollIndicators(.never)
                .task(id: model.splitSelection) {
                    await Task.yield()
                    guard !Task.isCancelled, let key = model.splitSelection else { return }
                    scroll.scrollTo(SidebarNode.owner(key).scrollID)
                }
            }
            Spacer(minLength: 0)
            if !model.copyKeys.isEmpty {
                Button { presentation.focus(.search) } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "square.on.square").font(.system(size: 14)).frame(width: 40, height: 36)
                        Text("\(model.copyKeys.count)").font(.system(size: 9)).foregroundStyle(Theme.accent)
                    }
                }
                .buttonStyle(IconPressStyle()).help("展开侧栏管理临时分身，不直接解除")
                .accessibilityLabel("展开侧栏，管理 \(model.copyKeys.count) 个临时分身")
            }
            railButton(.settings, symbol: "gearshape", title: "设置") { model.navigate(to: .settings) }
                .padding(.top, 3).padding(.bottom, 10)
                .frame(width: SidebarLayout.railWidth)
                .overlay(alignment: .top) { Rectangle().fill(SidebarRailTheme.groupLine).frame(height: 1) }
        }
        .frame(width: SidebarLayout.railWidth)
        .onChange(of: focused) { _, node in
            guard let node, InputSource.current != .pointer else { return }
            presentation.focus(node)
        }
        .onMoveCommand { direction in
            let nodes: [SidebarNode] = [.search] + (model.splitMode.isOn
                ? model.sidebarNavigationNodes.filter { if case .tag = $0 { return false }; return true }
                : [.menu(.preset), .menu(.temp), .settings])
            guard let focused, let index = nodes.firstIndex(of: focused) else { return }
            if direction == .down { self.focused = nodes[min(nodes.count - 1, index + 1)] }
            if direction == .up { self.focused = nodes[max(0, index - 1)] }
        }
    }

    @ViewBuilder private func navigation(_ node: SidebarNode) -> some View {
        switch node {
        case .home:
            railButton(node, symbol: "house", title: "首页", selected: model.page == .presets) { model.goHome() }
                .padding(.bottom, 5)
        case .menu(let kind):
            railButton(node, symbol: kind == .preset ? "square.stack.3d.up" : "terminal",
                       title: kind == .preset ? "快捷指令" : "终端", caption: kind == .preset ? "指令" : "终端",
                       selected: !model.splitMode.isOn && model.selectedKind == kind) {
                if model.splitMode.isOn { model.expandSidebarMenu(kind); presentation.focus(node) }
                else { model.navigate(to: kind == .preset ? .presets : .temps) }
            }
            .padding(.bottom, 6)
        case .tag: EmptyView()
        case .owner(let key):
            ownerButton(key)
        default: EmptyView()
        }
    }

    private func railGroup(_ group: SidebarRailGroup) -> some View {
        VStack(spacing: 0) {
            if !group.title.isEmpty {
                Text(group.title).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.tail).padding(.horizontal, 2)
                    .frame(width: SidebarLayout.ownerWidth, height: 20)
                    .help(group.title).accessibilityLabel("\(group.title) 分组")
            }
            ForEach(group.owners, id: \.self) { key in ownerButton(key) }
        }
        .padding(.bottom, 5)
        .frame(width: SidebarLayout.groupWidth)
        .background(SidebarRailTheme.group, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(SidebarRailTheme.groupLine, lineWidth: 1).allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .workbenchControlFrame("rail-group-" + group.id)
        .padding(.bottom, SidebarLayout.groupSpacing)
    }

    private func railButton(_ node: SidebarNode, symbol: String, title: String, caption: String? = nil,
                            selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: node == .home ? Theme.homeIconSize : Theme.menuIconSize))
                if let caption { Text(caption).font(.system(size: 8)).lineLimit(1) }
            }
            .frame(width: 40, height: caption == nil ? (node == .home ? 44 : 40) : 38)
            .background(selected ? Theme.navSelection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .top) {
                if caption != nil { Rectangle().fill(Theme.line).frame(height: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(IconPressStyle()).foregroundStyle(Theme.muted)
        .focused($focused, equals: node).help(title).accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .id(node.scrollID).workbenchControlFrame("rail-" + node.scrollID)
    }

    private func ownerButton(_ key: OwnerKey) -> some View {
        let title = key.kind == .preset ? (model.card(for: key.ownerId)?.title ?? "") : (model.temp(for: key.ownerId)?.title ?? "")
        let selected = model.splitSelection == key
        let status = model.presentation(for: key)
        let description = [status.label, status.badge].compactMap { $0 }.joined(separator: " · ")
        return Button { model.selectSplitItem(key) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(selected ? SidebarRailTheme.selected : .clear)
                SidebarRailTile(monogram: SidebarLayout.monogram(title: title, terminal: key.kind == .temp),
                                kind: .of(status), motionEnabled: !presentation.expanded)
                if selected {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.text).frame(width: 2, height: 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: SidebarLayout.ownerWidth, height: SidebarLayout.ownerHeight).contentShape(Rectangle())
        }
        .buttonStyle(IconPressStyle()).foregroundStyle(Theme.text)
        .focused($focused, equals: .owner(key))
        .help("\(title) · \(description)；打开详情，不重新执行")
        .accessibilityLabel("\(title)，\(description)").accessibilityHint("打开详情，不启动或重启终端")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .id(SidebarNode.owner(key).scrollID).workbenchControlFrame("rail-owner-" + key.ownerId)
    }
}

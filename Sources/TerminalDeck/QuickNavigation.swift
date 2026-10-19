import AppKit
import SwiftUI
import TerminalDeckKit

struct QuickNavigationItem: Identifiable {
    enum Destination { case owner(OwnerKey), home, settings, mode(WorkhorseMode) }
    let id: String
    let title: String
    let subtitle: String
    let searchText: String
    let symbol: String
    let destination: Destination
    var presentation: SessionStatusPresentation? = nil
}

extension AppModel {
    /// Saved configuration only. Never examines raw terminal input or queries SQLite during render.
    func quickNavigationResults(matching query: String) -> [QuickNavigationItem] {
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        }
        let words = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let entries: [(OwnerKey, String, String, String, String)] = cards.map { card in
            (OwnerKey(kind: .preset, ownerId: card.id), card.title, card.command,
             tags.first(where: { $0.id == card.tagId })?.name ?? "", "square.stack.3d.up")
        } + temps.map { temp in
            (OwnerKey(kind: .temp, ownerId: temp.id), temp.title,
             temp.launchConfiguration?.workingDirectory ?? "本机终端", "", "terminal")
        }
        var items = entries.filter { vanishing[$0.0] == nil && !removingCopies.contains($0.0) }.sorted { a, b in
            let aDate = lastRuntime[a.0]?.startedAt ?? storedLastSession[a.0]?.startedAt ?? .distantPast
            let bDate = lastRuntime[b.0]?.startedAt ?? storedLastSession[b.0]?.startedAt ?? .distantPast
            return aDate == bDate ? a.0.ownerId < b.0.ownerId : aDate > bDate
        }.map { key, title, subtitle, tag, symbol in
            QuickNavigationItem(id: "\(key.kind.rawValue):\(key.ownerId)",
                                title: isDisposableCopy(key) ? "\(title) · 分身" : title,
                                subtitle: subtitle.replacingOccurrences(of: "\n", with: " "),
                                searchText: title + " " + subtitle + " " + tag,
                                symbol: symbol, destination: .owner(key), presentation: presentation(for: key))
        }
        items += [
            QuickNavigationItem(id: "home", title: workhorseMode.isOn ? "返回工作台" : "打开快捷指令",
                                subtitle: "仅导航，不影响会话", searchText: "首页 工作台 快捷指令 home", symbol: "house", destination: .home),
            QuickNavigationItem(id: "switch-mode", title: workhorseMode.isOn ? "切换到标准模式" : "切换到牛马模式",
                                subtitle: "仅切换视图，运行中的终端保持不变",
                                searchText: "切换 模式 标准 卡片 牛马 视图 mode layout switch",
                                symbol: "rectangle.2.swap", destination: .mode(workhorseMode.isOn ? .off : .on)),
            QuickNavigationItem(id: "settings", title: "打开设置", subtitle: "⌘ ,", searchText: "设置 settings", symbol: "gearshape", destination: .settings),
        ]
        return items.filter { item in words.allSatisfy { normalized(item.searchText).contains($0) } }
    }

    func activateQuickNavigation(_ item: QuickNavigationItem) {
        closeQuickNavigation(restoringFocus: false)
        switch item.destination {
        case .owner(let key):
            guard (key.kind == .preset ? card(for: key.ownerId) != nil : temp(for: key.ownerId) != nil),
                  vanishing[key] == nil, !removingCopies.contains(key) else {
                showError("该项目已不存在或正在移除，请重新查找。")
                return
            }
            leaveEditorIfNeeded { [weak self] in self?.openDetail(key) }
        case .home: goHome()
        case .settings: navigate(to: .settings)
        case .mode(let mode): changeWorkhorseMode(mode)
        }
    }
}

/// Keyboard-driven overlay. No entrance/exit animation; a search is never a command.
struct QuickNavigationLayer: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var highlightedID: String?
    private enum Focus: Hashable { case input, close, result(String) }
    @FocusState private var focus: Focus?
    private var composing: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true }
    private var results: [QuickNavigationItem] { model.quickNavigationResults(matching: query) }

    var body: some View {
        if model.quickNavigationPresented {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    Color.black.opacity(0.22).contentShape(Rectangle())
                        .onTapGesture { model.closeQuickNavigation() }
                        .accessibilityHidden(true)
                    palette
                        .frame(width: min(590, max(0, geometry.size.width - 40)))
                        .padding(.top, min(120, max(24, geometry.size.height * 0.14)))
                }
            }
            .onAppear { query = ""; highlightedID = results.first?.id }
            .onDisappear { model.restoreQuickNavigationFocus() }
            .onChange(of: focus) { _, value in if case .result(let id) = value { highlightedID = id } }
            .onChange(of: results.map(\.id)) { _, ids in
                if !ids.contains(highlightedID ?? "") { highlightedID = ids.first }
            }
        }
    }

    private var palette: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(DeckTheme.accent)
                TextField("查找快捷指令、终端或操作…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .focused($focus, equals: .input).onSubmit { if !composing { choose() } }
                    .task { await Task.yield(); focus = .input }
                    .onKeyPress(.downArrow) { guard !composing else { return .ignored }; move(1); return .handled }
                    .onKeyPress(.upArrow) { guard !composing else { return .ignored }; move(-1); return .handled }
                    .onKeyPress(.escape) { guard !composing else { return .ignored }; model.closeQuickNavigation(); return .handled }
                    .accessibilityIdentifier("quick-navigation-input")
                    .accessibilityLabel("查找项目或切换模式，方向键选择，回车确认，不执行终端命令")
                Button("esc") { model.closeQuickNavigation() }
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                    .buttonStyle(.plain).focused($focus, equals: .close).accessibilityLabel("关闭快速导航")
            }
            .padding(18)
            Divider().overlay(DeckTheme.line)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if results.isEmpty {
                            Text("没有匹配项目。回车不会执行输入内容。")
                                .font(.system(size: 12)).foregroundStyle(DeckTheme.muted).padding(20)
                        }
                        ForEach(results) { item in
                            result(item).id(item.id)
                        }
                    }
                    .padding(8)
                    .deckScrollbars()
                }
                .frame(height: min(330, max(80, CGFloat(results.count) * 58 + 16)))
                .onChange(of: highlightedID) { _, id in if let id { proxy.scrollTo(id) } }
            }
            Divider().overlay(DeckTheme.line)
            HStack {
                Text("↑ ↓ 选择   ↵ 确认")
                Spacer()
                Text("打开项目或切换视图，不执行命令")
            }
            .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).padding(.horizontal, 18).padding(.vertical, 12)
        }
        .foregroundStyle(DeckTheme.text).background(DeckTheme.panel, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(DeckTheme.line))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 14)
        .accessibilityElement(children: .contain).accessibilityLabel("快速导航")
        .accessibilityAddTraits(.isModal)
        .onKeyPress(.tab, phases: .down) { press in
            let stops: [Focus] = [.input] + results.map { .result($0.id) } + [.close]
            let index = stops.firstIndex(of: focus ?? .input) ?? 0
            let step = press.modifiers.contains(.shift) ? -1 : 1
            focus = stops[(index + step + stops.count) % stops.count]
            return .handled
        }
    }
    private func result(_ item: QuickNavigationItem) -> some View {
        Button { model.activateQuickNavigation(item) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.symbol).font(.system(size: 14)).foregroundStyle(DeckTheme.muted)
                    .frame(width: 30, height: 30).background(DeckTheme.background, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(item.subtitle).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DeckTheme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let status = item.presentation {
                    Text(status.label).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
                if highlightedID == item.id { Image(systemName: "return").font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(highlightedID == item.id ? DeckTheme.navSelection : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focus, equals: .result(item.id))
        .onHover { if $0 { highlightedID = item.id } }
        .accessibilityLabel("\(item.title)，\(item.presentation?.label ?? item.subtitle)")
        .accessibilityHint("确认此选项，不执行或重启终端命令")
        .accessibilityAddTraits(highlightedID == item.id ? .isSelected : [])
    }
    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == highlightedID } ?? (delta > 0 ? -1 : 0)
        highlightedID = results[(index + delta + results.count) % results.count].id
    }
    private func choose() {
        guard let selected = results.first(where: { $0.id == highlightedID }) ?? results.first else { return }
        model.activateQuickNavigation(selected)
    }
}

struct QuickNavigationButton: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button { model.openQuickNavigation() } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("查找项目或操作")
                Spacer(minLength: 4)
                Text("⌘ K").font(.system(size: 10, design: .monospaced))
            }
            .font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
            .padding(.horizontal, 10).frame(height: 32)
            .background(DeckTheme.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DeckTheme.line))
        }
        .buttonStyle(DeckIconPressStyle()).help("查找项目或切换模式（⌘K），不会执行终端命令")
        .accessibilityLabel("查找项目，Command K")
    }
}

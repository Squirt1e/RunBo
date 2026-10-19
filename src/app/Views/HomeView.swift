import SwiftUI
import Core

/// A task-first, read-only projection. Opening an item never starts or restarts its shell.
struct HomeView: View {
    let snapshot: HomeSnapshot
    let onOpen: (HomeDestination) -> Void
    @State private var showsAllWorking = false
    @State private var showsAllAttention = false

    var body: some View {
        GeometryReader { viewport in
            let layout = HomeLayout(width: viewport.size.width, height: viewport.size.height)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(layout)
                    metrics(layout)
                    worksite(layout).padding(.top, 24)
                    recents(layout).padding(.top, 24)
                    Spacer(minLength: 24)
                    footer
                }
                .frame(width: layout.contentWidth)
                .padding(.top, 20)
                .padding(.bottom, 18)
                .frame(minHeight: max(0, viewport.size.height), alignment: .top)
                .frame(maxWidth: .infinity)
                .appScrollbars()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(SplitTheme.background)
    }

    private func hero(_ layout: HomeLayout) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("YOUR COMMAND CENTER")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.7).foregroundStyle(SplitTheme.accentText)
                Text("让命令各就各位。")
                    .font(.system(size: layout.titleSize, weight: .semibold))
                    .tracking(-0.6).foregroundStyle(SplitTheme.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                Text("逼格拉满，干活不慢。今天也从容开工。")
                    .font(.system(size: 12)).foregroundStyle(SplitTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if layout.showsEmblem {
                VStack(spacing: 8) {
                    OxMarkView().frame(width: layout.emblemDiameter, height: layout.emblemDiameter)
                    Text("ALL SHOW. ALL GO.").font(.system(size: 8, design: .monospaced))
                        .tracking(1.2).foregroundStyle(SplitTheme.muted)
                }
                .frame(width: 136).accessibilityHidden(true)
            }
        }
        .frame(height: layout.heroHeight)
    }

    private func metrics(_ layout: HomeLayout) -> some View {
        HStack(spacing: 0) {
            metric(snapshot.executingCount, title: "任务执行中", color: SplitTheme.accentText, first: true, layout: layout)
            metric(snapshot.onlineCount, title: "终端在线", color: SplitTheme.green, first: false, layout: layout)
            metric(snapshot.attention.count, title: "需要留意", color: SplitTheme.red, first: false, layout: layout)
        }
        .padding(.vertical, 18)
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .bottom) { hairline }
    }

    private func metric(_ count: Int, title: String, color: Color, first: Bool, layout: HomeLayout) -> some View {
        HStack(spacing: layout.inlineMetrics ? 13 : 7) {
            Text(String(format: "%02d", count))
                .font(.system(size: layout.inlineMetrics ? 30 : 24, design: .monospaced))
                .tracking(-1.5).monospacedDigit().foregroundStyle(SplitTheme.text)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 4, height: 4)
                Text(title).font(.system(size: 11)).foregroundStyle(SplitTheme.muted).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, first ? 0 : 16)
        .overlay(alignment: .leading) {
            if !first { Rectangle().fill(SplitTheme.line).frame(width: 1, height: 30) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(count) 项")
    }

    private func worksite(_ layout: HomeLayout) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("工作现场", detail: "打开详情，不重启终端")
            // Problems precede activity, even if the user has many active tasks.
            ForEach(Array(snapshot.attention.prefix(showsAllAttention ? snapshot.attention.count : 1))) { item in
                attentionRow(item)
            }
            if snapshot.attention.count > 1 {
                disclosure(showsAllAttention ? "收起提醒" : "还有 \(snapshot.attention.count - 1) 项需要留意 · 查看全部") {
                    showsAllAttention.toggle()
                }
            }
            if snapshot.working.isEmpty {
                emptyRow("当前没有执行中的任务", detail: snapshot.onlineCount > 0
                         ? "\(snapshot.onlineCount) 个终端在线，随时可接着用" : "工作台已就位，随时可以开工")
            } else {
                CardGridLayout(mode: .wide, columnSizing: .fitItems) {
                    ForEach(Array(snapshot.working.prefix(showsAllWorking ? snapshot.working.count : layout.workingPreviewLimit))) { item in
                        HomeTaskCard(item: item) { onOpen(item.destination) }
                    }
                }
            }
            if snapshot.working.count > layout.workingPreviewLimit {
                disclosure(showsAllWorking ? "收起任务" : "查看全部任务（\(snapshot.working.count)）") { showsAllWorking.toggle() }
            }
        }
    }

    private func attentionRow(_ item: HomeItem) -> some View {
        Button { onOpen(item.attentionDestination) } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(SplitTheme.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(SplitTheme.text).lineLimit(1)
                    Text(item.attention?.label ?? "需要留意").font(.system(size: 11)).foregroundStyle(SplitTheme.muted)
                }
                Spacer(minLength: 4)
                Label(item.historySessionID == nil ? "查看详情" : "查看历史", systemImage: "arrow.up.right")
                    .font(.system(size: 11)).foregroundStyle(SplitTheme.red).fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SplitTheme.redBackground, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SplitTheme.redBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title)，\(item.attention?.label ?? "需要留意")")
        .accessibilityHint(item.historySessionID == nil ? "打开详情，不会重新启动" : "只读回放这次会话")
    }

    private func recents(_ layout: HomeLayout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("最近使用", detail: "按最近启动时间")
            if snapshot.recent.isEmpty {
                emptyRow(snapshot.hasRunHistory ? "最近使用的项目都在上方" : "还没有运行记录", detail: "不记录终端原始输入")
            } else {
                VStack(spacing: 0) {
                    hairline
                    ForEach(Array(snapshot.recent.prefix(3))) { item in
                        recentRow(item, roomy: layout.contentWidth >= 640)
                        hairline
                    }
                }
            }
        }
    }

    private func recentRow(_ item: HomeItem, roomy: Bool) -> some View {
        Button { onOpen(item.destination) } label: {
            HStack(spacing: 12) {
                Image(systemName: item.key.kind == .preset ? "square.stack.3d.up" : "terminal")
                    .font(.system(size: 13)).foregroundStyle(SplitTheme.muted).frame(width: 18)
                Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(SplitTheme.text)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                if roomy {
                    Text(item.subtitle.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(SplitTheme.muted)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let date = item.startedAt {
                    Text(date, style: .relative).font(.system(size: 10)).foregroundStyle(SplitTheme.muted).lineLimit(1)
                }
                Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(SplitTheme.muted)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(item.title)\n\(item.subtitle)\n打开详情，不启动或重启终端")
        .accessibilityLabel("\(item.title)，最近启动于\(item.startedAt?.formatted() ?? "未知时间")")
        .accessibilityHint("打开详情，不启动或重启终端")
    }

    private var footer: some View {
        HStack {
            Label("本机运行 · 数据仅存本地", systemImage: "checkmark.shield")
                .font(.system(size: 10)).foregroundStyle(SplitTheme.muted)
            Spacer(minLength: 12)
            Text("RunBo / AT YOUR COMMAND.").font(.system(size: 8, design: .monospaced))
                .tracking(0.6).foregroundStyle(SplitTheme.muted)
        }
    }
    private var hairline: some View { Rectangle().fill(SplitTheme.line).frame(height: 1) }
    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(SplitTheme.text).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text(detail).font(.system(size: 10)).foregroundStyle(SplitTheme.muted)
        }
    }
    private func disclosure(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.system(size: 11)).foregroundStyle(SplitTheme.accentText).buttonStyle(.plain)
    }
    private func emptyRow(_ title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 18)).foregroundStyle(SplitTheme.muted)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12)).foregroundStyle(SplitTheme.text)
                Text(detail).font(.system(size: 11)).foregroundStyle(SplitTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(18).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SplitTheme.line))
    }
}

private struct HomeTaskCard: View {
    let item: HomeItem
    let onOpen: () -> Void
    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 9) {
                    // Kept mounted while executing; keyboard navigation never disables this clock.
                    StatusDotView(kind: StatusDot.of(item.presentation))
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(item.presentation.isCommandBusy ? "执行中" : item.presentation.label)
                        .font(.system(size: 11)).foregroundStyle(SplitTheme.accentText).fixedSize()
                }
                Text(item.subtitle.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(SplitTheme.muted)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    if let date = item.startedAt { HomeSessionAge(startedAt: date) }
                    Spacer(minLength: 4)
                    Label("打开终端", systemImage: "arrow.up.right")
                        .font(.system(size: 11)).foregroundStyle(SplitTheme.muted).fixedSize()
                }
            }
            .foregroundStyle(SplitTheme.text).padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HomeCardStyle())
        .accessibilityLabel("\(item.title)，\(item.presentation.label)")
        .accessibilityHint("打开详情，不启动或重启终端")
    }
}
private struct HomeSessionAge: View {
    let startedAt: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            Text("会话时长 " + HomeFormatting.sessionDuration(since: startedAt, now: clock.date))
                .font(.system(size: 10, design: .monospaced)).monospacedDigit().foregroundStyle(SplitTheme.muted)
        }
    }
}
private struct HomeCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? SplitTheme.hover : SplitTheme.panel, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SplitTheme.line))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

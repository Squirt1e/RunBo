import SwiftUI
import Core

/// Shared by right-click, card ellipsis, and split-mode row menus.
struct CardOperationsMenu: View {
    @ObservedObject var model: AppModel
    let key: OwnerKey

    var body: some View {
        if key.kind == .preset {
            Button { model.createCopy(key) } label: { Label("创建分身", systemImage: "square.on.square") }
                .disabled(!model.canCreateCopy(key) || model.copyIsBusy(key))
            Divider()
        }
        if model.isDisposableCopy(key) {
            Button("保留为普通卡片") { model.retainCopy(key) }.disabled(model.copyIsBusy(key))
            Divider()
        }
        Button("标签…") { model.openTagPicker(for: key) }.disabled(model.copyIsBusy(key))
        if key.kind == .preset {
            Button("编辑") {
                if let card = model.card(for: key.ownerId) { model.beginEditCard(card) }
            }.disabled(model.copyIsBusy(key))
        }
        Divider()
        Button(model.isDisposableCopy(key) ? "解除分身" : "删除") {
            switch key.kind {
            case .preset:
                if let card = model.card(for: key.ownerId) { model.requestDeleteCard(card) }
            case .temp:
                if let temp = model.temp(for: key.ownerId) { model.requestDeleteTemp(temp) }
            }
        }.disabled(model.copyIsBusy(key))
    }
}

struct CardCopyBadge: View {
    var body: some View {
        Text("分身")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
            .accessibilityLabel("分身卡片，退出或重启 App 后清理")
    }
}

struct CardCopyActions: View {
    @ObservedObject var model: AppModel
    let key: OwnerKey
    /// 牛马列表里只留图标，和同一行的启动 / 终止 / 「…」同尺寸。
    var compact = false
    var showsHint = true
    var focus: FocusState<SidebarNode?>.Binding? = nil

    var body: some View {
        HStack(spacing: compact ? 2 : 8) {
            if !compact && showsHint {
                Text(model.removingCopies.contains(key) ? "解除中…" : model.isRunning(key) ? "解除会结束此终端" : "本次可重复运行")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            action("保留", icon: "pin", color: Theme.accent, primary: true) { model.retainCopy(key) }
            action(model.removingCopies.contains(key) ? "解除中…" : "解除", icon: "xmark",
                   color: Theme.destructive, primary: false) { model.removeCopy(key) }
        }
        .disabled(model.copyIsBusy(key) || model.copyReflowing)
        .accessibilityElement(children: .contain)
    }

    private func action(_ title: String, icon: String, color: Color, primary: Bool,
                        perform: @escaping () -> Void) -> some View {
        CardCopyActionButton(icon: icon, title: title, tint: color, compact: compact,
                             primary: primary, perform: perform,
                             focusTarget: focus.map { ActionTarget(node: .action(key, primary ? "retain" : "remove"), focus: $0) })
    }
}

/// 分身的「保留 / 解除」按钮。
///
/// 形状、底色与悬停反馈跟 `IconButton`（同一行的启动 / 终止 / 「…」）完全一致：以前用的
/// 是自绘的实心方块，在同一行里格格不入。牛马列表中它们只在悬停时出现，所以底色也要浅。
private struct CardCopyActionButton: View {
    let icon: String
    let title: String
    let tint: Color
    let compact: Bool
    let primary: Bool
    let perform: () -> Void
    var focusTarget: ActionTarget? = nil

    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                if !compact {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
            }
            .foregroundStyle(primary ? tint : (hovering ? Theme.red : Theme.muted))
            .frame(minWidth: compact ? nil : 68, minHeight: compact ? 26 : nil)
            .frame(width: compact ? 30 : nil, height: compact ? 22 : 30)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    // 和 `IconButton`（同一行的启动 / 终止 / 「…」）同一套：平时透明，
                    // 悬停才浮出一块底色；彩色图标本身已经把两颗按钮分开了。
                    .fill(hovering ? Theme.panelSecondary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(IconPressStyle())
        .modifier(ActionFocus(target: focusTarget, activate: perform))
        .focusEffectDisabled(false)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    private var helpText: String {
        primary ? "保留为普通卡片，不中断当前终端"
                : "解除此分身：会结束它仍在线的终端并清理本次输出；原卡不受影响"
    }
}

struct CopyGlobalPanel: View {
    @ObservedObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        if !model.copyKeys.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.on.square").font(.system(size: 13))
                        Text("临时分身")
                        Spacer(minLength: 4)
                        Text("\(model.copyKeys.count)").monospacedDigit()
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0)).font(.system(size: 9))
                    }
                    .foregroundStyle(Theme.muted).frame(minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("管理 \(model.copyKeys.count) 个临时分身")
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                if expanded {
                    Text("全 App · \(model.copyOnlineCount) 个终端在线").foregroundStyle(Theme.muted)
                    Button(model.removingCopies.isEmpty ? "解除全部分身…" : "解除中…") { model.removeAllCopies() }
                        .buttonStyle(PressButtonStyle(variant: .small))
                        .disabled(!model.removingCopies.isEmpty)
                    Text("不影响原卡和已保留卡；在线分身会先确认终止。")
                        .foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// Secondary copy actions live in the existing terminal toolbar, never in a separate row.
struct CopyDetailMenu: View {
    @ObservedObject var model: AppModel
    let key: OwnerKey

    var body: some View {
        if model.isDisposableCopy(key) {
            Menu {
                Button { model.retainCopy(key) } label: {
                    Label("保留为普通卡片", systemImage: "pin")
                }
                Divider()
                Button(role: .destructive) { model.removeCopy(key) } label: {
                    Label(model.removingCopies.contains(key) ? "解除中…" : "解除分身…", systemImage: "xmark")
                }
            } label: {
                HStack(spacing: 5) {
                    CardCopyBadge()
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 6).frame(height: 28)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(model.copyIsBusy(key) || model.copyReflowing)
            .help("分身选项：保留为普通卡片或解除分身")
            .accessibilityLabel("分身选项")
            .workbenchControlFrame("copy-detail-menu")
        }
    }
}

struct CopyDetailBar: View {
    @ObservedObject var model: AppModel
    let key: OwnerKey
    var body: some View {
        if model.isDisposableCopy(key) {
            HStack(spacing: 10) {
                CardCopyBadge()
                Text(model.isRunning(key) ? "解除会结束此终端" : "保留后下次打开仍在")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 0)
                CardCopyActions(model: model, key: key, showsHint: false)
            }
            .padding(10)
            .background(Theme.panelSecondary, in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

private struct CopyCardDecoration: ViewModifier {
    @ObservedObject var model: AppModel
    let key: OwnerKey
    let square: Bool
    func body(content: Content) -> some View {
        content
            .disabled(model.copyIsBusy(key) || model.copyReflowing)
            .overlay(alignment: !square && key.kind == .temp ? .topTrailing : .bottomLeading) {
                if model.isDisposableCopy(key) {
                    CardCopyActions(model: model, key: key, compact: true, showsHint: false)
                        .padding(.leading, square ? 14 : key.kind == .preset ? 15 : 0)
                        .padding(.trailing, !square && key.kind == .temp ? 15 : 0)
                        .padding(.top, !square && key.kind == .temp ? 6 : 0)
                        .padding(.bottom, square ? 53 : key.kind == .preset ? 15 : 0)
                }
            }
        .frame(maxWidth: square ? CardDisplay.cardHeight : .infinity, alignment: .top)
        .allowsHitTesting(!model.copyReflowing)
    }
}

extension View {
    func copyCard(model: AppModel, key: OwnerKey, square: Bool) -> some View {
        modifier(CopyCardDecoration(model: model, key: key, square: square))
    }
}

import SwiftUI

/// Panel expansion has a dedicated shortcut: Escape belongs to a focused terminal.
struct MenuCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("工作台") {
            Button("查找项目…") { model.openQuickNavigation() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(model.alert != nil)
            Divider()
            Button("折叠或固定左侧栏") {
                // Let AppKit finish tracking this menu before removing its sidebar anchor.
                DispatchQueue.main.async { model.toggleSidebar(source: .keyboard) }
            }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.alert != nil || model.quickNavigationPresented || model.tagPicker != nil)
            Button("展开或收起终端") {
                if let key = model.currentDetailKey { model.toggleFullscreen(key) }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(!canExpand)
            Divider()
            Button("设置…") { model.navigate(to: .settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
    }

    private var canExpand: Bool {
        switch model.page {
        case .detail, .history(_, .some): return true
        default: return false
        }
    }
}

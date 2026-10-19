import AppKit
import SwiftUI
import TerminalDeckKit

private struct WorkbenchOwnerFocusKey: FocusedValueKey { typealias Value = OwnerKey }
extension FocusedValues {
    var workbenchOwner: OwnerKey? {
        get { self[WorkbenchOwnerFocusKey.self] }
        set { self[WorkbenchOwnerFocusKey.self] = newValue }
    }
}

/// Focus is independent of selection. A collapsed node never leaves invisible arrow-key stops.
enum WorkbenchSidebarNode: Hashable {
    case search, home, menu(SessionKind), tag(String), owner(OwnerKey), settings
    case action(OwnerKey, String)
    var scrollID: String {
        switch self {
        case .search: return "sidebar-search"
        case .home: return "sidebar-home"
        case .menu(let kind): return "sidebar-menu-" + kind.rawValue
        case .tag(let id): return "sidebar-tag-" + id
        case .owner(let key): return key.ownerId
        case .action(let key, let action): return "action-\(key.ownerId)-\(action)"
        case .settings: return "sidebar-settings"
        }
    }
    var owner: OwnerKey? {
        switch self { case .owner(let key), .action(let key, _): return key; default: return nil }
    }
}

/// A named rail container derived from the same visible nodes as the expanded sidebar.
struct WorkbenchSidebarRailGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let owners: [OwnerKey]
}

extension AppModel {
    var sidebarRailPresetGroups: [WorkbenchSidebarRailGroup] {
        let nodes = sidebarNavigationNodes
        let visible = Set(nodes.compactMap(\.owner))
        return tagSections(for: .preset).compactMap { section in
            let id = section.tag?.id ?? "__untagged__"
            let owners = section.items.map { OwnerKey(kind: .preset, ownerId: $0.id) }.filter { visible.contains($0) }
            // Preserve a collapsed tag's named header, but never resurrect a hidden menu or deleted row.
            guard !owners.isEmpty || nodes.contains(.tag(id)) else { return nil }
            return WorkbenchSidebarRailGroup(id: id, title: section.name, owners: owners)
        }
    }

    var sidebarRailTerminals: [OwnerKey] {
        sidebarNavigationNodes.compactMap(\.owner).filter { $0.kind == .temp }
    }

    var sidebarNavigationNodes: [WorkbenchSidebarNode] {
        var nodes: [WorkbenchSidebarNode] = [.home, .menu(.preset)]
        if !workhorseCollapsedMenus.contains(.preset) {
            let sections = tagSections(for: .preset)
            let headers = sections.contains { $0.tag != nil }
            for section in sections {
                let bucket = section.tag?.id ?? "__untagged__"
                if headers { nodes.append(.tag(bucket)) }
                let collapsed = section.tag.map { isTagCollapsed($0.id) } ?? isUntaggedBucketCollapsed
                if !collapsed {
                    nodes += section.items.compactMap { item in
                        let key = OwnerKey(kind: .preset, ownerId: item.id)
                        return vanishing[key] == nil ? .owner(key) : nil
                    }
                }
            }
        }
        nodes.append(.menu(.temp))
        if !workhorseCollapsedMenus.contains(.temp) {
            nodes += temps.compactMap { temp in
                let key = OwnerKey(kind: .temp, ownerId: temp.id)
                return vanishing[key] == nil ? .owner(key) : nil
            }
        }
        nodes.append(.settings)
        return nodes
    }

    func activateSidebarNode(_ node: WorkbenchSidebarNode) {
        // Keyboard expansion never waits for a layout animation. Runtime/delete clocks are unaffected.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch node {
            case .search: openQuickNavigation()
            case .home: goHome()
            case .settings: navigate(to: .settings)
            case .menu(let kind): toggleWorkhorseMenu(kind)
            case .tag(let id):
                if id == "__untagged__" { toggleUntaggedBucketCollapsed() } else { toggleTagCollapsed(id) }
            case .owner(let key): workhorseSelect(key)
            case .action: break // Actions are owned by their actual controls, never by navigation.
            }
        }
    }

    func activatePrimaryAction(_ key: OwnerKey) {
        guard !copyIsBusy(key), !engine.isQuitting else { return }
        if let runtime = liveRuntime(key) {
            if runtime.needsForceTermination { forceStop(key) }
            else if runtime.status == .running {
                if key.kind == .preset && !runtime.isCommandRunning { restart(key) } else { stop(key) }
            }
        } else { restart(key) }
    }

    func sidebarActionNodes(for key: OwnerKey) -> [WorkbenchSidebarNode] {
        guard !copyIsBusy(key) else { return [] }
        let runtime = liveRuntime(key)
        let transitional = runtime?.status == .starting || runtime?.status == .stopping
        var names: [String] = []
        if (key.kind == .preset || temp(for: key.ownerId)?.launchConfiguration != nil || runtime != nil),
           !transitional || runtime?.needsForceTermination == true { names.append("primary") }
        names += isDisposableCopy(key) ? ["retain", "remove"] : ["menu"]
        return names.map { .action(key, $0) }
    }

    func sidebarParent(of key: OwnerKey) -> WorkbenchSidebarNode {
        guard key.kind == .preset else { return .menu(.temp) }
        if tagSections(for: .preset).contains(where: { $0.tag != nil }) {
            return .tag(card(for: key.ownerId)?.tagId ?? "__untagged__")
        }
        return .menu(.preset)
    }
}

struct WorkbenchActionTarget {
    let node: WorkbenchSidebarNode
    let focus: FocusState<WorkbenchSidebarNode?>.Binding
}
struct WorkbenchActionFocus: ViewModifier {
    var target: WorkbenchActionTarget?
    var activate: (() -> Void)? = nil
    @Environment(\.isEnabled) private var enabled
    @ViewBuilder func body(content: Content) -> some View {
        if let target {
            content.focusable().focused(target.focus, equals: target.node)
                .onKeyPress(.space) { perform(target) }
                .onKeyPress(.return) { perform(target) }
        } else { content }
    }
    private func perform(_ target: WorkbenchActionTarget) -> KeyPress.Result {
        guard target.focus.wrappedValue == target.node, enabled, let activate else { return .ignored }
        activate(); return .handled
    }
}

struct WorkbenchSidebarFocus: ViewModifier {
    let node: WorkbenchSidebarNode
    let focus: FocusState<WorkbenchSidebarNode?>.Binding
    let activate: () -> Void
    func body(content: Content) -> some View {
        content
            .focusable().focused(focus, equals: node).focusEffectDisabled()
            .onKeyPress(.return) { guard focus.wrappedValue == node, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return .ignored }; activate(); return .handled }
            .onKeyPress(.space) { guard focus.wrappedValue == node, !(NSApp.keyWindow?.firstResponder is NSTextView) else { return .ignored }; activate(); return .handled }
            .focusedValue(\.workbenchOwner, node.owner)
            .accessibilityIdentifier(node.scrollID)
            .id(node.scrollID)
    }
}

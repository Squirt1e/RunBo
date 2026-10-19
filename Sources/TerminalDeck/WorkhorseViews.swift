import AppKit
import SwiftUI
import TerminalDeckKit

/// 让窗口标题栏跟着牛马模式的底色走。
///
/// 标题栏是 AppKit 画的，不认识我们的调色板：浅色外观下它是近白的一条，压在米黄纸上很显眼
/// （双击放大后尤其明显——窗口更宽，那条白带更长）。给窗口设 `backgroundColor` 并打开
/// `titlebarAppearsTransparent`，标题栏就与内容同色，这是 macOS 上让标题栏跟内容走的标准做法。
/// 视图被拆掉时（退出牛马模式）恢复系统默认，卡片界面一点不受影响。
struct DeckWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // 首次 update 时视图可能还没挂进窗口，下一轮再试一次。
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = WorkhorseTheme.windowBackgroundNSColor
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        guard let window = view.window else { return }
        window.titlebarAppearsTransparent = false
        window.backgroundColor = .windowBackgroundColor
    }
}

/// 左侧面板的缩进阶梯（相对面板左边缘，单位 pt，面板左右各留 10pt）。
///
/// 两列标记，按**中心**对齐（面板左右各留 10pt）：
///
/// - 菜单行图标与标签块头的折叠箭头共用同一个 14pt 槽，中心同在 35pt；折叠箭头只有 7pt 宽，
///   按左边缘对齐会让它的中心偏左，看上去就是「没对齐」。
/// - **列表项的圆点与标签块头的标签标记同列**（圆点中心 ≈52pt，胶囊左边缘 48pt）：
///   标签标记已经换成标签胶囊，不再是「另一颗点」，所以两项共用一列也不会互相干扰。
private enum WorkhorseIndent {
    /// 菜单行图标的左边缘。
    static let menu: CGFloat = 18
    /// 标签块头折叠箭头的左边缘（14pt 槽 → 中心 35pt，与菜单行图标同列）。
    static let block: CGFloat = 18
    /// 折叠箭头与图标共用的槽宽：箭头在槽里居中。
    static let markerSlot: CGFloat = 14
    /// 列表项圆点的左边缘（12pt 槽 → 圆点中心 ≈52pt）。
    static let item: CGFloat = 36
    /// 行的右内边距（悬停操作贴住这里）。
    static let trailing: CGFloat = 8
}

/// 面板里所有折叠共用一段动画。
///
/// 菜单行、标签块头、列表内容与折叠箭头读的是同一个值——「展开 / 收起」在四处同时发生，
/// 用不同的曲线就会出现箭头和内容对不上的那种一顿一顿。开启「减弱动态效果」时全部置空。
enum WorkhorseCollapse {
    static let animation = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)

    /// 供验证脚手架关掉动画用（`DSH_NO_COLLAPSE_ANIM=1`）：离屏渲染抓不到动画的终态，
    /// 关掉之后渲染出来的就是折叠/展开完成后的样子。正常使用不设这个变量。
    static var disabled: Bool { ProcessInfo.processInfo.environment["DSH_NO_COLLAPSE_ANIM"] != nil }
}

/// 分身标记：贴在标题前面的一枚小胶囊。
///
/// 它是**类别**不是**状态**——所以用具名标签而不是色点（色点会跟列表项的状态圆点抢同一只眼睛），
/// 字号也让位给标题：一眼看上去仍是「一张卡片的名字」，只是前面多了一枚标记。
private struct WorkhorseCopyChip: View {
    var body: some View {
        Text("分身")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(WorkhorseTheme.accentText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(WorkhorseTheme.accentSoft)
            )
            .fixedSize()
    }
}

/// 左栏的折叠容器：收起时内容离开视图树，淡出与收高同时进行。
///
/// 反复试出来的三条，别改回去：
/// - **不要 `.move(edge: .top)`**：行在容器收高的同时还会整体上移一段，两段位移叠起来
///   就是两层错位的影子——折叠时从上面那一组底下透出来，正是那个重影。
/// - **不要只淡出、不收回高度**：行会停在原位继续画，一样会透到邻居身上。
/// - **不自己量高度裁切**：这棵视图树里 `GeometryReader` 读到的是被裁切之后的框
///   （展开也读成 0），量出来就把内容高度清零，展开时反而什么都不剩。
///
/// 动画由 `AppModel` 改折叠状态时统一给（`withAnimation` + `WorkhorseCollapse`）：
/// 四处折叠共用一段，箭头和内容一起动。
private struct SidebarCollapse<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if isExpanded {
            content
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
}

/// 牛马模式的主窗口：左侧菜单面板 + 可拖拽的分隔线 + 右侧内容区。
///
/// 这棵视图树只负责「怎么摆、什么颜色」：卡片、终端、历史、标签、删除过渡全部仍走
/// `AppModel` 与 `TerminalDeckKit`，与卡片界面共用同一份数据。
struct WorkhorseRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        WorkbenchSplitView(model: model) {
            WorkhorsePanel(model: model)
        } content: {
            WorkhorseContentView(model: model)
        }
        .onExitCommand { model.cancelDeletion() }
    }
}

/// Both modes use the same ratio, constraints, drag target and content allocation.
struct WorkbenchSplitView<Sidebar: View, Content: View>: View {
    @ObservedObject var model: AppModel
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var content: Content

    @ObservedObject private var presentation: SidebarPresentation

    init(model: AppModel, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content) {
        self.model = model; self.sidebar = sidebar(); self.content = content()
        self._presentation = ObservedObject(wrappedValue: model.sidebar)
    }

    /// 拖拽中的宽度。
    ///
    /// 整段拖拽只改这个局部状态：每帧写回模型会让整棵视图树（包括终端）重画，而指针又停在
    /// 一个正在移动的分隔线上——两件事叠起来就是「一跳一跳」。抬手才落库，中途不动模型。
    @State private var draggingWidth: CGFloat?
    @State private var draggingCard = false

    /// 拖拽手势的坐标空间。分隔线自己会移动，所以必须在一个固定的空间里取指针位置，
    /// 否则 `translation` 会被自己的位移反复污染。
    private var coordinateSpace: String { "workbench-root" }

    var body: some View {
        GeometryReader { proxy in
            let windowWidth = proxy.size.width
            let committed = WorkhorseLayout.sidebarWidth(ratio: model.workhorseSidebarRatio,
                                                         windowWidth: windowWidth)
            let width = draggingWidth ?? committed
            // This content subtree never changes identity. Peeks affect only the overlay.
            HStack(spacing: 0) {
                Color.clear.frame(width: WorkbenchSidebarLayout.reservedWidth(mode: presentation.mode, expandedWidth: width))
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .workbenchControlFrame("workbench-content")
            }
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        WorkbenchSidebarHeader(model: model, presentation: presentation)
                        ZStack(alignment: .topLeading) {
                            // Keep menus, rename and deletion clocks mounted even behind the rail.
                            sidebar.frame(width: width)
                                .opacity(presentation.expanded ? 1 : 0)
                                .allowsHitTesting(presentation.expanded).disabled(!presentation.expanded)
                                .accessibilityHidden(!presentation.expanded)
                                .transformPreference(CardFrameKey.self) { if !presentation.expanded { $0.removeAll() } }
                            WorkbenchSidebarRail(model: model, presentation: presentation)
                                .opacity(presentation.expanded ? 0 : 1)
                                .allowsHitTesting(!presentation.expanded).disabled(presentation.expanded)
                                .accessibilityHidden(presentation.expanded)
                        }
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .frame(width: presentation.expanded ? width : WorkbenchSidebarLayout.railWidth, alignment: .leading)
                    }
                    .frame(width: presentation.expanded ? width : WorkbenchSidebarLayout.railWidth, alignment: .leading)
                    .background(DeckTheme.panelSecondary)
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: presentation.mode == .collapsed && presentation.peeking ? 10 : 0,
                                                      topTrailingRadius: presentation.mode == .collapsed && presentation.peeking ? 10 : 0))
                    .shadow(color: .black.opacity(presentation.mode == .collapsed && presentation.peeking ? 0.14 : 0), radius: 14, x: 6)
                    .animation(presentation.animation, value: presentation.expanded)
                    .workbenchControlFrame("sidebar-panel")
                    if presentation.mode == .pinned {
                        WorkhorseDivider(
                            onDrag: { x in draggingWidth = WorkhorseLayout.clampedWidth(x, windowWidth: windowWidth) },
                            onEnd: { x in
                                let width = WorkhorseLayout.clampedWidth(x, windowWidth: windowWidth)
                                draggingWidth = nil
                                presentation.setDragging(false)
                                model.setWorkhorseSidebarRatio(WorkhorseLayout.ratio(forWidth: width, windowWidth: windowWidth), persist: true)
                            },
                            onReset: { draggingWidth = nil; model.resetWorkhorseSidebarRatio() }
                        )
                        .allowsHitTesting(!draggingCard)
                    }
                }
                .frame(maxHeight: .infinity)
                .fixedSize(horizontal: true, vertical: false)
                .background(SidebarEventProbe(presentation: presentation))
                .onPreferenceChange(WorkhorseCardDraggingKey.self) {
                    draggingCard = $0; presentation.setDragging($0 || draggingWidth != nil)
                }
            }
            .coordinateSpace(name: coordinateSpace)
            .background(DeckTheme.background)
            .onChange(of: draggingWidth) { _, value in presentation.setDragging(draggingCard || value != nil) }
            .onChange(of: model.sidebarInteractionLocked, initial: true) { _, _ in presentation.interactionChanged() }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in presentation.menuTracking(true) }
            .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in presentation.menuTracking(false) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in presentation.windowInactive() }
            .onDisappear { presentation.windowInactive() }
        }
    }
}

/// 两侧之间的分隔线。
///
/// 自己写而不是用 `NavigationSplitView` / `HSplitView`：系统那两个会接管侧栏的外观与生命
/// 周期（材质底、标题栏折叠按钮、列可见性），而这里两侧都是自绘的固定宽度面板，并且宽度
/// 要按窗口比例记住、要能双击回默认、要能在悬停时加粗并浮出抓手。规则在
/// `WorkhorseLayout`，这里只做手势与外观。
private struct WorkhorseDivider: View {
    /// 指针位置就是目标宽度（根视图坐标空间里，x = 0 就是面板左边缘）。
    let onDrag: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void
    let onReset: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            // 静止是一条 1pt 细线；指针进来只「微微变实」：加粗到 2pt + 一枚中性抓手指。
            //
            // 一开始用的是稻草金 3pt —— 拖拽时一整条竖线顶着强调色，比内容还显眼。
            // 分隔线是家具，不是按钮：用次要文字色的半透明就够提示「这里能拖」了。
            Rectangle()
                .fill(hovering ? WorkhorseTheme.muted.opacity(0.55) : WorkhorseTheme.divider)
                .frame(width: hovering ? 2 : 1)
            if hovering {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(WorkhorseTheme.muted.opacity(0.5))
                    .frame(width: 5, height: 26)
            }
        }
        // 细线本身只有 1pt，抓不住；热区加宽到 9pt，但视觉宽度不变。
        .frame(width: 9)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear {
            // 指针还停在分隔线上时视图消失（比如退出牛马模式）会漏掉一次 pop，
            // 光标就永久停在 ↔ 上，所以这里补一次。
            if hovering {
                NSCursor.pop()
                hovering = false
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1,
                        coordinateSpace: .named("workbench-root"))
                .onChanged { value in onDrag(value.location.x) }
                .onEnded { value in onEnd(value.location.x) }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onReset() }
        )
        .help("拖动改变宽度，双击回到默认")
        .accessibilityLabel("菜单面板宽度")
    }
}

// MARK: - 菜单面板

private struct WorkhorseRowFrameKey: PreferenceKey {
    static let coordinateSpace = "workhorse-list-hover"
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct WorkhorsePanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var sidebarPresentation: SidebarPresentation

    init(model: AppModel) { self.model = model; self._sidebarPresentation = ObservedObject(wrappedValue: model.sidebar) }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var hoveredRowID: String?
    @FocusState private var sidebarFocus: WorkbenchSidebarNode?
    @FocusedValue(\.workbenchOwner) private var keyboardOwner
    @State private var pointerLocation: CGPoint?
    @State private var pressLocation: CGPoint?
    @State private var cardDrag: WorkhorseCardDrag?
    @State private var dropFrames: [String: CGRect] = [:]
    @State private var dragExpandedGroups: Set<String> = []
    @State private var dragViewport: CGSize = .zero
    @State private var dragScroll = WorkhorseDragScrollDriver()
    private let dragScrollTick = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()
    private var reorderAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)
    }
    /// 左栏折叠共用一段动画；开启「减弱动态效果」时置空，折叠立刻完成。
    private var collapseAnimation: Animation? {
        (reduceMotion || WorkhorseCollapse.disabled) ? nil : WorkhorseCollapse.animation
    }

    var body: some View {
        VStack(spacing: 0) {
            QuickNavigationButton(model: model).padding(.horizontal, 16).padding(.bottom, 8)
                .focused($sidebarFocus, equals: .search)
            WorkhorseMenuRow(
                icon: "house",
                title: "首页",
                expanded: nil,
                isActive: isHome,
                onToggle: {},
                onAdd: nil,
                onTap: { model.goHome() }
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .modifier(sidebarTarget(.home))

            ScrollViewReader { scroller in
                ScrollView {
                    // 普通 VStack 而不是 LazyVStack：折叠要量出内容自身的高度才能裁切，
                    // 懒容器给不出这个数。左栏的项数本来就有限。
                    VStack(alignment: .leading, spacing: 0) {
                        menuRow(.preset)
                        SidebarCollapse(isExpanded: !model.workhorseCollapsedMenus.contains(.preset)) {
                            presetList
                        }
                        menuRow(.temp)
                            .padding(.top, 10)
                        SidebarCollapse(isExpanded: !model.workhorseCollapsedMenus.contains(.temp)) {
                            tempList
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                    .padding(.bottom, 18)
                    .background(WorkhorseDragScrollProbe(driver: dragScroll))
                    .allowsHitTesting(cardDrag == nil)
                    .deckScrollbars()
                }
                .onTapGesture { model.commitRename() }
                // 标签选择器的位置由根视图统一收集；悬停仍使用列表自身坐标。
                .coordinateSpace(name: WorkhorseRowFrameKey.coordinateSpace)
                .onPreferenceChange(WorkhorseRowFrameKey.self) { frames in
                    rowFrames = frames
                    updateHover(frames: frames)
                }
                .onPreferenceChange(WorkhorseDropFrameKey.self) { frames in
                    dropFrames = frames
                    if cardDrag?.landingPending == true, let frame = frames[WorkhorseDropFrameKey.placeholder] {
                        cardDrag?.landingPending = false
                        animateDragLanding(at: frame)
                    }
                }
                .overlay(alignment: .topLeading) { dragOverlay }
                // 整个列表统一命中一行；滚动改变行位置时也重新命中，不能留下旧行的 hover。
                .onContinuousHover(coordinateSpace: .named(WorkhorseRowFrameKey.coordinateSpace)) { phase in
                    switch phase {
                    case .active(let location):
                        pointerLocation = location
                        updateHover(frames: rowFrames)
                    case .ended:
                        pointerLocation = nil
                        hoveredRowID = nil
                    }
                }
                // 选中项换掉时（含刚进入模式那一刻）把它滚进视野：`task(id:)` 在出现时
                // 也会跑一次，正好覆盖「进来时正看着某个终端」这种情况。
                .onChange(of: model.newlyCreatedCopyID) { _, id in
                    if let id { scroller.scrollTo(id) }
                }
                .task(id: sidebarFocus) {
                    guard let node = sidebarFocus else { return }
                    if case .owner(let key) = node, let frame = rowFrames[key.ownerId],
                       frame.minY >= 0, frame.maxY <= dragViewport.height { return }
                    scroller.scrollTo(node.scrollID)
                }
                .task(id: model.workhorseSelection) {
                    // Let newly revealed groups lay out. Do not move an already-visible row
                    // under the pointer between the first and second click of a rename.
                    await Task.yield()
                    guard !Task.isCancelled, let key = model.workhorseSelection else { return }
                    if let frame = rowFrames[key.ownerId], frame.minY >= 0,
                       frame.maxY <= dragViewport.height { return }
                    scroller.scrollTo(key.ownerId)
                }
            }

            CopyGlobalPanel(model: model).padding(.horizontal, 10)
            Divider().overlay(WorkhorseTheme.line)

            HStack(spacing: 0) {
                WorkhorseMenuRow(
                    icon: "gearshape",
                    title: "设置",
                    expanded: nil,
                    isActive: isSettings,
                    onToggle: {},
                    onAdd: nil,
                    onTap: { model.navigate(to: .settings) }
                )
                .modifier(sidebarTarget(.settings))
                ClearCacheButton(model: model)
                    .padding(.trailing, WorkhorseIndent.trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .background {
            WorkhorseTheme.panelSecondary
                .contentShape(Rectangle())
                .onTapGesture { model.commitRename() }
        }
        .preference(key: WorkhorseCardDraggingKey.self, value: cardDrag != nil)
        .onMoveCommand(perform: moveSidebarFocus)
        .onKeyPress(.tab, phases: .down) { press in
            guard let current = sidebarFocus, let key = current.owner else { return .ignored }
            let stops: [WorkbenchSidebarNode] = [.owner(key)] + model.sidebarActionNodes(for: key)
            let index = stops.firstIndex(of: current) ?? 0
            let next = index + (press.modifiers.contains(.shift) ? -1 : 1)
            if stops.indices.contains(next) { sidebarFocus = stops[next] }
            else {
                let nodes = model.sidebarNavigationNodes
                if let row = nodes.firstIndex(of: .owner(key)) {
                    sidebarFocus = nodes[min(nodes.count - 1, max(0, row + (next < 0 ? -1 : 1)))]
                }
            }
            return .handled
        }
        .onChange(of: sidebarFocus) { _, node in
            model.sidebarFocusedNode = node
            model.sidebar.keyboardFocusChanged(node != nil)
        }
        .onChange(of: model.sidebar.focusRequest) { _, node in
            guard let node else { return }
            DispatchQueue.main.async {
                guard model.sidebar.focusRequest == node else { return }
                sidebarFocus = node
                model.sidebar.finishFocusTransfer(node)
            }
        }
        .onChange(of: model.sidebarNavigationNodes) { _, nodes in
            if let focused = sidebarFocus, focused != .search, !nodes.contains(focused) { sidebarFocus = .menu(.preset) }
        }
        .onChange(of: model.page) { _, _ in updateHover(frames: rowFrames) }
        .onChange(of: model.cards.map(\.id)) { _, ids in
            if let cardDrag, !ids.contains(cardDrag.card.id) { resetCardDrag() }
        }
        .onChange(of: model.vanishing) { _, records in
            if cardDrag != nil, !records.isEmpty { cancelCardDrag() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                resetCardDrag()
                pointerLocation = nil
                hoveredRowID = nil
            }
        }
        .task(id: cardDrag.flatMap { $0.valid && !$0.dropping ? ($0.destination.tagId ?? "") : nil }) {
            await expandDragDestination()
        }
        .onReceive(dragScrollTick) { _ in scrollDuringDrag() }
        .onDisappear {
            model.sidebarFocusedNode = nil
            resetCardDrag()
            pointerLocation = nil
            hoveredRowID = nil
        }
    }

    private func sidebarTarget(_ node: WorkbenchSidebarNode) -> WorkbenchSidebarFocus {
        WorkbenchSidebarFocus(node: node, focus: $sidebarFocus) {
            guard model.renamingKey == nil else { return }
            model.activateSidebarNode(node)
        }
    }

    private func moveSidebarFocus(_ direction: MoveCommandDirection) {
        guard model.renamingKey == nil, model.alert == nil, !model.quickNavigationPresented,
              !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
        let nodes = model.sidebarNavigationNodes
        guard !nodes.isEmpty else { return }
        if sidebarFocus == .search {
            if direction == .down { sidebarFocus = .home }
            return
        }
        let focused = sidebarFocus ?? keyboardOwner.map(WorkbenchSidebarNode.owner)
        let current = focused?.owner.map(WorkbenchSidebarNode.owner) ?? focused
            ?? model.workhorseSelection.map(WorkbenchSidebarNode.owner) ?? .home
        let index = nodes.firstIndex(of: current) ?? 0
        switch direction {
        case .up: sidebarFocus = nodes[max(0, index - 1)]
        case .down: sidebarFocus = nodes[min(nodes.count - 1, index + 1)]
        case .left:
            switch current {
            case .owner(let key): sidebarFocus = model.sidebarParent(of: key)
            case .menu(let kind): if !model.workhorseCollapsedMenus.contains(kind) { model.activateSidebarNode(current) }
            case .tag(let id):
                let collapsed = id == "__untagged__" ? model.isUntaggedBucketCollapsed : model.isTagCollapsed(id)
                if !collapsed { model.activateSidebarNode(current) }
            default: break
            }
        case .right:
            let collapsed: Bool
            switch current {
            case .menu(let kind): collapsed = model.workhorseCollapsedMenus.contains(kind)
            case .tag(let id): collapsed = id == "__untagged__" ? model.isUntaggedBucketCollapsed : model.isTagCollapsed(id)
            default: return
            }
            if collapsed { model.activateSidebarNode(current) }
            else { sidebarFocus = nodes[min(nodes.count - 1, index + 1)] }
        default: break
        }
    }

    private func updateHover(frames: [String: CGRect]) {
        guard cardDrag == nil else {
            hoveredRowID = nil
            return
        }
        hoveredRowID = pointerLocation.flatMap { point in
            NSApp.isActive ? WorkhorseRowState.hoveredID(at: point, frames: frames) : nil
        }
    }

    private var isHome: Bool {
        switch model.page {
        case .presets, .temps: return true
        default: return false
        }
    }

    private var isSettings: Bool {
        if case .settings = model.page { return true }
        return false
    }

    // MARK: 菜单行

    private func menuRow(_ kind: SessionKind) -> some View {
        WorkhorseMenuRow(
            icon: kind == .preset ? "square.stack.3d.up" : "terminal",
            title: kind == .preset ? "快捷指令" : "终端",
            expanded: !model.workhorseCollapsedMenus.contains(kind),
            isActive: false,
            onToggle: { model.toggleWorkhorseMenu(kind) },
            onAdd: {
                switch kind {
                case .preset: model.beginNewCard()
                case .temp: model.createWorkhorseTempTerminal()
                }
            },
            onTap: nil
        )
        .modifier(sidebarTarget(.menu(kind)))
    }

    // MARK: 列表

    @ViewBuilder
    private var presetList: some View {
        let sections = previewSections
        // 没有卡片挂标签时直接平铺：不显示「未加标签」这种没有信息量的标题。
        let showsHeaders = sections.contains { $0.tag != nil }
        ForEach(sections) { section in
            VStack(alignment: .leading, spacing: 0) {
                if showsHeaders {
                    WorkhorseBlockHeader(model: model, section: section,
                                         expandedForDrag: dragExpandedGroups.contains(section.id))
                        .modifier(sidebarTarget(.tag(section.tag?.id ?? "__untagged__")))
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isDragDestination(section) ? WorkhorseTheme.accentSoft : Color.clear)
                        )
                        .workhorseDropFrame(WorkhorseDropFrameKey.header(section.id),
                                            coordinateSpace: WorkhorseRowFrameKey.coordinateSpace)
                }
                SidebarCollapse(isExpanded: !isCollapsed(section)) {
                    ForEach(section.items) { item in
                        if case .preset(let card) = item {
                            if cardDrag?.card.id == card.id {
                                dragPlaceholder
                                    .id(card.id)
                            } else {
                                presetRow(card)
                            }
                        }
                    }
                    // 折叠组先给落点留位，悬停稍久再展开其他卡片，避免块头从指针下滑走。
                    if isCollapsed(section), isDragDestination(section) { dragPlaceholder }
                }
            }
            .transition(.opacity)
        }
        if model.cards.isEmpty {
            emptyHint("还没有快捷指令")
        }
    }

    @ViewBuilder
    private var tempList: some View {
        ForEach(model.temps) { temp in
            WorkhorseRow(
                model: model,
                kind: .temp,
                id: temp.id,
                title: temp.title,
                detail: nil,
                selectedKey: model.workhorseSelection,
                hoveredID: hoveredRowID,
                keyboardFocused: keyboardOwner == OwnerKey(kind: .temp, ownerId: temp.id),
                actionFocus: $sidebarFocus
            )
            .modifier(sidebarTarget(.owner(OwnerKey(kind: .temp, ownerId: temp.id))))
            .cardFrame(temp.id)
            .id(temp.id)
        }
        if model.temps.isEmpty {
            emptyHint("还没有终端")
        }
    }

    private func presetRow(_ card: PresetCard) -> some View {
        WorkhorseRow(
            model: model,
            kind: .preset,
            id: card.id,
            title: card.title,
            detail: card.command,
            selectedKey: model.workhorseSelection,
            hoveredID: hoveredRowID,
            onLongPress: { beginCardDrag(card) },
            keyboardFocused: keyboardOwner == OwnerKey(kind: .preset, ownerId: card.id),
            actionFocus: $sidebarFocus
        )
        .modifier(sidebarTarget(.owner(OwnerKey(kind: .preset, ownerId: card.id))))
        .cardFrame(card.id)
        .id(card.id)
        .workhorseDropFrame(WorkhorseDropFrameKey.row(card.id),
                            coordinateSpace: WorkhorseRowFrameKey.coordinateSpace)
    }

    private func isCollapsed(_ section: TagSection<PresetCardOrTemp>) -> Bool {
        if dragExpandedGroups.contains(section.id) { return false }
        guard let tag = section.tag else { return model.isUntaggedBucketCollapsed }
        return model.isTagCollapsed(tag.id)
    }

    // MARK: 长按拖动（预览不改模型，松手只提交一次）

    private var previewSections: [TagSection<PresetCardOrTemp>] {
        let cards = cardDrag.flatMap {
            PresetCardReordering.moving(model.cards, id: $0.card.id, to: $0.destination)
        } ?? model.cards
        var sections = CardGrouping.sections(items: cards.map(PresetCardOrTemp.preset), tags: model.tags) { $0.tagId }
        // 移动尚未提交时保留源块头，避免最后一项被拖起后多收掉 26pt，让目标从指针下跳走。
        // 松手进入 dropping 后才随落位动画收掉空组；标签本身始终保留。
        if let drag = cardDrag, !drag.dropping,
           let source = model.tagSections(for: .preset).first(where: { $0.items.contains { $0.id == drag.card.id } }),
           !sections.contains(where: { $0.id == source.id }) {
            sections.append(TagSection(tag: source.tag, items: []))
            let order = model.tags.sorted { $0.sortOrder < $1.sortOrder }.map(\.id) + [""]
            sections.sort { (order.firstIndex(of: $0.id) ?? order.count) < (order.firstIndex(of: $1.id) ?? order.count) }
        }
        return sections
    }

    private func isDragDestination(_ section: TagSection<PresetCardOrTemp>) -> Bool {
        guard let cardDrag, cardDrag.valid else { return false }
        return section.tag?.id == cardDrag.destination.tagId
    }

    private var dragPlaceholder: some View {
        RoundedRectangle(cornerRadius: WorkhorseRow.cornerRadius)
            .fill(WorkhorseTheme.accentSoft.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: WorkhorseRow.cornerRadius)
                    .strokeBorder(WorkhorseTheme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .frame(height: WorkhorseLayout.listRowHeight)
            .workhorseDropFrame(WorkhorseDropFrameKey.placeholder,
                                coordinateSpace: WorkhorseRowFrameKey.coordinateSpace)
    }

    private var dragOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                WorkhorseDragCapture(
                    active: cardDrag != nil && cardDrag?.dropping == false,
                    onPress: { pressLocation = $0 },
                    onMove: updateCardDrag,
                    onEnd: finishCardDrag,
                    onCancel: cancelCardDrag
                )
                if let drag = cardDrag {
                    dragPreview(drag)
                        .frame(width: drag.originFrame.width, height: WorkhorseLayout.listRowHeight)
                        .scaleEffect(drag.dropping ? 1 : 1.025)
                        .opacity(drag.valid ? 1 : 0.65)
                        .offset(x: drag.offset.x, y: drag.offset.y)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .allowsHitTesting(false)
                }
            }
            .onAppear { dragViewport = proxy.size }
            .onChange(of: proxy.size) { _, size in dragViewport = size }
        }
        .clipped()
    }

    private func dragPreview(_ drag: WorkhorseCardDrag) -> some View {
        HStack(spacing: 8) {
            WorkhorseDot(kind: WorkhorseStatusDot.of(model.presentation(
                for: OwnerKey(kind: .preset, ownerId: drag.card.id))))
            VStack(alignment: .leading, spacing: 1) {
                Text(drag.card.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WorkhorseTheme.text)
                Text(model.tag(for: drag.destination.tagId)?.name ?? TagVocabulary.untaggedTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(WorkhorseTheme.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.leading, WorkhorseIndent.item)
        .padding(.trailing, WorkhorseIndent.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: WorkhorseRow.cornerRadius).fill(WorkhorseTheme.panel))
        .overlay(RoundedRectangle(cornerRadius: WorkhorseRow.cornerRadius)
            .stroke(WorkhorseTheme.accent.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(drag.dropping ? 0 : 0.16), radius: 9, y: 4)
    }

    private var dropRegions: [CardDropRegion] {
        previewSections.flatMap { section -> [CardDropRegion] in
            let items = section.items.filter { $0.id != cardDrag?.card.id }
            let first = CardDropDestination(tagId: section.tag?.id, beforeCardID: items.first?.id)
            var regions: [CardDropRegion] = []
            if let frame = dropFrames[WorkhorseDropFrameKey.header(section.id)] {
                regions.append(CardDropRegion(frame: frame, before: first, after: first))
            }
            for (index, item) in items.enumerated() {
                guard let frame = dropFrames[WorkhorseDropFrameKey.row(item.id)] else { continue }
                let next = index + 1 < items.count ? items[index + 1].id : nil
                regions.append(CardDropRegion(frame: frame,
                    before: CardDropDestination(tagId: section.tag?.id, beforeCardID: item.id),
                    after: CardDropDestination(tagId: section.tag?.id, beforeCardID: next)))
            }
            return regions
        }
    }

    private func beginCardDrag(_ card: PresetCard) {
        let key = OwnerKey(kind: .preset, ownerId: card.id)
        guard cardDrag == nil, model.removingCopies.isEmpty, model.pendingDeletion == nil, model.vanishing.isEmpty,
              model.renamingKey != key, let frame = rowFrames[card.id] else { return }
        let point = pressLocation ?? pointerLocation ?? CGPoint(x: frame.midX, y: frame.midY)
        guard frame.contains(point), model.vanishing[key] == nil else { return }
        let siblings = model.cards.filter { $0.tagId == card.tagId }
        guard let index = siblings.firstIndex(where: { $0.id == card.id }) else { return }
        let next = index + 1 < siblings.count ? siblings[index + 1].id : nil
        model.closeTagPicker()
        hoveredRowID = nil
        NSCursor.closedHand.push()
        withAnimation(reorderAnimation) {
            cardDrag = WorkhorseCardDrag(card: card, originFrame: frame,
                grabOffset: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
                location: point, destination: CardDropDestination(tagId: card.tagId, beforeCardID: next))
        }
    }

    private func updateCardDrag(_ point: CGPoint, _ viewport: CGSize) {
        guard let drag = cardDrag, !drag.dropping else { return }
        dragViewport = viewport
        pointerLocation = point
        var direct = Transaction(animation: nil)
        direct.disablesAnimations = true
        withTransaction(direct) { cardDrag?.location = point }
        let inside = CGRect(origin: .zero, size: viewport).contains(point)
        let onPlaceholder = dropFrames[WorkhorseDropFrameKey.placeholder]?.contains(point) == true
        let destination = onPlaceholder ? drag.destination : CardDropRegion.destination(at: point, in: dropRegions)
        withAnimation(reorderAnimation) {
            cardDrag?.valid = inside && destination != nil
            if let destination { cardDrag?.destination = destination }
        }
    }

    private func expandDragDestination() async {
        guard let drag = cardDrag, !drag.dropping else { return }
        let id = drag.destination.tagId ?? ""
        let collapsed = drag.destination.tagId.map { model.isTagCollapsed($0) } ?? model.isUntaggedBucketCollapsed
        guard collapsed, !dragExpandedGroups.contains(id) else { return }
        do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
        guard cardDrag?.token == drag.token, cardDrag?.valid == true,
              cardDrag?.destination.tagId == drag.destination.tagId else { return }
        withAnimation(reorderAnimation) { _ = dragExpandedGroups.insert(id) }
    }

    private func scrollDuringDrag() {
        guard let drag = cardDrag, !drag.dropping,
              dragScroll.scroll(at: drag.location, viewport: dragViewport) else { return }
        DispatchQueue.main.async {
            guard let drag = cardDrag, !drag.dropping else { return }
            updateCardDrag(drag.location, dragViewport)
        }
    }

    private func finishCardDrag(_ point: CGPoint, _ viewport: CGSize) {
        // 静止松手不要重新命中正在让位的邻行；位置变化/边缘滚动时已经持续更新落点。
        if cardDrag?.location != point { updateCardDrag(point, viewport) }
        guard let drag = cardDrag, !drag.dropping else { return }
        guard drag.valid else { cancelCardDrag(); return }
        // 标签与顺序是同一个事务：写盘失败就回原位，不留下半次移动。
        let saved = withAnimation(reorderAnimation) { model.moveWorkhorseCard(drag.card.id, to: drag.destination) }
        guard saved else { cancelCardDrag(); return }
        withAnimation(reorderAnimation) {
            if let tag = drag.destination.tagId, model.isTagCollapsed(tag) {
                model.toggleTagCollapsed(tag)
            } else if drag.destination.tagId == nil, model.isUntaggedBucketCollapsed {
                model.toggleUntaggedBucketCollapsed()
            }
        }
        let header = dropFrames[WorkhorseDropFrameKey.header(drag.destination.tagId ?? "")]
        let fallback = header.map { CGRect(x: $0.minX, y: $0.maxY, width: $0.width,
                                          height: WorkhorseLayout.listRowHeight) } ?? drag.originFrame
        settleCardDrag(at: dropFrames[WorkhorseDropFrameKey.placeholder] ?? fallback)
    }

    private func cancelCardDrag() {
        guard let drag = cardDrag, !drag.dropping else { return }
        withAnimation(reorderAnimation) {
            let siblings = model.cards.filter { $0.tagId == drag.card.tagId }
            let next = siblings.drop { $0.id != drag.card.id }.dropFirst().first?.id
            cardDrag?.destination = CardDropDestination(tagId: drag.card.tagId, beforeCardID: next)
        }
        settleCardDrag(at: drag.originFrame)
    }

    private func settleCardDrag(at frame: CGRect) {
        guard let drag = cardDrag else { return }
        withAnimation(reorderAnimation) {
            cardDrag?.dropping = true
            cardDrag?.valid = true
            cardDrag?.landingPending = true
        }
        animateDragLanding(at: frame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard cardDrag?.token == drag.token else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { resetCardDrag() }
        }
    }

    private func animateDragLanding(at frame: CGRect) {
        guard let drag = cardDrag else { return }
        withAnimation(reorderAnimation) {
            cardDrag?.location = CGPoint(x: frame.minX + drag.grabOffset.x, y: frame.minY + drag.grabOffset.y)
        }
    }

    private func resetCardDrag() {
        if cardDrag != nil { NSCursor.pop() }
        cardDrag = nil
        dragExpandedGroups = []
        updateHover(frames: rowFrames)
    }

    /// 列表为空时的一句话：面板里居中、不带句号。
    ///
    /// 文案里不出现「牛马」——牛马指的是人（用这个 App 的人），不是卡片也不是终端。
    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(WorkhorseTheme.muted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

/// 一枚菜单行：图标 + 名称 + 计数 + 行密度 + 「＋」+ 折叠箭头。
///
/// 菜单行从「切页面」变成「折叠 / 展开」，所以整行是一个折叠开关；「＋」是牛马模式里
/// 唯一的新增入口，点它新建的东西一定落在这一行所属的菜单里。
private struct WorkhorseMenuRow: View {
    let icon: String
    let title: String
    /// nil 表示这一行不能折叠（首页、设置）。
    let expanded: Bool?
    let isActive: Bool
    let onToggle: () -> Void
    let onAdd: (() -> Void)?
    /// 整行点击的另一个去处（首页、设置用它）。
    let onTap: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    /// 「＋」自己的悬停：底色跟着它，而不是跟着整行。
    @State private var plusHovering = false

    /// 折叠箭头跟内容用同一段动画，箭头不会比它指的那一列先到。
    private var collapseAnimation: Animation? {
        (reduceMotion || WorkhorseCollapse.disabled) ? nil : WorkhorseCollapse.animation
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: icon == "house" ? DeckTheme.homeIconSize : DeckTheme.menuIconSize, weight: .regular))
                .frame(width: 18)
                .foregroundStyle(isActive ? WorkhorseTheme.accent : WorkhorseTheme.muted)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isActive ? WorkhorseTheme.accentText : WorkhorseTheme.text)
            .lineLimit(1)

            Spacer(minLength: 4)

            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(plusHovering ? WorkhorseTheme.accent : WorkhorseTheme.muted)
                        .frame(width: 26, height: 24)
                        .background(
                            // 底色只属于按钮自己：指针在行的别处时不该给它一块白底，
                            // 那会让人以为「这一行被选中了」。
                            RoundedRectangle(cornerRadius: 6)
                                .fill(plusHovering ? WorkhorseTheme.panel : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(plusHovering ? WorkhorseTheme.line : Color.clear, lineWidth: 1)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { plusHovering = $0 }
                .help(title == "快捷指令" ? "新建快捷指令" : "新建终端")
                .accessibilityLabel(title == "快捷指令" ? "新建快捷指令" : "新建终端")
            }

            if let expanded {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WorkhorseTheme.muted)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                    .animation(collapseAnimation, value: expanded)
            }
        }
        .padding(.leading, WorkhorseIndent.menu)
        .padding(.trailing, WorkhorseIndent.trailing)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering ? WorkhorseTheme.hover : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture {
            if let onTap { onTap() } else { onToggle() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(expanded.map { $0 ? "已展开" : "已折叠" } ?? "")
        .accessibilityAction { if let onTap { onTap() } else { onToggle() } }
    }
}

/// 标签块头：标签胶囊 + 折叠箭头，不显示数量；悬停给出与卡片界面同一套标签菜单。
///
/// 它是标签唯一出现的地方（卡片与列表项都不带标签），规则与卡片界面完全一致。
private struct WorkhorseBlockHeader: View {
    @ObservedObject var model: AppModel
    let section: TagSection<PresetCardOrTemp>
    var expandedForDrag = false

    @State private var hovering = false
    @State private var menuOpen = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var confirmingDelete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var renameFocused: Bool

    /// 块头的折叠箭头与它下面那一列卡片用同一段动画。
    private var collapseAnimation: Animation? {
        (reduceMotion || WorkhorseCollapse.disabled) ? nil : WorkhorseCollapse.animation
    }

    private var tag: CardTag? { section.tag }
    private var collapsed: Bool {
        if expandedForDrag { return false }
        guard let tag else { return model.isUntaggedBucketCollapsed }
        return model.isTagCollapsed(tag.id)
    }
    private var tone: TagTone { tag.map(TagTone.of) ?? .untagged }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if confirmingDelete { deleteConfirm }
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            // 折叠箭头两种块头都有：「未加标签」也是一块，只是不是标签而已。
            // 在槽里居中：这一列的中心与菜单行图标一致。
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(WorkhorseTheme.muted)
                .frame(width: WorkhorseIndent.markerSlot)
                .animation(collapseAnimation, value: collapsed)
            if let tag, renaming {
                TextField("标签名", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WorkhorseTheme.text)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(WorkhorseTheme.panel)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(WorkhorseTheme.accent, lineWidth: 1))
                    )
                    .focused($renameFocused)
                    .onSubmit {
                        model.renameTag(tag.id, to: draft)
                        renaming = false
                    }
                    .onExitCommand { renaming = false }
                    .onAppear {
                        draft = tag.name
                        renameFocused = true
                    }
            } else {
                RoundedRectangle(cornerRadius: 1).fill(tone.foreground.opacity(0.7)).frame(width: 2, height: 10)
                    .accessibilityHidden(true)
                Text(tag?.name ?? TagVocabulary.untaggedTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WorkhorseTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let tag, hovering || menuOpen || renaming {
                blockMenu(tag)
            }
        }
        .padding(.leading, WorkhorseIndent.block)
        .padding(.trailing, WorkhorseIndent.trailing)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering && tag != nil ? WorkhorseTheme.hover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let tag {
                model.toggleTagCollapsed(tag.id)
            } else {
                model.toggleUntaggedBucketCollapsed()
            }
        }
        .help(tag == nil ? "点击折叠或展开「未加标签」" : "点击折叠或展开「\(tag?.name ?? "")」")
    }

    private func blockMenu(_ tag: CardTag) -> some View {
        Menu {
            Button("重命名") { renaming = true }
            Button("上移") { model.moveTag(tag.id, by: -1) }
            Button("下移") { model.moveTag(tag.id, by: 1) }
            Divider()
            Button("删除标签…") {
                confirmingDelete = true
                menuOpen = false
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WorkhorseTheme.muted)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { menuOpen = $0 }
        .help("管理标签「\(tag.name)」")
    }

    private var deleteConfirm: some View {
        HStack(spacing: 8) {
            Text(section.items.isEmpty
                 ? "删除「\(tag?.name ?? "")」？"
                 : "删除「\(tag?.name ?? "")」？\(section.items.count) 张卡片会退回「未加标签」。")
                .font(.system(size: 11))
                .foregroundStyle(WorkhorseTheme.text)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("取消") { confirmingDelete = false }
                .buttonStyle(DeckButtonStyle(variant: .small, fontSize: 11))
            Button("删除") {
                if let tag { model.deleteTag(tag.id) }
                confirmingDelete = false
            }
            .buttonStyle(DeckButtonStyle(variant: .smallDanger, fontSize: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(DeckTheme.redBackground)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(DeckTheme.redBorder, lineWidth: 1))
        )
        .padding(.vertical, 4)
    }
}

/// 列表项：一颗状态圆点 + 标题（+ 一行副文本），悬停才浮出该卡片的操作按钮。
///
/// 状态文字不进行内，但悬停提示与无障碍标签给全——这是「只看圆点」这条规则的底线。
struct WorkhorseRow: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let kind: SessionKind
    let id: String
    let title: String
    /// 选中或悬停且未编辑标题时显示的预设命令；终端传 nil。两种列表项始终等高。
    let detail: String?
    let selectedKey: OwnerKey?
    let hoveredID: String?
    var onLongPress: (() -> Void)? = nil
    var keyboardFocused = false
    var actionFocus: FocusState<WorkbenchSidebarNode?>.Binding? = nil
    private func actionTarget(_ name: String) -> WorkbenchActionTarget? {
        actionFocus.map { WorkbenchActionTarget(node: .action(key, name), focus: $0) }
    }

    /// 行的圆角。确认层要用同一个：轮廓对不上，玻璃看起来就是「贴上去的一块」。
    static let cornerRadius: CGFloat = 7
    /// 行内操作按钮的热区；为两行文字留出空间，与固定行高一起保持垂直居中。
    private static let actionWell: CGFloat = 26
    private static let actionWellHeight: CGFloat = 28

    /// 这一行的告别：留着删除时的记录，让它和孩子列表一样淡出、撒完粒子再消失。
    ///
    /// 和 `CardShell` 同样的写法——`AppModel` 会在补位动画之后清掉记录，而 SwiftUI 可能还在
    /// 渲染这一帧，所以这里保留自己的一份，避免删掉的行「淡回来」。
    @State private var leaving: CardVanish?
    @FocusState private var renameFieldFocused: Bool

    private var key: OwnerKey { OwnerKey(kind: kind, ownerId: id) }
    private var isRenamingTitle: Bool { model.isRenaming(key, in: .workhorseList) }
    private var presentation: SessionStatusPresentation { model.presentation(for: key) }
    private var dot: WorkhorseStatusDot { WorkhorseStatusDot.of(presentation) }
    private var runtime: SessionRuntime? { model.liveRuntime(key) }
    private var vanish: CardVanish? { model.vanishing[key] }
    /// 这一行正在等第二次确认。
    private var confirming: Bool { model.pendingDeletion?.key == key }

    private var rowState: WorkhorseRowState {
        WorkhorseRowState(key: key, selectedKey: selectedKey, hoveredID: hoveredID,
                          tagPickerKey: model.tagPicker?.key, isRenamingTitle: isRenamingTitle)
    }
    private var selected: Bool { rowState.selected }
    private var hovering: Bool { rowState.hovering }
    private var showsDetail: Bool { rowState.showsDetail || keyboardFocused }
    private var actionSurface: Color {
        selected ? WorkhorseTheme.selection : WorkhorseTheme.hover
    }

    /// 拖拽只属于圆点、标题和空白区；操作按钮是兄弟视图，不参与长按识别。
    /// 分身的保留 / 解除会挤动「…」，不能用固定的行尾宽度排除按钮。
    private var draggableContent: some View {
        // 分身只压缩行尾操作区，圆点与文字的间距始终和普通行一致。
        HStack(alignment: .center, spacing: 8) {
            WorkhorseDot(kind: dot)
            VStack(alignment: .leading, spacing: 1) {
                if isRenamingTitle {
                    renameField
                } else {
                    HStack(spacing: 5) {
                        if model.isDisposableCopy(key) {
                            WorkhorseCopyChip()
                        }
                        Text(title)
                            .font(.system(size: 13, weight: selected ? .medium : .regular))
                            .foregroundStyle(WorkhorseTheme.text)
                            .lineLimit(1)
                    }
                }
                if showsDetail, !isRenamingTitle, let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(WorkhorseTheme.muted)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: model.isDisposableCopy(key) ? 0 : 6)
        }
        .padding(.leading, WorkhorseIndent.item)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !confirming, leaving == nil, !isRenamingTitle, !model.isDisposableCopy(key) else { return }
            model.workhorseSelect(key, renamingTitle: true)
        }
        // Simultaneous recognition lets a single click finish immediately, instead of
        // waiting for the system double-click interval. Buttons are sibling views.
        .simultaneousGesture(TapGesture().onEnded {
            guard !confirming, leaving == nil, !isRenamingTitle else { return }
            model.workhorseSelect(key)
        })
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35, maximumDistance: 6)
                .onEnded { _ in onLongPress?() },
            including: onLongPress == nil || isRenamingTitle ? .subviews : .all
        )
    }

    /// 标题输入框：整块盒子铺满卡片项的高度（外沿上下各留 6pt），文字仍居中一行。
    ///
    /// 盒子由一层背景自己撑起来，`TextField` 只负责在里面居中——直接把 `frame` 加在 `TextField`
    /// 上时，AppKit 那层仍然按文字行高（16pt）报尺寸，视觉上还是「居中的一小条」。
    private var renameField: some View {
        TextField("终端标题", text: $model.renameText)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(WorkhorseTheme.text)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(WorkhorseTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(WorkhorseTheme.accent, lineWidth: 1))
                    .frame(height: WorkhorseLayout.listRowHeight - 14)
            )
            .focused($renameFieldFocused)
            .onSubmit { model.commitRename() }
            .onExitCommand { model.cancelRename() }
            .accessibilityLabel("终端标题，按回车保存")
    }

    var body: some View {
        draggableContent
            // 行内操作（含分身的保留 / 解除）只在悬停时浮出，而且是覆盖在行上而不是挤占布局：
            // 常驻会喧宾夺主，挤占布局又会让标题随指针进出反复换行。
            .overlay(alignment: .trailing) { rowActions }
            .padding(.trailing, WorkhorseIndent.trailing)
            // 标题（或标题与命令组成的一组）、圆点和操作按钮各自垂直居中；任何状态都不改行高。
            .frame(height: WorkhorseLayout.listRowHeight)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: WorkhorseRowFrameKey.self,
                                           value: [id: proxy.frame(in: .named(WorkhorseRowFrameKey.coordinateSpace))])
                }
            }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(confirming
                      ? WorkhorseTheme.panel
                      : (selected ? WorkhorseTheme.selection : (hovering ? WorkhorseTheme.hover : Color.clear)))
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        // 换一行进入标题标记模式时，这一行自动失焦回到展示模式（`workhorseSelect` 已经落盘）。
        .onChange(of: isRenamingTitle) { _, renaming in
            renameFieldFocused = renaming
        }
        .onChange(of: renameFieldFocused) { _, focused in
            guard !focused, model.isRenaming(key, in: .workhorseList) else { return }
            // 点别的卡片：`workhorseSelect` 在同一轮里落盘并换选中，输入框会和这一帧一起被换掉，
            // 于是「输入框 → 标题」没有过渡，看上去就是突然消失。失焦先落地，下一轮再提交，
            // 回到展示模式那段动画才有机会演。
            DispatchQueue.main.async {
                guard model.isRenaming(key, in: .workhorseList) else { return }
                model.commitRename()
            }
        }
        .onAppear { renameFieldFocused = model.isRenaming(key, in: .workhorseList) }
        .onDisappear {
            if isRenamingTitle { model.commitRename() }
        }
        .cardContextMenu(model: model, key: key, kind: kind)
        // 二次确认沿用卡片界面那一套：同一份 `DeleteConfirmOverlay`（玻璃 + 两颗圆钮）、
        // 同一段淡入、同一套文案。26pt 圆钮与说明放在固定 44pt 的行内。
        .deleteConfirmation(for: key, inline: true, cornerRadius: WorkhorseRow.cornerRadius,
                            buttonSize: 26, model: model)
        // 告别：整行淡出（SwiftUI 动画），粒子由自己的时钟画在这一行之上，
        // 和卡片列表用的是同一个 `DeleteBurstView` 与同一份粒子数据。
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
        .allowsHitTesting(leaving == nil && !model.copyReflowing)
        .help(rowHelp)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)，\(presentation.label)")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { model.workhorseSelect(key) }
        .accessibilityHint("回车打开详情，Tab 访问行尾操作；不会重新执行命令")
    }

    /// 卡片那套淡出用的是同一个 `DeleteBurst.fade`。
    private var fadeAnimation: Animation? {
        guard leaving?.startedAt != nil, let fade = leaving?.burst.fade else { return nil }
        return .linear(duration: fade)
    }

    /// 悬停时浮出的行内操作：贴着行的右内边距，覆盖在内容之上。
    ///
    /// 分身有**两组**按钮：自己的启动 / 终止（`actions`，它没有「…」）和保留 / 解除
    /// （`CardCopyActions` 的紧凑形态）。两组都是行内图标按钮，只是不再常驻。
    @ViewBuilder
    private var rowActions: some View {
        if hovering || keyboardFocused || NSWorkspace.shared.isVoiceOverEnabled, leaving == nil, !confirming, !isRenamingTitle {
            HStack(spacing: 2) {
                actions
                if model.isDisposableCopy(key) {
                    CardCopyActions(model: model, key: key, compact: true, focus: actionFocus)
                }
            }
            .disabled(model.copyIsBusy(key))
            .padding(.trailing, WorkhorseIndent.trailing)
            .background {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, actionSurface], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 14)
                    actionSurface
                }
                .padding(.leading, -14)
                .frame(height: WorkhorseLayout.listRowHeight)
                .allowsHitTesting(false)
            }
            .transition(.opacity)
        }
    }

    /// 悬停提示里那句「双击可重命名」只对普通行成立：分身卡片没有双击重命名。
    private var rowHelp: String {
        guard model.isDisposableCopy(key) else { return "\(title)；\(presentation.label)；双击可重命名" }
        return "\(title)；\(presentation.label)；分身卡片，解除会结束此终端"
    }

    /// 悬停时浮出的操作。预设命令行是 启动 / 终止 + 「…」，终端行是 终止 + 删除；
    /// 「详情」不再是按钮——点整行就是看详情（见 `model.workhorseSelect`）。
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            if kind == .preset || model.temp(for: id)?.launchConfiguration != nil {
                primaryAction.modifier(WorkbenchActionFocus(target: actionTarget("primary"), activate: { model.activatePrimaryAction(key) }))
            } else {
                if runtime != nil {
                    DeckIconButton(systemName: "stop.fill", help: "终止 \(title)",
                                   tint: WorkhorseTheme.red,
                                   wellWidth: Self.actionWell, wellHeight: Self.actionWellHeight) {
                        model.stop(key)
                    }
                    .modifier(WorkbenchActionFocus(target: actionTarget("primary"), activate: { model.activatePrimaryAction(key) }))
                }
            }
            if !model.isDisposableCopy(key) { rowMenu }
        }
    }

    /// 与卡片上的主操作同一套判断：过渡态显示进度（无响应时给强制终止），
    /// 任务结束后是重新「启动」，命令还在跑时是「终止」。
    @ViewBuilder
    private var primaryAction: some View {
        switch runtime?.status {
        case .starting, .stopping:
            HStack(spacing: 2) {
                if runtime?.needsForceTermination != true {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                if runtime?.needsForceTermination == true {
                    DeckIconButton(systemName: "bolt.fill", help: "强制终止 \(title)",
                                   tint: WorkhorseTheme.red,
                                   wellWidth: Self.actionWell, wellHeight: Self.actionWellHeight) {
                        model.forceStop(key)
                    }
                }
            }
            .frame(minWidth: 28, minHeight: 24)
        case .running:
            if kind == .preset && runtime?.isCommandRunning != true {
                DeckIconButton(systemName: "play.fill", help: "重新运行 \(title)（会重建当前终端）",
                               tint: WorkhorseTheme.green,
                               wellWidth: Self.actionWell, wellHeight: Self.actionWellHeight) {
                    if let card = model.card(for: id) { model.startCard(card) }
                }
            } else {
                DeckIconButton(systemName: "stop.fill", help: "终止 \(title)",
                               tint: WorkhorseTheme.red,
                               wellWidth: Self.actionWell, wellHeight: Self.actionWellHeight) {
                    model.stop(key)
                }
            }
        default:
            DeckIconButton(systemName: "play.fill", help: "启动 \(title)",
                           tint: WorkhorseTheme.green,
                           wellWidth: Self.actionWell, wellHeight: Self.actionWellHeight) {
                model.restart(key)
            }
        }
    }

    /// 与卡片上的「…」同一份菜单（标签… / 编辑 / 删除）。
    private var rowMenu: some View {
        Menu {
            CardOperationsMenu(model: model, key: key)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WorkhorseTheme.muted)
                .frame(width: Self.actionWell, height: Self.actionWellHeight)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(WorkbenchActionFocus(target: actionTarget("menu")))
        .help("标签、编辑或删除 \(title)")
        .accessibilityLabel("标签、编辑或删除 \(title)")
    }
}

/// 一颗状态圆点。形状补足颜色不够表达的部分：空心环＝没在跑，断弧＝过渡中，
/// 外圈光晕＝命令在跑。逐条规则见 `WorkhorseStatusDot`。
struct WorkhorseDot: View {
    let kind: WorkhorseStatusDot
    /// Injectable for isolated previews; nil always follows the real system preference.
    var reduceMotionOverride: Bool? = nil

    private let size: CGFloat = 8

    var body: some View {
        ZStack {
            switch kind {
            case .executing, .liveBusy:
                // 圆环与圆点在同一个 ZStack 中共享圆心，不让缩放过的 overlay 参与布局。
                WorkhorseDotRipple(color: WorkhorseTheme.accent, reduceMotionOverride: reduceMotionOverride)
                Circle().fill(kind == .executing ? WorkhorseTheme.accent : WorkhorseTheme.green)
                    .frame(width: size, height: size)
            case .live:
                Circle().fill(WorkhorseTheme.green).frame(width: size, height: size)
            case .failed:
                Circle().fill(WorkhorseTheme.red).frame(width: size, height: size)
            case .idle:
                Circle().strokeBorder(WorkhorseTheme.muted, lineWidth: 1.5)
                    .frame(width: size - 1, height: size - 1)
            case .starting, .unresponsive:
                Circle().strokeBorder(WorkhorseTheme.muted.opacity(0.55), lineWidth: 1.4)
                    .frame(width: size - 1, height: size - 1)
                WorkhorseDotSpinner(color: kind == .unresponsive ? WorkhorseTheme.red : WorkhorseTheme.accent,
                                    reduceMotionOverride: reduceMotionOverride)
                    .frame(width: size - 1, height: size - 1)
            }
        }
        .frame(width: size + 4, height: size + 4)
        .accessibilityHidden(true)
    }
}

/// 仅在启动 / 终止期间挂载，时钟更新限定在圆点内，状态结束即销毁。
private struct WorkhorseDotSpinner: View {
    let color: Color
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate / 0.9
            Circle()
                .trim(from: 0, to: 0.34)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? -30 : turns.truncatingRemainder(dividingBy: 1) * 360))
        }
    }
}

/// 执行中那一圈往外扩散的光环。
///
/// 只在「命令在跑」时挂载，所以状态一变这个视图就没了、动画随之结束——
/// 这正是之前圆点常驻旋转踩过的坑：动画留在列表里，整份列表一直重绘。
private struct WorkhorseDotRipple: View {
    let color: Color
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let ripple = WorkhorseRipple(elapsed: timeline.date.timeIntervalSinceReferenceDate,
                                             size: size, reduceMotion: reduceMotion)
                context.stroke(Path(ellipseIn: ripple.bounds),
                               with: .color(color.opacity(ripple.opacity)),
                               lineWidth: ripple.lineWidth)
            }
            .frame(width: WorkhorseRipple.canvasSize, height: WorkhorseRipple.canvasSize)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 右侧内容区

private struct WorkhorseContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.page {
            case .presets, .temps:
                WorkhorseHomeView(snapshot: model.workhorseHome, onOpen: model.openWorkhorseHome)
            case .detail(let key):
                SessionDetailView(model: model, key: key)
                    .id("workhorse-detail-" + key.ownerId)
            case .history(let key, let sessionId):
                HistoryPageView(model: model, key: key, sessionId: sessionId)
                    .id("workhorse-history-" + key.ownerId)
            case .editor:
                CardEditorView(model: model)
            case .settings:
                SettingsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkhorseTheme.background)
        .deckFeedback(model: model)
    }
}

/// 用户参考图的原始笔触与配色：只去外部纸白和底部残字，不给插画套主题色。
struct WorkhorseOxMark: View {
    // SwiftPM's generated lookup checks the app root; assembled apps keep bundles
    // in Contents/Resources. Resolve that first, with .module for swift run.
    static let artworkBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "TerminalDeck_TerminalDeck", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    // Named SwiftUI image lookup can silently render a loose SwiftPM PNG as
    // transparent on macOS. Decode its file explicitly instead of using that cache.
    private static let artworkImage: NSImage? = {
        guard let url = artworkBundle.url(forResource: "WorkhorseOx", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let image = Self.artworkImage {
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

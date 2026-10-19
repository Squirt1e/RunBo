import CoreGraphics
import Foundation
import Core

/// 牛马模式的规则检查。
///
/// 这些是视图判断不了、只能靠断言的部分：比例怎么换算、夹在哪两个数之间、窄到什么程度转单行，
/// 以及状态到圆点的映射是否覆盖了每一种输入。
func registerSplitRulesChecks() {
    // MARK: - 模式取值

    register("split.mode-round-trip") {
        try expectEqual(SplitMode.stored("on"), .on, "on")
        try expectEqual(SplitMode.stored("off"), .off, "off")
        try expectEqual(SplitMode(rawValue: SplitMode.on.rawValue), .on, "rawValue 往返")
    }

    register("split.mode-falls-back-to-off") {
        // 升级用户不该因为一个缺失或写坏的设置项换到另一套界面。
        for stored in [nil, "", "ON", "yes", "true", "1", "牛马"] as [String?] {
            try expectEqual(SplitMode.stored(stored), .off, "「\(stored ?? "nil")」当作关闭")
        }
    }

    // MARK: - 列表交互与涟漪

    register("split.row-selection-is-exclusive-and-clears") {
        let first = OwnerKey(kind: .preset, ownerId: "first")
        let second = OwnerKey(kind: .preset, ownerId: "second")
        let selected = SplitRowState(key: first, selectedKey: first, hoveredID: nil)
        try expect(selected.selected && selected.showsDetail, "当前终端显示选中背景与命令")
        let other = SplitRowState(key: second, selectedKey: first, hoveredID: nil)
        try expect(!other.selected && !other.showsDetail && !other.hovering, "其他行不保留样式")
        for key in [first, second] {
            let cleared = SplitRowState(key: key, selectedKey: nil, hoveredID: nil)
            try expect(!cleared.selected && !cleared.hovering && !cleared.showsDetail,
                       "设置/首页没有选中项时背景、命令与操作全部收起")
        }
        let hovered = SplitRowState(key: second, selectedKey: first, hoveredID: "second")
        try expect(hovered.hovering && hovered.showsDetail && !hovered.selected, "悬停不等于选中")
    }

    register("split.row-rename-hides-and-restores-command") {
        let key = OwnerKey(kind: .preset, ownerId: "renaming")
        for selected in [false, true] {
            for hovered in [false, true] {
                for hasTagPicker in [false, true] {
                    func state(renaming: Bool) -> SplitRowState {
                        SplitRowState(key: key, selectedKey: selected ? key : nil,
                                          hoveredID: hovered ? key.ownerId : nil,
                                          tagPickerKey: hasTagPicker ? key : nil,
                                          isRenamingTitle: renaming)
                    }
                    let before = state(renaming: false)
                    try expectEqual(before.showsDetail, selected || hovered || hasTagPicker,
                                    "非编辑状态仍按选中、悬停与标签弹窗显示命令")
                    let editing = state(renaming: true)
                    try expect(!editing.showsDetail, "编辑标题时即使选中或悬停也隐藏命令")
                    try expectEqual(editing.selected, before.selected, "编辑不改变选中态")
                    try expectEqual(editing.hovering, before.hovering, "编辑不改变悬停态")
                    try expectEqual(state(renaming: false), before, "保存或取消后恢复原显示规则")
                }
            }
        }
    }

    register("split.tag-picker-keeps-target-hovered") {
        let target = OwnerKey(kind: .preset, ownerId: "target")
        let selected = OwnerKey(kind: .preset, ownerId: "selected")
        for hoveredID in [target.ownerId, nil] as [String?] {
            let state = SplitRowState(key: target, selectedKey: selected,
                                          hoveredID: hoveredID, tagPickerKey: target)
            try expect(state.hovering && state.showsDetail, "鼠标移入弹窗后仍保留背景、命令与操作")
            try expect(!state.selected, "设置标签不改变当前选中项")
        }
        let other = SplitRowState(key: selected, selectedKey: selected,
                                      hoveredID: nil, tagPickerKey: target)
        try expect(other.selected && other.showsDetail && !other.hovering, "其他选中行不获得弹窗的悬停态")
    }

    register("split.tag-picker-matches-the-full-owner-key") {
        let target = OwnerKey(kind: .preset, ownerId: "shared")
        let terminal = OwnerKey(kind: .temp, ownerId: "shared")
        let other = SplitRowState(key: terminal, selectedKey: nil,
                                      hoveredID: nil, tagPickerKey: target)
        try expect(!other.hovering && !other.showsDetail, "同 ID 不同类型的行不被错误高亮")
        let state = SplitRowState(key: terminal, selectedKey: nil,
                                      hoveredID: nil, tagPickerKey: terminal)
        try expect(state.hovering && state.showsDetail, "终端自己的标签弹窗也保留悬停态")
    }

    register("split.tag-picker-close-restores-pointer-hover") {
        let target = OwnerKey(kind: .preset, ownerId: "target")
        for hoveredID in [nil, target.ownerId, "other"] as [String?] {
            let state = SplitRowState(key: target, selectedKey: nil,
                                          hoveredID: hoveredID, tagPickerKey: nil)
            try expectEqual(state.hovering, hoveredID == target.ownerId, "关闭后仅按当前指针显示悬停态")
            try expectEqual(state.showsDetail, state.hovering, "鼠标不在目标上时收起命令与操作")
        }
        let selected = SplitRowState(key: target, selectedKey: target,
                                         hoveredID: nil, tagPickerKey: nil)
        try expect(selected.selected && selected.showsDetail && !selected.hovering,
                   "关闭弹窗不清除原有选中态")
    }

    register("split.tag-picker-switches-the-highlighted-target") {
        let first = OwnerKey(kind: .preset, ownerId: "first")
        let second = OwnerKey(kind: .preset, ownerId: "second")
        for target in [first, second] {
            for key in [first, second] {
                let state = SplitRowState(key: key, selectedKey: nil,
                                              hoveredID: nil, tagPickerKey: target)
                try expectEqual(state.hovering, key == target, "切换弹窗目标后只有新目标保留悬停态")
            }
        }
    }

    register("split.hover-follows-current-pointer-and-row-frames") {
        let frames = ["first": CGRect(x: 10, y: 10, width: 240, height: 44),
                      "second": CGRect(x: 10, y: 54, width: 240, height: 44)]
        try expectEqual(SplitRowState.hoveredID(at: CGPoint(x: 30, y: 30), frames: frames),
                        "first", "指针命中第一行")
        try expectEqual(SplitRowState.hoveredID(at: CGPoint(x: 30, y: 70), frames: frames),
                        "second", "移到第二行只保留第二行")
        try expectEqual(SplitRowState.hoveredID(at: CGPoint(x: 400, y: 30), frames: frames),
                        nil, "移出列表不残留悬停")
        let scrolled = frames.mapValues { $0.offsetBy(dx: 0, dy: -44) }
        try expectEqual(SplitRowState.hoveredID(at: CGPoint(x: 30, y: 30), frames: scrolled),
                        "second", "指针不动，滚动后也按最新位置命中")
        try expectEqual(SplitRowState.hoveredID(at: .zero, frames: [:]), nil, "列表消失即清空")
    }

    register("split.ripple-stays-circular-and-centered") {
        for size in [CGSize(width: 22, height: 22), CGSize(width: 24, height: 30)] {
            for sample in 0..<100 {
                let ripple = StatusRipple(elapsed: Double(sample) / 80, size: size)
                try expect(abs(ripple.bounds.midX - size.width / 2) < 1e-9, "圆心 X 不漂移")
                try expect(abs(ripple.bounds.midY - size.height / 2) < 1e-9, "圆心 Y 不漂移")
                try expectEqual(ripple.bounds.width, ripple.bounds.height, "始终是正圆")
                try expect(ripple.bounds.minX >= ripple.lineWidth / 2, "圆环不会被画布裁切")
                try expect((0...0.6).contains(ripple.opacity), "透明度在合法区间")
            }
        }
    }

    register("split.ripple-repeats-after-the-original-period") {
        let size = CGSize(width: StatusRipple.canvasSize, height: StatusRipple.canvasSize)
        let first = StatusRipple(elapsed: 0.25, size: size)
        let repeated = StatusRipple(elapsed: 0.25 + StatusRipple.period, size: size)
        try expectEqual(first.bounds, repeated.bounds, "每 1.25 秒重复同一半径")
        try expectEqual(first.opacity, repeated.opacity, "每次循环的透明度一致")
    }

    register("split.ripple-reduced-motion-is-static") {
        let size = CGSize(width: 22, height: 22)
        let first = StatusRipple(elapsed: 0, size: size, reduceMotion: true)
        let later = StatusRipple(elapsed: 0.9, size: size, reduceMotion: true)
        try expectEqual(first.bounds, later.bounds, "减少动态效果下半径不变")
        try expectEqual(first.opacity, later.opacity, "减少动态效果下不闪烁")
        try expectEqual(first.bounds.width + first.lineWidth, 11, "保留原来的 11pt 静止圆环")
    }

    // MARK: - 面板宽度（按比例）

    register("split.width-default-ratio-equals-296") {
        let width = SplitLayout.sidebarWidth(
            ratio: SplitLayout.defaultRatio,
            windowWidth: SplitLayout.defaultWindowWidth
        )
        try expect(abs(width - 296) < 0.01, "默认窗口下应当是 296pt，实际 \(width)")
        try expectEqual(SplitLayout.defaultSidebarWidth, 296, "默认宽度常量")
    }

    register("split.width-follows-the-window") {
        let ratio = SplitLayout.defaultRatio
        let wide = SplitLayout.sidebarWidth(ratio: ratio, windowWidth: 1600)
        try expect(abs(wide - 430.5) < 1.5, "1600pt 窗口下约 430pt，实际 \(wide)")
        let narrow = SplitLayout.sidebarWidth(ratio: ratio, windowWidth: 950)
        try expect(abs(narrow - 255.6) < 1.5, "950pt 窗口下约 256pt，实际 \(narrow)")
        try expect(narrow < wide, "窗口越宽，面板越宽")
    }

    register("split.width-clamps-both-ends") {
        try expectEqual(SplitLayout.sidebarWidth(ratio: 0.02, windowWidth: 1100), 240, "低于下限抬到 240")
        try expectEqual(SplitLayout.sidebarWidth(ratio: 0.95, windowWidth: 2000), 460, "高于上限压到 460")
        try expectEqual(SplitLayout.sidebarWidth(ratio: 0.9, windowWidth: 950), 390, "窄窗口按内容区下限收上限")
        try expectEqual(SplitLayout.sidebarWidth(ratio: 0.9, windowWidth: 700), 240, "窗口极窄也不低于下限")
    }

    register("split.width-keeps-the-content-area") {
        // 上限的意义就是这一条：内容区永远不小于 560pt。
        for windowWidth in [950.0, 1100.0, 1440.0, 2000.0, 3200.0] as [CGFloat] {
            let width = SplitLayout.sidebarWidth(ratio: 1.0, windowWidth: windowWidth)
            let content = windowWidth - width
            try expect(content >= SplitLayout.minContentWidth - 0.01,
                       "窗口 \(windowWidth) 时内容区只剩 \(content)")
        }
    }

    register("split.width-ratio-round-trip") {
        // 拖拽结束时把宽度换算回比例，重开或改窗口尺寸后应当落回同一个宽度。
        for width in [240.0, 260.0, 296.0, 388.0, 460.0] as [CGFloat] {
            let ratio = SplitLayout.ratio(forWidth: width, windowWidth: 1100)
            let back = SplitLayout.sidebarWidth(ratio: ratio, windowWidth: 1100)
            try expect(abs(back - width) < 0.5, "\(width)pt 往返成了 \(back)pt")
        }
    }

    register("split.width-ratio-parsing") {
        try expect(abs(SplitLayout.storedRatio("0.269091") - 0.269091) < 1e-9, "正常取值")
        for stored in [nil, "", "abc", "0", "-0.2", "nan", "inf"] as [String?] {
            try expectEqual(SplitLayout.storedRatio(stored), SplitLayout.defaultRatio,
                            "「\(stored ?? "nil")」回落默认比例")
        }
        // 往返不漂移：存下来的字符串读回来还是同一个比例。
        let stored = SplitLayout.storageValue(SplitLayout.defaultRatio)
        try expect(abs(SplitLayout.storedRatio(stored) - SplitLayout.defaultRatio) < 1e-6,
                   "默认比例往返漂移了：\(stored)")
    }

    register("split.width-survives-a-degenerate-window") {
        // 窗口还没布局好时宽度可能是 0；这里只要求不崩、不出负数。
        for windowWidth in [0.0, -10.0, CGFloat.infinity] as [CGFloat] {
            let width = SplitLayout.sidebarWidth(ratio: SplitLayout.defaultRatio, windowWidth: windowWidth)
            try expect(width >= SplitLayout.minSidebarWidth, "窗口 \(windowWidth) 时宽度 \(width)")
        }
        try expectEqual(SplitLayout.ratio(forWidth: 296, windowWidth: 0), SplitLayout.defaultRatio,
                        "窗口宽为 0 时比例兜底")
    }

    register("split.width-key-is-its-own") {
        // 卡片界面的侧栏宽度是写死的 198pt，与这里没有共用键。
        try expect(SplitLayout.sidebarRatioKey != "card_mode_presets", "与卡片形态不共键")
        try expect(SplitLayout.sidebarRatioKey != "workhorse_mode", "与模式开关不共键")
    }

    // MARK: - 拖拽时用的宽度钳制

    register("split.clamped-width-matches-the-ratio-path") {
        // 拖拽直接夹宽度、松手再换算成比例；两条路必须落在同一个数上。
        for raw in [100.0, 240.0, 296.0, 400.0, 460.0, 700.0] as [CGFloat] {
            let direct = SplitLayout.clampedWidth(raw, windowWidth: 1100)
            let viaRatio = SplitLayout.sidebarWidth(ratio: Double(raw / 1100), windowWidth: 1100)
            try expect(abs(direct - viaRatio) < 0.01, "宽度 \(raw)：\(direct) vs \(viaRatio)")
        }
    }

    register("split.clamped-width-keeps-the-content-area") {
        for windowWidth in [950.0, 1100.0, 1440.0, 2000.0] as [CGFloat] {
            let width = SplitLayout.clampedWidth(9999, windowWidth: windowWidth)
            try expect(windowWidth - width >= SplitLayout.minContentWidth - 0.01,
                       "窗口 \(windowWidth) 时内容区只剩 \(windowWidth - width)")
        }
        try expectEqual(SplitLayout.clampedWidth(.nan, windowWidth: 1100),
                        SplitLayout.defaultSidebarWidth, "非有限值回落默认宽度")
    }

    register("split.list-row-height") {
        try expectEqual(SplitLayout.listRowHeight, 44, "标题与命令共用固定 44pt 行高")
    }

    // MARK: - 状态圆点

    register("split.dot-maps-every-presentation") {
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(label: "执行中", tone: .executing)),
            .executing, "执行中"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(label: "成功", tone: .running)),
            .live, "成功"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(label: "结果未知", tone: .running)),
            .live, "结果未知"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(label: "在线", tone: .running)),
            .live, "在线"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(
                label: "在线", tone: .running, badge: "执行中", badgeKind: .busy
            )),
            .liveBusy, "在线且命令执行中"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(label: "正在启动", tone: .busy)),
            .starting, "正在启动"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(label: "正在终止", tone: .busy)),
            .starting, "正在终止"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(
                label: "正在终止", tone: .busy, badge: "无响应", badgeTone: .failure
            )),
            .unresponsive, "正在终止 · 无响应"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(label: "失败", tone: .failed)),
            .failed, "失败"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(label: "启动失败", tone: .failed)),
            .failed, "启动失败"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(label: "意外退出", tone: .failed)),
            .failed, "意外退出"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(label: "未运行", tone: .idle)),
            .idle, "未运行"
        )
        try expectEqual(
            StatusDot.of(SessionStatusPresentation(label: "已失效", tone: .idle)),
            .idle, "已失效"
        )
    }

    register("split.dot-kinds-are-all-reachable") {
        // 圆点种类不多不少：每一种都由某个真实状态映射得到，没有画不出来的分支。
        let samples: [SessionStatusPresentation] = [
            SessionStatusPresentation(label: "执行中", tone: .executing),
            SessionStatusPresentation(label: "在线", tone: .running),
            SessionStatusPresentation(label: "在线", tone: .running, badge: "执行中", badgeKind: .busy),
            SessionStatusPresentation(label: "正在启动", tone: .busy),
            SessionStatusPresentation(label: "正在终止", tone: .busy, badge: "无响应", badgeTone: .failure),
            SessionStatusPresentation(label: "失败", tone: .failed),
            SessionStatusPresentation(label: "未运行", tone: .idle),
        ]
        let reached = Set(samples.map(StatusDot.of))
        try expectEqual(reached, Set(StatusDot.allCases), "七种圆点恰好被这七种状态覆盖")
    }
}

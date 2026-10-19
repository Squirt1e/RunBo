import CoreGraphics
import Foundation

/// 牛马模式：卡片界面之外的第二套工作台（设置页一行开关进入与退出）。
///
/// 这一层只放**规则**——模式取值、设置键、面板宽度的换算、行密度、状态圆点种类。
/// 规则放这里是为了能被自检断言：视图只负责把它们画出来，判断不了对错。
public enum SplitMode: String, CaseIterable, Sendable {
    case off
    case on

    /// Legacy storage key; keep the value stable for existing installations.
    public static let key = "workhorse_mode"

    /// 缺失、空串、无法识别的取值一律当作关闭：升级后看到的仍是卡片界面。
    public static func stored(_ value: String?) -> SplitMode {
        guard let value, let mode = SplitMode(rawValue: value) else { return .off }
        return mode
    }

    public var isOn: Bool { self == .on }
}

/// 菜单面板与内容区之间那条分隔线的规则。
///
/// 宽度按**占窗口的比例**记忆：用户拖出来的是「左边占多宽」，同一个 296pt 在 13 寸屏全屏
/// 和 5K 屏上是两种布局。代价是改窗口尺寸时宽度会跟着漂移，所以下限、上限与内容区下限
/// 必须兜住——这三条都在 `sidebarWidth(ratio:windowWidth:)` 里，可以被断言。
public enum SplitLayout {
    /// 默认窗口尺寸（`AppEntry` 的 `defaultSize`）。默认比例就是按它算出来的。
    public static let defaultWindowWidth: CGFloat = 1100
    public static let defaultSidebarWidth: CGFloat = 296
    public static let minSidebarWidth: CGFloat = 240
    public static let maxSidebarWidth: CGFloat = 460
    /// 内容区不允许比这更窄：终端再挤就没法用了。
    public static let minContentWidth: CGFloat = 560
    /// Legacy storage key; keep the value stable for existing installations.
    public static let sidebarRatioKey = "workhorse_sidebar_width"

    /// `296 / 1100`：在默认窗口下正好等于 296pt。
    public static let defaultRatio: Double = Double(defaultSidebarWidth / defaultWindowWidth)

    /// 缺失、空串、非数字、非正数与无穷大全部回落默认比例。
    public static func storedRatio(_ value: String?) -> Double {
        guard let value, let ratio = Double(value), ratio.isFinite, ratio > 0 else { return defaultRatio }
        return ratio
    }

    /// 存成定点小数字符串，往返不漂移（`0.269091` → 1100pt 窗口下 296.0pt）。
    public static func storageValue(_ ratio: Double) -> String {
        String(format: "%.6f", ratio)
    }

    /// 比例 + 当前窗口宽度 → 实际宽度。顺序是先换算再夹：上限随窗口收窄这条规则靠它成立。
    public static func sidebarWidth(ratio: Double, windowWidth: CGFloat) -> CGFloat {
        let width = windowWidth.isFinite ? max(0, windowWidth) : defaultWindowWidth
        let desired = CGFloat(ratio.isFinite ? ratio : defaultRatio) * width
        return clampedWidth(desired, windowWidth: windowWidth)
    }

    /// 把「想设的宽度」夹进合法区间。
    ///
    /// 拖拽时直接用它：指针的 x 就是目标宽度，夹一次即可，不必先算比例再算回来——
    /// 中间那趟浮点往返正是拖起来一跳一跳的原因之一。
    public static func clampedWidth(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        let available = windowWidth.isFinite ? max(0, windowWidth) : defaultWindowWidth
        guard width.isFinite else { return defaultSidebarWidth }
        // 窗口越窄，上限越低；但下限永远不低于 240（窗口极窄时宁可压内容区也不把面板挤没）。
        let upper = min(maxSidebarWidth, max(minSidebarWidth, available - minContentWidth))
        return min(max(width, minSidebarWidth), upper)
    }

    /// 宽度 → 比例，供拖拽结束时写回设置。窗口宽为 0 或非有限值时兜底成默认比例。
    public static func ratio(forWidth width: CGFloat, windowWidth: CGFloat) -> Double {
        guard windowWidth.isFinite, windowWidth > 0 else { return defaultRatio }
        let clamped = sidebarWidth(ratio: Double(width / windowWidth), windowWidth: windowWidth)
        return Double(clamped) / Double(windowWidth)
    }

    /// 列表项固定行高，足够容纳标题与一行命令；悬停、选中、删除确认都不改变高度。
    public static let listRowHeight: CGFloat = 44
}

/// 背景、副文本与按钮共用悬停判断；标签弹窗打开期间，其目标行也保持悬停态。
/// 标题编辑期间只隐藏命令副文本，不改变选中与悬停状态。
public struct SplitRowState: Equatable, Sendable {
    public let selected: Bool
    public let hovering: Bool
    public let isRenamingTitle: Bool
    public var showsDetail: Bool { !isRenamingTitle && (selected || hovering) }

    public init(key: OwnerKey, selectedKey: OwnerKey?, hoveredID: String?, tagPickerKey: OwnerKey? = nil,
                isRenamingTitle: Bool = false) {
        selected = selectedKey == key
        hovering = hoveredID == key.ownerId || tagPickerKey == key
        self.isRenamingTitle = isRenamingTitle
    }

    /// 按当前指针和最新行位置命中，而不是依赖各行可能漏掉的 mouse-exit。
    public static func hoveredID(at point: CGPoint, frames: [String: CGRect]) -> String? {
        frames.first { $0.value.contains(point) }?.key
    }
}

/// 涟漪只改变绘制半径，不缩放视图的布局；圆环始终以画布中心为圆心。
public struct StatusRipple {
    public static let period: TimeInterval = 1.25
    public static let canvasSize: CGFloat = 22
    public let bounds: CGRect
    public let lineWidth: CGFloat
    public let opacity: Double

    public init(elapsed: TimeInterval, size: CGSize, reduceMotion: Bool = false) {
        let phase = elapsed.isFinite ? max(0, elapsed).truncatingRemainder(dividingBy: Self.period) / Self.period : 0
        let progress = 1 - pow(1 - phase, 3)
        let scale: CGFloat = reduceMotion ? 1 : CGFloat(0.85 + 0.9 * progress)
        lineWidth = reduceMotion ? 1.1 : 1.2 * scale
        let diameter = 11 * scale - lineWidth
        bounds = CGRect(x: (size.width - diameter) / 2, y: (size.height - diameter) / 2,
                        width: diameter, height: diameter)
        opacity = reduceMotion ? 0.5 : 0.6 * (1 - progress)
    }
}

/// 列表项上那一颗圆点能表达的七种状态。
///
/// 颜色只有四个语义（金＝执行中、绿＝在线/成功、红＝失败/异常、灰＝未运行），状态却有七种，
/// 所以形状补足剩下的区分：空心环＝没在跑，断弧＝正在启动或正在终止，外圈光晕＝命令在跑。
/// 文字不进行内，但**必须**在悬停提示与无障碍标签里给全——这是「只看圆点」这条规则的底线。
public enum StatusDot: String, CaseIterable, Sendable {
    /// 命令正在跑。
    case executing
    /// 在线 / 成功 / 结果未知。
    case live
    /// 在线且命令在执行中：绿点 + 金圈。
    case liveBusy
    /// 正在启动 / 正在终止：灰环 + 金弧。
    case starting
    /// 正在终止但无响应：灰环 + 红弧。
    case unresponsive
    /// 失败 / 启动失败 / 意外退出。
    case failed
    /// 未运行 / 已失效：空心环。
    case idle

    /// 状态数据 → 圆点。判定与卡片完全同源：这里只做一次映射，不重新判断业务。
    public static func of(_ presentation: SessionStatusPresentation) -> StatusDot {
        switch presentation.tone {
        case .executing:
            return .executing
        case .running:
            // 终端的「在线 + 执行中」：主状态是在线，第二件事（命令在跑）由外圈表达。
            return presentation.isCommandBusy ? .liveBusy : .live
        case .failed:
            return .failed
        case .busy:
            // 过渡态。带 failure 徽标的那一种（正在终止 · 无响应）要能把红弧亮出来。
            return presentation.badgeTone == .failure ? .unresponsive : .starting
        case .idle:
            return .idle
        }
    }
}

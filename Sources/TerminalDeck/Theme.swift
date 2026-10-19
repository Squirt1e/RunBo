import AppKit
import SwiftUI
import TerminalDeckKit

/// Quiet Precision: warm paper and graphite shared by both layouts.
/// Terminal output colours remain independent from the workbench material.
enum DeckTheme {
    /// Retained as a layout compatibility marker; mode switches no longer change the skin.
    enum Palette { case standard, workhorse }

    static var palette: Palette = .standard

    // Two layouts, one material system. Palette is retained for layout compatibility,
    // not for a second skin; terminal colours below deliberately remain independent.
    static var background: Color { WorkhorseTheme.background }
    static var panel: Color { WorkhorseTheme.panel }
    static var panelSecondary: Color { WorkhorseTheme.panelSecondary }
    static var text: Color { WorkhorseTheme.text }
    static var muted: Color { WorkhorseTheme.muted }
    static var line: Color { WorkhorseTheme.line }
    static var accent: Color { WorkhorseTheme.accentText }
    static let green = WorkhorseTheme.green
    /// Card fills stay close to the panel colour; the state is carried by the border,
    /// the dot and the chip. A saturated fill looked muddy in dark mode.
    static let greenBackground = adaptive(light: 0xF2F9F5, dark: 0x252E2B)
    static let greenBorder = adaptive(light: 0x9CD3B7, dark: 0x3C6B58)
    static let executingBorder = adaptive(light: 0x5983DB, dark: 0xA0BDFF)
    static var red: Color { WorkhorseTheme.red }
    /// Destructive actions (delete): the system red the confirmation glass is tinted with,
    /// so the icon that asks and the button that answers are the same colour.
    static let destructive = adaptive(light: 0xFF3B30, dark: 0xFF453A)
    static var redBackground: Color { WorkhorseTheme.redBackground }
    static var redBorder: Color { WorkhorseTheme.redBorder }
    static let amber = adaptive(light: 0x8A5A0B, dark: 0xE0B163)
    static let terminalBackground = adaptive(light: 0x18212C, dark: 0x101317)
    static let terminalText = Color(red: 0.863, green: 0.910, blue: 0.929)
    /// Terminal chrome (title bar / divider) shared by the session detail and the
    /// preset command editor so both read as the same surface.
    static let terminalBarText = Color(red: 0.62, green: 0.67, blue: 0.72)
    static let terminalBarLine = Color(red: 0.23, green: 0.27, blue: 0.32)
    /// State colours for the terminal bar's badge. That chrome is dark in both
    /// appearances, so these stay fixed: the adaptive greens and ambers would go
    /// almost black on it in light mode.
    static let terminalBarLive = Color(red: 0.475, green: 0.863, blue: 0.690)
    static let terminalBarBusy = Color(red: 0.878, green: 0.694, blue: 0.388)
    static let terminalBarIdle = Color(red: 0.655, green: 0.690, blue: 0.737)
    /// A shell that died on its own. The bar's fill stays dark so the last output is still
    /// readable; only the dot and the wording carry the alarm.
    static let terminalBarFailed = Color(red: 1.0, green: 0.569, blue: 0.588)
    static var navSelection: Color { WorkhorseTheme.navSelection }
    /// Pop-up menu row in use: the mockup fills it light blue and flips the text
    /// to a dark colour instead of tinting the panel.
    static var selectionFill: Color { WorkhorseTheme.selectionFill }
    static var selectionText: Color { WorkhorseTheme.selectionText }
    /// Chip backgrounds used by the status badge.
    static let failureChipBackground = adaptive(light: 0xFBEAEA, dark: 0x452D30)
    /// The "执行中" chip on a temporary terminal: accent tinted, because it reports
    /// activity rather than a problem.
    static let busyChipBackground = adaptive(light: 0xF1E5D5, dark: 0x393429)
    /// Particles of the delete transition. They are decoration rather than state, but they
    /// follow the same light/dark pairing as the status colours so the burst stays visible
    /// on either background.
    /// Deliberately more saturated than the status colours: a particle is decoration, and a
    /// muted one disappears against the card it just left — especially in dark mode, where
    /// the dark variants have to carry the whole effect on a near-black background.
    static let particlePalette: [Color] = [
        adaptive(light: 0x2563EB, dark: 0x7FA8FF),
        adaptive(light: 0x0EA5C6, dark: 0x4FD8F0),
        adaptive(light: 0x16A34A, dark: 0x4FE0A0),
        adaptive(light: 0xF59E0B, dark: 0xFFC24D),
        adaptive(light: 0xEF4444, dark: 0xFF7A72),
        adaptive(light: 0x8B5CF6, dark: 0xB49BFF),
    ]

    // MARK: - Tag tones

    /// The six tag colours, in `TagVocabulary.toneIndex` order. Green and red are missing on
    /// purpose: those belong to card *state* (成功 / 失败 / 执行中), and a tag pill in one of
    /// them reads as a status badge. `foreground` tints the dot and the name, `background`
    /// fills the pill, `border` draws its hairline.
    ///
    /// In dark mode the foreground brightens a full step: the light-mode values are tuned for
    /// a white pill and go muddy at 11pt on a near-black one.
    static let tagTones: [TagTone] = [
        TagTone(  // 紫 purple — "日常"
            foreground: adaptive(light: 0x6D4AC4, dark: 0xBFA8FF),
            background: adaptive(light: 0xEFEBFA, dark: 0x241F38),
            border: adaptive(light: 0xC9BCEE, dark: 0x443A66)
        ),
        TagTone(  // 青 teal — "数据库"
            foreground: adaptive(light: 0x0E7C8C, dark: 0x5FD6E8),
            background: adaptive(light: 0xE4F4F6, dark: 0x16282E),
            border: adaptive(light: 0xA8D6DD, dark: 0x2C525C)
        ),
        TagTone(  // 玫 rose — "客户"
            foreground: adaptive(light: 0xB03A6A, dark: 0xFFA3C6),
            background: adaptive(light: 0xFBEBF2, dark: 0x2C1E26),
            border: adaptive(light: 0xE8AFC7, dark: 0x5E2E45)
        ),
        TagTone(  // 灰 grey — "稍后"
            foreground: adaptive(light: 0x657180, dark: 0xB4BCC7),
            background: adaptive(light: 0xEEF0F3, dark: 0x262A31),
            border: adaptive(light: 0xCBD1D9, dark: 0x414751)
        ),
        TagTone(  // 琥珀 amber — "运维"
            foreground: adaptive(light: 0x8A5A0B, dark: 0xE8BC72),
            background: adaptive(light: 0xFAF1E0, dark: 0x2B2517),
            border: adaptive(light: 0xE4C68C, dark: 0x5C4A22)
        ),
        TagTone(  // 蓝 blue — "工作"
            foreground: adaptive(light: 0x315FDA, dark: 0x8FB0FF),
            background: adaptive(light: 0xE9EEFC, dark: 0x1E2740),
            border: adaptive(light: 0xB9C8F4, dark: 0x33406B)
        ),
    ]

    static let cardRadius: CGFloat = 10
    static let cornerRadius: CGFloat = 6
    static let homeIconSize: CGFloat = 18
    static let menuIconSize: CGFloat = 14

    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

/// Shared workbench material: 上工 (warm white) / 夜班 (graphite).
/// Both layouts and their common editors/settings consume these same semantic tokens.
enum WorkhorseTheme {
    /// 内容区底色。
    static let background = DeckTheme.adaptive(light: 0xF9F9F5, dark: 0x1A1E1C)
    /// 卡片、编辑页、设置页这类浮在底色上的面。
    static let panel = DeckTheme.adaptive(light: 0xFFFFFF, dark: 0x222724)
    /// 左侧菜单面板的底色。
    static let panelSecondary = DeckTheme.adaptive(light: 0xF0F1EB, dark: 0x202421)
    static let text = DeckTheme.adaptive(light: 0x252B29, dark: 0xE6EBE3)
    // Also readable over the darker hover / selected fills, not only the page background.
    static let muted = DeckTheme.adaptive(light: 0x606861, dark: 0xA1ACA0)
    static let line = DeckTheme.adaptive(light: 0xDDE1D8, dark: 0x343D34)
    /// 稻草金：链接、选中、计数与「执行中」都用它。
    static let accent = DeckTheme.adaptive(light: 0x95551F, dark: 0xDEB07E)
    /// Small labels need more contrast than decorative marks and large display numerals.
    static let accentText = accent
    /// 在线 / 成功。语义与卡片界面一致，只是换成同一族的暖色。
    static let green = DeckTheme.adaptive(light: 0x397153, dark: 0x94C9A0)
    /// 失败 / 异常。
    static let red = DeckTheme.adaptive(light: 0xA34235, dark: 0xF1A194)
    static let hover = DeckTheme.adaptive(light: 0xE8ECE3, dark: 0x2B332C)
    static let selection = DeckTheme.adaptive(light: 0xE3E8DD, dark: 0x333D31)
    /// 左右分隔线自己的颜色。
    ///
    /// 不能直接用 `line`：面板底（#EFE9DC）与内容区底（#F2EDE3）本来就只差一点点，
    /// 分隔线再用同族的浅色，整条分界就看不见了（真机全屏时就是这样）。这里取一档更实的沙色，
    /// 只比两侧底色深，仍然安静。
    static let divider = DeckTheme.adaptive(light: 0xC9CFC4, dark: 0x505C4D)
    /// 窗口标题栏要的 AppKit 颜色。
    ///
    /// SwiftUI 的 `Color` 交给 AppKit 会丢掉「随外观变化」的能力，所以这里按同一组色值重建一个
    /// 动态 NSColor。
    static var windowBackgroundNSColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? 0x1A1E1C : 0xF9F9F5)
        }
    }
    /// 「已开启」这类小标记的底色。
    static let accentSoft = DeckTheme.adaptive(light: 0xF1E5D5, dark: 0x393429)
    /// 删除确认、错误提示这类「红面」的暖色版本。
    static let redBackground = DeckTheme.adaptive(light: 0xFAF0EB, dark: 0x352924)
    static let redBorder = DeckTheme.adaptive(light: 0xE4C5B9, dark: 0x66463C)
    /// 编辑页与设置页里那几处「选中行」的底色。
    static let navSelection = selection
    /// 下拉菜单里当前那一行：与卡片界面一样，用亮底 + 深字。
    static let selectionFill = selection
    static let selectionText = text
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// One tag colour: what the dot and name are drawn in, what fills the pill, and its hairline.
struct TagTone {
    let foreground: Color
    let background: Color
    let border: Color

    /// The tone for a tag. The index comes from `TagVocabulary.toneIndex`, which hashes the
    /// tag's own name — so the colour needs no column in the database and never changes for a
    /// given tag. Tags whose names happen to hash alike share a colour; the block header's
    /// text, not the colour, is what names the category.
    static func of(_ tag: CardTag) -> TagTone {
        let tones = DeckTheme.tagTones
        guard !tones.isEmpty else {
            return TagTone(foreground: DeckTheme.muted, background: DeckTheme.panelSecondary, border: DeckTheme.line)
        }
        return tones[TagVocabulary.toneIndex(for: tag.name) % tones.count]
    }

    /// The "未加标签" bucket is not a tag: it gets no colour of its own, only muted greys.
    static var untagged: TagTone {
        TagTone(foreground: DeckTheme.muted, background: DeckTheme.panel, border: DeckTheme.line)
    }
}

/// Status dot + text (+ optional short chip) used by cards and detail headers.
/// The text never wraps: the chip carries the short extra state instead.
struct DeckStatusLabel: View {
    let presentation: SessionStatusPresentation
    var showsDot: Bool = true
    /// Square cards have no room for the activity chip; their round button spins instead.
    var showsBadge: Bool = true
    var isTask = false

    var body: some View {
        HStack(spacing: 5) {
            if showsDot, showsConnectionDot {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text(presentation.label)
                .font(.system(size: 12, weight: presentation.tone == .failed ? .medium : .regular))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if showsBadge, let badge = presentation.badge {
                badgeChip(badge)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The chip that rides beside the primary state. A running command gets the accent
    /// treatment with a small spinner; an alert keeps the existing tinted chip.
    @ViewBuilder
    private func badgeChip(_ badge: String) -> some View {
        if presentation.badgeKind == .busy {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 9, height: 9)
                Text(badge)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DeckTheme.accent)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 999)
                    .fill(DeckTheme.busyChipBackground)
            )
            .accessibilityLabel("正在执行命令")
        } else {
            Text(badge)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(badgeForeground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 999)
                        .fill(badgeBackground)
                )
        }
    }

    /// A connection state is calm by default: "在线" and "未运行" are plain text, and only
    /// the states that need attention (启动失败 / 意外退出) draw a dot. A card running a
    /// command keeps its dot, because there the dot reads as "something is happening" and
    /// the accent chip alone would leave the label looking inert.
    private var showsConnectionDot: Bool {
        switch presentation.tone {
        case .failed: return true
        case .running: return isTask || presentation.isCommandBusy
        case .executing, .idle, .busy: return true
        }
    }

    private var color: Color {
        switch presentation.tone {
        case .executing: return DeckTheme.accent
        case .running: return presentation.isCommandBusy ? DeckTheme.accent : DeckTheme.green
        case .failed: return DeckTheme.red
        case .idle, .busy: return DeckTheme.muted
        }
    }

    private var textColor: Color {
        switch presentation.tone {
        case .executing: return DeckTheme.accent
        case .failed: return DeckTheme.red
        case .running: return isTask ? DeckTheme.green : DeckTheme.muted
        case .idle, .busy: return DeckTheme.muted
        }
    }

    /// The alert chip (无响应) keeps the failure tint; anything else that reaches here is
    /// an activity chip, which uses the accent treatment instead.
    private var badgeForeground: Color {
        presentation.badgeTone == .failure ? DeckTheme.red : DeckTheme.amber
    }

    private var badgeBackground: Color {
        presentation.badgeTone == .failure ? DeckTheme.failureChipBackground : DeckTheme.busyChipBackground
    }
}

/// Small pill used for section counts.
struct DeckCountPill: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11))
            .foregroundStyle(DeckTheme.muted)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 999)
                    .fill(DeckTheme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 999).stroke(DeckTheme.line, lineWidth: 1))
            )
    }
}

/// Buttons matching the prototype's three variants.
struct DeckButtonStyle: ButtonStyle {
    enum Variant { case standard, primary, danger, small, smallPrimary, smallDanger }

    var variant: Variant = .standard
    var controlHeight: CGFloat? = nil
    var fontSize: CGFloat? = nil
    var minimumWidth: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize ?? (isSmall ? 12 : 13), weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, isSmall ? 9 : 12)
            .padding(.vertical, isSmall ? 5 : 7)
            .frame(minWidth: minimumWidth)
            .frame(height: controlHeight)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: DeckTheme.cornerRadius)
                    .stroke(borderColor, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DeckTheme.cornerRadius))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .focusEffectDisabled(false)
    }

    private var isSmall: Bool {
        variant == .small || variant == .smallPrimary || variant == .smallDanger
    }

    private var isPrimary: Bool { variant == .primary || variant == .smallPrimary }
    private var isDestructive: Bool { variant == .danger || variant == .smallDanger }

    private var foreground: Color {
        if isPrimary { return DeckTheme.panel }
        if isDestructive { return DeckTheme.destructive }
        return DeckTheme.text
    }

    private var background: Color {
        isPrimary ? DeckTheme.text : DeckTheme.panel
    }

    private var borderColor: Color {
        if isPrimary { return DeckTheme.text }
        return isDestructive ? DeckTheme.redBorder : DeckTheme.line
    }
}

/// Borderless icon button used in card action rows.
struct DeckIconButton: View {
    let systemName: String
    let help: String
    var tint: Color = DeckTheme.muted
    /// 热区尺寸。卡片上的图标按钮是 34×30；牛马模式的列表项只有 32–44pt 高，
    /// 用同一套尺寸会把行撑高，展开的那一行就会被挤出自己的高亮框。
    var wellWidth: CGFloat = 34
    var wellHeight: CGFloat = 30
    var action: () -> Void

    @State private var hovering = false

    /// Per-symbol vertical correction (points), tuned by eye.
    static func opticalNudge(for symbol: String) -> CGFloat {
        switch symbol {
        case "terminal.fill": return 1
        default: return 0
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                // A few SF Symbols sit high inside their bounding box; nudge the drawn
                // glyph so it looks centred next to the others.
                .offset(y: Self.opticalNudge(for: systemName))
                .frame(width: wellWidth, height: wellHeight)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(hovering ? DeckTheme.panelSecondary : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(DeckIconPressStyle())
        .focusEffectDisabled(false)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

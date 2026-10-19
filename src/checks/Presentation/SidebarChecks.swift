import Foundation
import Core

func registerSidebarChecks() {
    register("sidebar.existing-installations-default-to-pinned") {
        for value in [nil, "", "on", "off", "invalid"] as [String?] {
            try expectEqual(SidebarMode.stored(value), .pinned, "missing/invalid settings preserve existing layout")
        }
        try expectEqual(SidebarMode.stored("collapsed"), .collapsed, "explicit opt-in")
        try expectEqual(SidebarMode.stored("pinned"), .pinned, "explicit pin")
    }
    register("sidebar.preference-keys-are-independent") {
        try expect(SidebarMode.key != SplitMode.key && SidebarMode.key != SplitLayout.sidebarRatioKey,
                   "folding cannot replace layout mode or expanded width")
    }
    register("sidebar.peeks-never-reserve-expanded-width") {
        for width in [240.0, 296.0, 460.0] {
            try expectEqual(SidebarLayout.reservedWidth(mode: .collapsed, expandedWidth: width), 56,
                            "hover width is deliberately absent from allocation")
            try expectEqual(SidebarLayout.reservedWidth(mode: .pinned, expandedWidth: width), width + 9,
                            "existing divider and width remain unchanged when pinned")
        }
    }
    register("sidebar.rail-geometry-preserves-hit-targets") {
        try expectEqual(SidebarLayout.tileSize, 32, "approved letter tile")
        try expectEqual(SidebarLayout.ownerWidth, 40, "owner hit width")
        try expectEqual(SidebarLayout.ownerHeight, 44, "owner hit height")
        try expectEqual(SidebarLayout.groupWidth, 44, "named group fits within 56pt rail")
        try expectEqual(SidebarLayout.groupSpacing, 10, "groups have visible breathing room")
        try expect(SidebarLayout.tileSize < SidebarLayout.ownerWidth
                   && SidebarLayout.groupWidth < SidebarLayout.railWidth, "visual borders do not replace the hit target")
    }
    register("sidebar.rail-border-uses-all-seven-existing-statuses") {
        for kind in StatusDot.allCases {
            let border = SidebarRailBorder(kind)
            let width: CGFloat = kind == .executing || kind == .failed ? 2 : (kind == .idle ? 1 : 1.5)
            try expectEqual(border.lineWidth, width, "\(kind) stroke width")
            try expectEqual(border.isDashed, kind == .starting || kind == .unresponsive, "\(kind) transient line style")
            try expectEqual(border.showsRunningLight, kind == .executing || kind == .liveBusy, "\(kind) only real command activity moves")
        }
        try expectEqual(SidebarRailBorder.orbitDuration, 2.4, "approved orbit duration")
    }
    register("sidebar.rail-border-never-reinterprets-status-data") {
        for (status, expected) in [
            (SessionStatusPresentation(label: "执行中", tone: .executing), StatusDot.executing),
            (.init(label: "在线", tone: .running), .live),
            (.init(label: "在线", tone: .running, badge: "执行中", badgeKind: .busy), .liveBusy),
            (.init(label: "正在终止", tone: .busy, badge: "无响应", badgeTone: .failure), .unresponsive),
            (.init(label: "正在启动", tone: .busy), .starting),
            (.init(label: "失败", tone: .failed), .failed),
            (.init(label: "未运行", tone: .idle), .idle),
        ] {
            try expectEqual(SidebarRailBorder(.of(status)).kind, expected, "same status source as cards and expanded rows")
        }
    }
    register("sidebar.monograms-are-derived-and-grapheme-safe") {
        for (title, expected) in [("Learning Agent", "LA"), ("Terminal Dashboard", "TD"), ("Agents Usage", "AU"),
                                  ("  单字  ", "单字"), ("🚀项目", "🚀项"), ("", "")] {
            try expectEqual(SidebarLayout.monogram(title: title), expected, "real title: \(title)")
        }
        try expectEqual(SidebarLayout.monogram(title: "终端 12", terminal: true), "12", "terminal index")
    }
}

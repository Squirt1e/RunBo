import CoreGraphics
import Foundation
import Core

private let homeEpoch = Date(timeIntervalSince1970: 1_800_000_000)

private func homeRuntime(_ id: String, kind: SessionKind = .preset, status: SessionStatus = .running,
                         busy: Bool = false, ready: Bool = true, failed: Bool = false,
                         started: TimeInterval = 0, sessionID: String? = nil) -> SessionRuntime {
    SessionRuntime(sessionId: sessionID ?? "session-\(id)", key: OwnerKey(kind: kind, ownerId: id),
                   title: "Old \(id)", shell: "/bin/zsh", workingDirectory: "/Users/test/Projects/app",
                   status: status, lastCommandFailed: failed, lastCommandStatusUnknown: false,
                   lastCommandExitStatus: failed ? 1 : nil, needsForceTermination: false,
                   startedAt: homeEpoch.addingTimeInterval(started), isReady: ready, isCommandRunning: busy,
                   lastCommandText: "private terminal input")
}

private func homeRecord(_ id: String, kind: SessionKind = .preset, started: TimeInterval = 0,
                        finished: Bool = true, failed: Bool = false, sessionID: String? = nil) -> SessionRecord {
    SessionRecord(id: sessionID ?? "session-\(id)", kind: kind, ownerId: id, title: "Old \(id)", shell: "/bin/zsh",
                  workingDirectory: "/Users/test/Projects/app", startedAt: homeEpoch.addingTimeInterval(started),
                  endedAt: finished ? homeEpoch.addingTimeInterval(started + 60) : nil,
                  termination: finished ? .normal : nil, lastCommandFailed: failed,
                  lastCommandText: "private terminal input")
}

private func homeSnapshot(cards: [PresetCard] = [], temps: [TempTerminal] = [], runtimes: [SessionRuntime] = [],
                          records: [SessionRecord] = []) -> HomeSnapshot {
    HomeSnapshot(cards: cards, temps: temps, runtimes: runtimes,
                          storedSessions: Dictionary(uniqueKeysWithValues: records.map {
                              (OwnerKey(kind: $0.kind, ownerId: $0.ownerId), $0)
                          }), homeDirectory: "/Users/test")
}

func registerHomeProjectionChecks() {
    register("split-home.empty-has-real-zeroes-and-no-fabricated-entries") {
        let home = homeSnapshot()
        try expectEqual(home.executingCount, 0, "no tasks")
        try expectEqual(home.onlineCount, 0, "no online terminals")
        try expect(home.items.isEmpty && home.working.isEmpty && home.attention.isEmpty && home.recent.isEmpty,
                   "an empty store does not acquire demo cards or sessions")
        try expect(!home.hasRunHistory, "first launch has no history")
    }

    register("split-home.counts-tasks-and-connections-with-different-rules") {
        let cards = ["executing", "completed", "starting"].map { PresetCard(id: $0, title: $0, command: "echo \($0)") }
        let temps = ["idle", "busy", "booting", "stopping"].map { TempTerminal(id: $0, title: $0) }
        var completed = homeRuntime("completed")
        completed.lastCommandExitStatus = 0
        let home = homeSnapshot(cards: cards, temps: temps, runtimes: [
            homeRuntime("executing", busy: true), completed,
            homeRuntime("starting", status: .starting, ready: false),
            homeRuntime("idle", kind: .temp), homeRuntime("busy", kind: .temp, busy: true),
            homeRuntime("booting", kind: .temp, status: .starting, ready: false),
            homeRuntime("stopping", kind: .temp, status: .stopping),
        ])
        try expectEqual(home.executingCount, 1, "completed shells and transitional states do not count as executing")
        try expectEqual(home.onlineCount, 2, "idle/busy ready terminals count; starting/stopping do not")
        try expect(!home.working.contains { $0.key.ownerId == "completed" || $0.key.ownerId == "idle" },
                   "idle shells are not fabricated tasks")
        try expect(home.working.contains { $0.key.ownerId == "booting" }, "connection transitions remain reachable")
        try expectEqual(home.attention.count, 0, "normal transitions are not errors")
    }

    register("split-home.stored-open-sessions-are-never-treated-as-live") {
        let home = homeSnapshot(temps: [TempTerminal(id: "terminal", title: "Terminal")],
                                records: [homeRecord("terminal", kind: .temp, finished: false)])
        try expectEqual(home.onlineCount, 0, "a stored open row cannot reconnect a shell after relaunch")
        try expect(home.working.isEmpty, "only an actual runtime can be working")
        try expect(home.hasRunHistory && home.recent.count == 1, "stored start time can still populate recents")
    }

    register("split-home.only-latest-owner-failures-need-attention") {
        var unknown = homeRecord("unknown", failed: true)
        unknown.lastCommandStatusUnknown = true
        var crash = homeRecord("crash", kind: .temp)
        crash.unexpectedExit = true
        var launch = homeRecord("launch")
        launch.launchFailed = true
        let home = homeSnapshot(
            cards: ["failed", "unknown", "launch"].map { PresetCard(id: $0, title: $0, command: "echo test") },
            temps: [TempTerminal(id: "interactive", title: "Interactive"), TempTerminal(id: "crash", title: "Crash")],
            records: [homeRecord("failed", failed: true), unknown, launch,
                      homeRecord("interactive", kind: .temp, failed: true), crash])
        try expectEqual(Set(home.attention.compactMap(\.attention)), [.commandFailed, .launchFailed, .unexpectedExit],
                        "command failures, launch failures and crashes have distinct reasons")
        try expectEqual(home.attention.count, 3, "unknown status and failed terminal commands are not errors")
        try expectEqual(home.attention.first { $0.key.ownerId == "crash" }?.historySessionID, nil,
                        "temporary terminals never offer preset history")
    }

    register("split-home.new-command-and-restart-clear-old-failure") {
        let cards = [PresetCard(id: "busy", title: "Busy", command: "make"),
                     PresetCard(id: "restart", title: "Restart", command: "make")]
        let home = homeSnapshot(cards: cards,
                                runtimes: [homeRuntime("busy", busy: true, failed: true),
                                           homeRuntime("restart", status: .starting, ready: false, started: 100, sessionID: "new")],
                                records: [homeRecord("busy", finished: false, failed: true), homeRecord("restart", failed: true)])
        try expect(home.attention.isEmpty, "old result cannot make a new attempt red")
        try expectEqual(home.working.count, 2, "both new attempts appear at the worksite")
        try expect(home.items.allSatisfy { $0.historySessionID == nil }, "old history does not impersonate the current run")
    }

    register("split-home.finished-failure-persists-and-has-exact-history-destination") {
        let card = PresetCard(id: "backup", title: "Backup", command: "backup")
        let record = homeRecord("backup", failed: true)
        let runtime = homeRuntime("backup", status: .stopped, failed: true)
        let home = homeSnapshot(cards: [card], runtimes: [runtime], records: [record])
        let item = try expectUnwrap(home.attention.first, "failed owner")
        try expectEqual(item.attention, .commandFailed, "stopping the shell does not erase the latest failed result")
        try expectEqual(item.destination, .detail(item.key), "ordinary card navigation is detail-only")
        try expectEqual(item.attentionDestination, .history(item.key, record.id), "replay exactly the failed run")
        try expect(home.working.isEmpty && home.recent.isEmpty, "no duplicate failure card in another section")
    }

    register("split-home.live-failure-falls-back-to-detail-without-finished-history") {
        let home = homeSnapshot(cards: [PresetCard(id: "fail", title: "Fail", command: "false")],
                                runtimes: [homeRuntime("fail", failed: true)],
                                records: [homeRecord("fail", finished: false, failed: true)])
        let item = try expectUnwrap(home.attention.first, "live failed command")
        try expectEqual(item.historySessionID, nil, "unfinished history is not offered as a finished replay")
        try expectEqual(item.attentionDestination, .detail(item.key), "view the still-live terminal instead")
    }

    register("split-home.unresponsive-stop-is-actionable-not-online") {
        var runtime = homeRuntime("stuck", kind: .temp, status: .stopping)
        runtime.needsForceTermination = true
        let home = homeSnapshot(temps: [TempTerminal(id: "stuck", title: "Stuck")], runtimes: [runtime])
        try expectEqual(home.attention.first?.attention, .unresponsive, "surface the existing force-stop hint")
        try expectEqual(home.onlineCount, 0, "a stopping connection is not online")
        try expectEqual(home.working.count, 1, "the transitional owner remains accessible")
    }

    register("split-home.newer-stored-run-wins-over-stale-runtime-callback") {
        let home = homeSnapshot(cards: [PresetCard(id: "card", title: "Card", command: "make")],
                                runtimes: [homeRuntime("card", status: .failed)],
                                records: [homeRecord("card", started: 100, sessionID: "new")])
        try expect(home.attention.isEmpty && home.working.isEmpty, "old callback cannot revive an old failure")
        try expectEqual(home.recent.first?.startedAt, homeEpoch.addingTimeInterval(100), "most recent run is authoritative")
    }

    register("split-home.finished-record-defeats-a-late-live-snapshot") {
        let home = homeSnapshot(cards: [PresetCard(id: "card", title: "Card", command: "make")],
                                runtimes: [homeRuntime("card", busy: true)], records: [homeRecord("card")])
        try expectEqual(home.executingCount, 0, "finished stored run cannot remain executing")
        try expect(home.working.isEmpty && home.recent.count == 1, "final state wins for the same session")
    }

    register("split-home.runtime-deduplication-is-stable-and-keeps-all-current-owners") {
        let cards = (0..<6).map { PresetCard(id: "\($0)", title: "Card \($0)", command: "make") }
        let runtimes = cards.map { homeRuntime($0.id, busy: true, started: 100) }
            + [homeRuntime("0", status: .failed, started: -100), homeRuntime("deleted", busy: true)]
        let first = homeSnapshot(cards: cards, runtimes: runtimes)
        let reversed = homeSnapshot(cards: cards, runtimes: Array(runtimes.reversed()))
        try expectEqual(first, reversed, "incoming dictionary order does not shuffle items")
        try expectEqual(first.working.count, 6, "snapshot does not silently truncate tasks beyond two")
        try expectEqual(first.executingCount, 6, "one current owner counts once; deleted owners never count")
        try expect(first.attention.isEmpty, "earlier failure is gone")
    }

    register("split-home.recents-use-session-start-not-card-edits-or-terminal-io") {
        let cards = [PresetCard(id: "old", title: "Old", command: "echo old", updatedAt: .distantFuture),
                     PresetCard(id: "new", title: "New", command: "echo new", updatedAt: .distantPast),
                     PresetCard(id: "never", title: "Never", command: "echo never")]
        let temps = [TempTerminal(id: "terminal", title: "Terminal", lastActivityAt: .distantFuture)]
        let home = homeSnapshot(cards: cards, temps: temps,
                                records: [homeRecord("old", started: 0), homeRecord("new", started: 100),
                                          homeRecord("terminal", kind: .temp, started: -100)])
        try expectEqual(home.recent.map { $0.key.ownerId }, ["new", "old", "terminal"],
                        "card edits and terminal activity are not visits or starts")
        try expectEqual(home.recent.first?.destination, .detail(OwnerKey(kind: .preset, ownerId: "new")),
                        "recent cards navigate; they do not relaunch")
    }

    register("split-home.current-config-and-safe-terminal-subtitles-only") {
        let card = PresetCard(id: "same", title: "Renamed", command: "echo saved-config")
        let temp = TempTerminal(id: "same", title: "Renamed terminal")
        let home = homeSnapshot(cards: [card], temps: [temp],
                                runtimes: [homeRuntime("same"), homeRuntime("same", kind: .temp)])
        let preset = try expectUnwrap(home.items.first { $0.key.kind == .preset }, "preset")
        let terminal = try expectUnwrap(home.items.first { $0.key.kind == .temp }, "terminal")
        try expectEqual(preset.title, card.title, "use current owner title, not history snapshot")
        try expectEqual(preset.subtitle, card.command, "use saved command, not last typed input")
        try expectEqual(terminal.subtitle, "zsh · ~/Projects/app", "terminal shows shell/path only")
        try expect(preset.id != terminal.id, "same string ID in different menus is not the same owner")
        try expect(home.items.allSatisfy { !$0.subtitle.contains("private terminal input") }, "no raw terminal input on home")
    }

    register("split-home.path-abbreviation-respects-directory-boundaries") {
        var runtime = homeRuntime("terminal", kind: .temp)
        runtime.workingDirectory = "/Users/test-other/project"
        var home = homeSnapshot(temps: [TempTerminal(id: "terminal", title: "Terminal")], runtimes: [runtime])
        try expectEqual(home.items.first?.subtitle, "zsh · /Users/test-other/project", "do not shorten a different user's path")
        runtime.workingDirectory = "/Users/test"
        home = homeSnapshot(temps: [TempTerminal(id: "terminal", title: "Terminal")], runtimes: [runtime])
        try expectEqual(home.items.first?.subtitle, "zsh · ~", "home itself abbreviates to tilde")
    }

    register("split-home.mismatched-history-owner-is-ignored") {
        let key = OwnerKey(kind: .preset, ownerId: "card")
        let home = HomeSnapshot(cards: [PresetCard(id: "card", title: "Card", command: "make")], temps: [],
                                         runtimes: [], storedSessions: [key: homeRecord("other", failed: true)])
        try expect(home.attention.isEmpty && home.recent.isEmpty, "wrong owner cannot supply a timestamp, error or replay action")
    }

    register("split-home.projection-does-not-mutate-stored-data") {
        let (store, root) = try makeStore("home-projection")
        defer { TempSpace.clean(root) }
        let card = PresetCard(id: "card", title: "Card", command: "make", createdAt: homeEpoch, updatedAt: homeEpoch)
        try store.save(card)
        try store.save(homeRecord("card", failed: true))
        let before = try store.sessions(kind: .preset, ownerId: card.id)
        let records = [try expectUnwrap(store.latestSession(kind: .preset, ownerId: card.id), "persisted latest run")]
        let first = homeSnapshot(cards: try store.cards(), records: records)
        let reopened = try DataStore(directory: root)
        let second = homeSnapshot(cards: try reopened.cards(), records: records)
        try expectEqual(first, second, "reopening keeps latest result and start order")
        try expectEqual(try reopened.cards(), [card], "no command/configuration/order/timestamp changes")
        try expectEqual(try reopened.sessions(kind: .preset, ownerId: card.id), before, "no new sessions or rewritten history")
    }

    register("split-home.layout-default-narrow-and-wide") {
        let normal = HomeLayout(width: 804)
        try expectEqual(normal.contentWidth, 716, "44pt margins match the approved default mockup")
        try expect(normal.showsEmblem && normal.inlineMetrics, "roomy home keeps the instrument emblem")
        try expectEqual(normal.workingColumns, 2, "two work cards")
        try expectEqual(normal.recentColumns, 3, "three recent cards")
        let narrow = HomeLayout(width: 560)
        try expect(!narrow.showsEmblem && !narrow.inlineMetrics, "tight width prioritizes real content")
        try expectEqual(narrow.workingColumns, 1, "work cards stack")
        try expectEqual(narrow.recentColumns, 1, "recents stack too")
        try expect(!normal.splitsSections && !narrow.splitsSections, "ordinary windows stack the sections")
        let wide = HomeLayout(width: 2094, height: 1382)
        try expectEqual(wide.contentWidth, 1966, "large windows use the right pane instead of a 900pt island")
        try expect(wide.splitsSections, "wide windows place work and recents side by side")
        try expect(abs(wide.workingWidth + wide.sectionGap + wide.recentWidth - wide.contentWidth) < 0.001,
                   "the section widths exactly fill the content width")
        try expect(wide.titleSize >= normal.titleSize && wide.titleSize <= 34,
                   "display type is bounded instead of growing into a billboard")
        try expect(wide.emblemDiameter <= 112 && normal.emblemDiameter <= 112 && wide.heroHeight <= 160,
                   "the ox stays a compact brand signature at every window size")
    }

    register("split-home.layout-single-items-do-not-reserve-empty-columns") {
        for width: CGFloat in [560, 804, 1240, 1600, 2094, 4000] {
            let layout = HomeLayout(width: width)
            try expectEqual(layout.workingColumns(itemCount: 1), 1, "one working card spans its section")
            try expectEqual(layout.recentColumns(itemCount: 1), 1, "one recent card spans its section")
            try expectEqual(layout.workingColumns(itemCount: 0), 1, "empty grid never has zero columns")
            try expectEqual(layout.recentColumns(itemCount: -1), 1, "invalid count never creates a negative grid")
            try expect(layout.workingColumns(itemCount: 2) <= 2 && layout.recentColumns(itemCount: 2) <= 2,
                       "only real items allocate columns")
            try expect(layout.workingPreviewLimit >= layout.workingColumns, "the preview fills at least one grid row")
        }
    }

    register("split-home.layout-breakpoints-and-section-card-widths") {
        try expect(!HomeLayout(width: 1204).splitsSections, "just below the split threshold stays stacked")
        try expect(HomeLayout(width: 1208).splitsSections, "1120pt of usable content splits sections")
        try expectEqual(HomeLayout(width: 720).recentColumns, 2, "intermediate widths support two recent cards")
        try expectEqual(HomeLayout(width: 4000).workingColumns, 3, "very wide work sections gain a third column")
        var previous: CGFloat = 0
        for value in stride(from: 760, through: 4000, by: 4) {
            let width = CGFloat(value)
            let layout = HomeLayout(width: width)
            try expect(layout.contentWidth >= previous, "usable width grows continuously instead of hitting a fixed cap")
            try expectEqual(layout.contentWidth + layout.padding * 2, width, "only responsive outer margins are reserved")
            let workCard = (layout.workingWidth - layout.sectionPadding * 2 - CGFloat(layout.workingColumns - 1) * 14)
                / CGFloat(layout.workingColumns)
            let recentCard = (layout.recentWidth - layout.sectionPadding * 2 - CGFloat(layout.recentColumns - 1) * 14)
                / CGFloat(layout.recentColumns)
            try expect(workCard >= 300 && recentCard >= 210, "columns account for section padding, not the whole pane")
            previous = layout.contentWidth
        }
    }

    register("split-home.layout-bounds-decoration-and-invalid-geometry") {
        let short = HomeLayout(width: 2094, height: 400)
        let tall = HomeLayout(width: 2094, height: 2000)
        try expect(short.heroHeight < tall.heroHeight && tall.heroHeight <= 160, "short windows compress the signature and tall windows never turn it into a billboard")
        try expect(short.emblemDiameter + 24 <= short.heroHeight, "short wide windows keep decoration inside the hero")
        for width: CGFloat in [0, 12, -100, .nan, .infinity] {
            for height: CGFloat in [0, -100, .nan, .infinity, 4000] {
                let layout = HomeLayout(width: width, height: height)
                try expect(layout.contentWidth.isFinite && layout.contentWidth >= 0, "invalid width cannot produce a negative/infinite frame")
                try expect(layout.heroHeight.isFinite && layout.heroHeight > 0, "invalid height keeps a usable hero")
            }
        }
    }

    register("split-home.invalid-start-time-is-not-formatted-as-a-recent-date") {
        var record = homeRecord("card")
        record.startedAt = Date(timeIntervalSince1970: .nan)
        let home = homeSnapshot(cards: [PresetCard(id: "card", title: "Card", command: "make")], records: [record])
        try expectEqual(home.items.first?.startedAt, nil, "corrupt timestamp is treated as unknown")
        try expect(home.recent.isEmpty, "do not pass an invalid date to the relative formatter")
    }

    register("split-home.session-duration-is-bounded-and-not-command-duration") {
        for (elapsed, expected) in [(0.0, "00:00"), (84, "01:24"), (3601, "1:00:01"), (-60, "00:00")] {
            try expectEqual(HomeFormatting.sessionDuration(since: homeEpoch, now: homeEpoch.addingTimeInterval(elapsed)),
                            expected, "session duration at \(elapsed)")
        }
        try expectEqual(HomeFormatting.sessionDuration(since: homeEpoch, now: Date(timeIntervalSince1970: .infinity)),
                        "00:00", "invalid clock cannot trap a numeric conversion")
    }
}

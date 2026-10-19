import Foundation
import Core

private let retentionNow = Date(timeIntervalSince1970: 1_800_000_000)

private func hoursAgo(_ hours: Double) -> Date {
    retentionNow.addingTimeInterval(-hours * 3600)
}

private func tempTerminal(id: String, activityHoursAgo: Double) -> TempTerminal {
    TempTerminal(id: id, title: id, createdAt: hoursAgo(activityHoursAgo + 48), lastActivityAt: hoursAgo(activityHoursAgo))
}

private func sessionRecord(ownerId: String, finished: Bool, activityHoursAgo: Double) -> SessionRecord {
    let started = hoursAgo(activityHoursAgo + 2)
    return SessionRecord(
        id: "session-\(ownerId)",
        kind: .temp,
        ownerId: ownerId,
        title: ownerId,
        shell: "/bin/zsh",
        startedAt: started,
        endedAt: finished ? started.addingTimeInterval(60) : nil,
        termination: finished ? .exited : nil
    )
}

func registerRetentionChecks() {
    register("retention.running-session-never-expires") {
        // 100 hours of idleness, but the session is still running: never expire.
        let temp = tempTerminal(id: "t-run", activityHoursAgo: 100)
        let expired = RetentionPolicy.expiredTempIDs(
            temps: [temp],
            latestSessions: ["t-run": sessionRecord(ownerId: "t-run", finished: false, activityHoursAgo: 100)],
            now: retentionNow
        )
        try expectEqual(expired, [], "a running temp must never be expired by the clock")
    }

    register("retention.23h-finished-survives") {
        let temp = tempTerminal(id: "t-23", activityHoursAgo: 23)
        let expired = RetentionPolicy.expiredTempIDs(
            temps: [temp],
            latestSessions: ["t-23": sessionRecord(ownerId: "t-23", finished: true, activityHoursAgo: 23)],
            now: retentionNow
        )
        try expectEqual(expired, [], "23 hours of idleness must not expire")
    }

    register("retention.25h-finished-expires") {
        let temp = tempTerminal(id: "t-25", activityHoursAgo: 25)
        let expired = RetentionPolicy.expiredTempIDs(
            temps: [temp],
            latestSessions: ["t-25": sessionRecord(ownerId: "t-25", finished: true, activityHoursAgo: 25)],
            now: retentionNow
        )
        try expectEqual(expired, ["t-25"], "25 hours of idleness must expire")
    }

    register("retention.exactly-24h-expires") {
        let temp = tempTerminal(id: "t-24", activityHoursAgo: 24)
        let expired = RetentionPolicy.expiredTempIDs(
            temps: [temp],
            latestSessions: ["t-24": sessionRecord(ownerId: "t-24", finished: true, activityHoursAgo: 24)],
            now: retentionNow
        )
        try expectEqual(expired, ["t-24"], "exactly 24 hours must expire (deadline <= now)")
        try expectEqual(RetentionPolicy.tempIdleTimeout, 86_400, "tempIdleTimeout is 24 hours")
        try expectEqual(RetentionPolicy.sessionHistoryLimit, 2, "both card kinds keep this run and the previous one")
    }

    register("retention.no-session-uses-own-activity") {
        let fresh = tempTerminal(id: "t-fresh", activityHoursAgo: 23)
        let stale = tempTerminal(id: "t-stale", activityHoursAgo: 25)
        let expired = RetentionPolicy.expiredTempIDs(temps: [fresh, stale], latestSessions: [:], now: retentionNow)
        try expectEqual(expired, ["t-stale"], "without a session the temp's own lastActivityAt decides")
    }

    register("retention.mixed-temps") {
        let temps = [
            tempTerminal(id: "t-running", activityHoursAgo: 200),
            tempTerminal(id: "t-1h", activityHoursAgo: 1),
            tempTerminal(id: "t-30h", activityHoursAgo: 30),
            tempTerminal(id: "t-nosession", activityHoursAgo: 40),
        ]
        let latest: [String: SessionRecord] = [
            "t-running": sessionRecord(ownerId: "t-running", finished: false, activityHoursAgo: 200),
            "t-1h": sessionRecord(ownerId: "t-1h", finished: true, activityHoursAgo: 1),
            "t-30h": sessionRecord(ownerId: "t-30h", finished: true, activityHoursAgo: 30),
        ]
        let expired = Set(RetentionPolicy.expiredTempIDs(temps: temps, latestSessions: latest, now: retentionNow))
        try expectEqual(expired, ["t-30h", "t-nosession"], "only the expired, non-running temps are returned")
    }

    register("retention.trim-keeps-current-and-previous-plus-running") {
        let root = try TempSpace.make("retention-trim")
        defer { TempSpace.clean(root) }
        let store = try DataStore(directory: root)

        let cardId = "card-trim"
        try store.save(PresetCard(id: cardId, title: "Trim", command: "echo trim"))
        let base = Date(timeIntervalSince1970: 1_800_100_000)

        // 5 finished sessions, oldest first: finished-0 (oldest) ... finished-4 (newest).
        for index in 0..<5 {
            let started = base.addingTimeInterval(Double(index) * 60)
            let record = SessionRecord(
                id: "finished-\(index)",
                kind: .preset,
                ownerId: cardId,
                title: "Trim",
                shell: "/bin/zsh",
                startedAt: started,
                endedAt: started.addingTimeInterval(30),
                termination: .normal
            )
            try store.save(record)
            try store.append([SessionEvent(sessionId: record.id, sequence: 0, kind: .output, data: Data(repeating: 0x41, count: index))])
        }
        // One running session, newest of all: it must survive trimming.
        let running = SessionRecord(
            id: "running",
            kind: .preset,
            ownerId: cardId,
            title: "Trim",
            shell: "/bin/zsh",
            startedAt: base.addingTimeInterval(10_000)
        )
        try store.save(running)
        try store.append([SessionEvent(sessionId: "running", sequence: 0, kind: .output, data: Data([0x52]))])

        try expectEqual(try store.sessions(kind: .preset, ownerId: cardId).count, 6, "6 sessions before trimming")

        let deleted = try store.trimHistory(kind: .preset, ownerId: cardId, limit: 2)
        try expectEqual(deleted, ["finished-2", "finished-1", "finished-0"], "only the two newest finished sessions remain")

        let remaining = try store.sessions(kind: .preset, ownerId: cardId)
        try expectEqual(remaining.count, 3, "2 finished + 1 running remain")
        try expect(remaining.contains { $0.id == "running" }, "the running session must survive trimming")
        try expectEqual(remaining.filter { $0.isFinished }.map(\.id), ["finished-4", "finished-3"], "newest finished sessions first")
        try expectEqual(try store.events(sessionId: "finished-0"), [], "trimmed session history removed")
        try expectEqual(try store.events(sessionId: "finished-4").count, 1, "kept session history survives")

        // Trimming again is a no-op once only two finished sessions remain.
        try expectEqual(try store.trimHistory(kind: .preset, ownerId: cardId, limit: 2), [], "second trim is a no-op")
        try expectEqual(try store.sessions(kind: .preset, ownerId: cardId).count, 3, "second trim keeps everything")

        // A running session counts as this run: only one finished predecessor stays.
        let beforeStartTrim = try store.trimHistory(kind: .preset, ownerId: cardId,
                                                    limit: RetentionPolicy.sessionHistoryLimit - 1)
        try expectEqual(beforeStartTrim, ["finished-3"], "starting a run drops the older predecessor")
        try expectEqual(try store.sessions(kind: .preset, ownerId: cardId).filter(\.isFinished).map(\.id),
                        ["finished-4"], "exactly one finished predecessor remains beside the running run")
    }

    register("retention.applies-to-terminal-cards-too") {
        let root = try TempSpace.make("retention-temp-trim")
        defer { TempSpace.clean(root) }
        let store = try DataStore(directory: root)
        let temp = TempTerminal(id: "temp-trim", title: "Terminal")
        try store.save(temp)
        let base = Date(timeIntervalSince1970: 1_800_200_000)
        for index in 0..<4 {
            let started = base.addingTimeInterval(Double(index) * 60)
            try store.save(SessionRecord(
                id: "temp-finished-\(index)", kind: .temp, ownerId: temp.id,
                title: temp.title, shell: "/bin/zsh", startedAt: started,
                endedAt: started.addingTimeInterval(30), termination: .normal
            ))
            try store.append([SessionEvent(sessionId: "temp-finished-\(index)", sequence: 0,
                                          kind: .output, data: Data("temp \(index)".utf8))])
        }
        let deleted = try store.trimHistory(kind: .temp, ownerId: temp.id)
        try expectEqual(deleted, ["temp-finished-1", "temp-finished-0"],
                        "terminal cards keep only the current and previous record")
        try expectEqual(try store.sessions(kind: .temp, ownerId: temp.id).map(\.id),
                        ["temp-finished-3", "temp-finished-2"], "newest two terminal records remain")
    }

    register("retention.trim-all-upgrades-existing-history") {
        let root = try TempSpace.make("retention-trim-all")
        defer { TempSpace.clean(root) }
        let store = try DataStore(directory: root)
        try store.save(PresetCard(id: "legacy", title: "Legacy", command: "true"))
        try store.save(TempTerminal(id: "legacy-temp", title: "Legacy terminal"))
        let base = Date(timeIntervalSince1970: 1_800_300_000)
        for (index, owner) in [("legacy", SessionKind.preset), ("legacy-temp", SessionKind.temp)] {
            for run in 0..<4 {
                let started = base.addingTimeInterval(Double(run) * 60)
                try store.save(SessionRecord(
                    id: "\(index)-\(run)", kind: owner, ownerId: index, title: index,
                    shell: "/bin/zsh", startedAt: started,
                    endedAt: started.addingTimeInterval(30), termination: .normal
                ))
            }
        }
        // A session row whose card is gone can never be shown again; startup removes it.
        try store.save(SessionRecord(
            id: "orphan-session", kind: .preset, ownerId: "missing-card", title: "Orphan",
            shell: "/bin/zsh", startedAt: base, endedAt: base, termination: .normal
        ))
        try store.append([SessionEvent(sessionId: "orphan-session", sequence: 0,
                                      kind: .output, data: Data("orphan".utf8))])
        let removed = try store.trimAllHistory()
        try expectEqual(removed.count, 5, "four old records plus the orphan row are removed")
        try expect(try store.session(id: "orphan-session") == nil, "orphaned session row is deleted")
        try expectEqual(try store.events(sessionId: "orphan-session"), [], "orphaned history blob is deleted")
        try expectEqual(try store.sessions(kind: .preset, ownerId: "legacy").count, 2, "preset keeps two")
        try expectEqual(try store.sessions(kind: .temp, ownerId: "legacy-temp").count, 2, "terminal keeps two")
        try expectEqual(try store.trimAllHistory(), [], "second pass is a no-op")
    }
}

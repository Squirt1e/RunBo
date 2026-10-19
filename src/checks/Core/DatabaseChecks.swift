import Foundation
import Core

private final class DatabaseCheckErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        messages.append(String(describing: error))
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
}

private enum ExpectedRollback: Error { case requested }

/// Hold one transaction open while another queue tries either a transaction or a
/// single statement. Neither may enter the first transaction or inherit its rollback.
private func checkTransactionIsolation(rollback: Bool) throws {
    let database = try Database(path: ":memory:")
    try database.execute("CREATE TABLE writes (value TEXT NOT NULL);")
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let attempting = DispatchSemaphore(value: 0)
    let competitorFinished = DispatchSemaphore(value: 0)
    let group = DispatchGroup()
    let errors = DatabaseCheckErrors()

    group.enter()
    DispatchQueue.global().async {
        defer { group.leave() }
        do {
            try database.transaction {
                try database.run("INSERT INTO writes VALUES ('owner');")
                entered.signal()
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw CheckFailure("timed out releasing the owner transaction")
                }
                if rollback { throw ExpectedRollback.requested }
            }
        } catch ExpectedRollback.requested {
            // Deliberately roll back only the owner's write.
        } catch {
            errors.record(error)
        }
    }
    defer { release.signal() }
    try expect(entered.wait(timeout: .now() + 5) == .success, "owner entered its transaction")

    group.enter()
    DispatchQueue.global().async {
        defer { competitorFinished.signal(); group.leave() }
        attempting.signal()
        do {
            if rollback {
                try database.run("INSERT INTO writes VALUES ('competitor');")
            } else {
                try database.transaction {
                    try database.run("INSERT INTO writes VALUES ('competitor');")
                }
            }
        } catch {
            errors.record(error)
        }
    }
    try expect(attempting.wait(timeout: .now() + 5) == .success, "competitor started")
    let completedBeforeRelease = competitorFinished.wait(timeout: .now() + 0.15) == .success
    release.signal()
    try expect(group.wait(timeout: .now() + 5) == .success, "both writers finished without deadlock")
    try expect(!completedBeforeRelease, "another queue must wait for the whole transaction")
    try expectEqual(errors.all, [], "concurrent database errors")
    let values = try database.query("SELECT value FROM writes ORDER BY value;") { $0.string(0) }
    try expectEqual(values, rollback ? ["competitor"] : ["competitor", "owner"],
                    "rollback must not swallow another queue's write")
}

func registerDatabaseChecks() {
    register("database.concurrent-transactions-are-serialized") {
        try checkTransactionIsolation(rollback: false)
    }

    register("database.rollback-does-not-absorb-another-writer") {
        try checkTransactionIsolation(rollback: true)
    }

    register("database.failed-transaction-rolls-back-and-recovers") {
        let database = try Database(path: ":memory:")
        try database.execute("CREATE TABLE writes (value TEXT UNIQUE);")
        _ = try expectThrows("failed batch") {
            try database.transaction {
                try database.run("INSERT INTO writes VALUES ('duplicate');")
                try database.run("INSERT INTO writes VALUES ('duplicate');")
            }
        }
        try database.transaction {
            try database.run("INSERT INTO writes VALUES ('recovered');")
        }
        let values = try database.query("SELECT value FROM writes;") { $0.string(0) }
        try expectEqual(values, ["recovered"], "failed batch is atomic and the next transaction works")
    }

    register("database.concurrent-history-appends") {
        let (store, root) = try makeStore("concurrent-history")
        defer { TempSpace.clean(root) }
        let errors = DatabaseCheckErrors()
        DispatchQueue.concurrentPerform(iterations: 8) { writer in
            for sequence in 0..<20 {
                do {
                    try store.append([SessionEvent(
                        sessionId: "writer-\(writer)", sequence: Int64(sequence),
                        kind: .output, data: Data([UInt8(writer), UInt8(sequence)])
                    )])
                    try store.setString("\(sequence)", forKey: "activity-\(writer)")
                } catch {
                    errors.record(error)
                }
            }
        }
        try expectEqual(errors.all, [], "parallel history and settings writes")
        for writer in 0..<8 {
            let events = try store.events(sessionId: "writer-\(writer)")
            try expectEqual(events.map(\.sequence), Array(0..<Int64(20)), "writer \(writer) keeps every event")
        }
    }
}

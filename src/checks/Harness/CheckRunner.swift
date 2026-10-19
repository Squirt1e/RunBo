import Foundation
import Core

/// Thrown by a check to report a failure with a human readable reason.
struct CheckFailure: Error, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { reason }
}

/// Thrown by a check that cannot run deterministically on this machine. It is reported as
/// `SKIP <name>: <reason>`, counted separately, and never affects the exit code: a skip is
/// neither a pass nor a failure, so the suite stays green instead of reporting a false PASS.
struct CheckSkip: Error, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { reason }
}

/// Marks the current check as skipped, with the printed reason.
func skipCheck(_ reason: String) throws -> Never {
    throw CheckSkip(reason)
}

/// Tiny registry: `register("name") { ... }`. A check fails by throwing.
private final class CheckRegistry {
    static let shared = CheckRegistry()
    private var entries: [(name: String, body: () throws -> Void)] = []
    private let lock = NSLock()

    func add(_ name: String, _ body: @escaping () throws -> Void) {
        lock.lock(); defer { lock.unlock() }
        entries.append((name, body))
    }

    func snapshot() -> [(name: String, body: () throws -> Void)] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}

func register(_ name: String, _ body: @escaping () throws -> Void) {
    CheckRegistry.shared.add(name, body)
}

// MARK: - Assertions

func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw CheckFailure(message()) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    if actual != expected {
        throw CheckFailure("\(label): expected \(expected), got \(actual)")
    }
}

func expectUnwrap<T>(_ value: T?, _ label: String) throws -> T {
    guard let value else { throw CheckFailure("\(label) was nil") }
    return value
}

/// `try` variant for tests that must not abort before reporting.
func expectThrows<T>(_ label: String, _ body: () throws -> T) throws -> Error {
    do {
        _ = try body()
    } catch {
        return error
    }
    throw CheckFailure("\(label): expected a thrown error but nothing was thrown")
}

// MARK: - Runner

private func describe(_ error: Error) -> String {
    let raw: String
    if let failure = error as? CheckFailure {
        raw = failure.reason
    } else if let launch = error as? ShellLaunchError {
        raw = launch.message
    } else {
        raw = "\(error)"
    }
    return raw
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
}

/// Runs every registered check (optionally filtered by a name substring) and prints exactly
/// one `PASS <name>` / `FAIL <name>: <reason>` / `SKIP <name>: <reason>` line per check plus
/// a summary. `SKIP` is reserved for checks that cannot be made deterministic on this
/// machine; it is not a pass and does not fail the run. Returns the process exit code.
func runChecks(filter: String?) -> Int32 {
    var passed = 0
    var failed = 0
    var skipped = 0
    for entry in CheckRegistry.shared.snapshot() {
        if let filter, !filter.isEmpty, !entry.name.contains(filter) { continue }
        do {
            try entry.body()
            print("PASS \(entry.name)")
            passed += 1
        } catch let skip as CheckSkip {
            print("SKIP \(entry.name): \(skip.reason)")
            skipped += 1
        } catch {
            print("FAIL \(entry.name): \(describe(error))")
            failed += 1
        }
        fflush(stdout)
    }
    // The required summary stays `N passed, M failed`; the skip count is appended only when
    // something actually skipped, so the common line is unchanged.
    if skipped == 0 {
        print("\(passed) passed, \(failed) failed")
    } else {
        print("\(passed) passed, \(failed) failed, \(skipped) skipped")
    }
    fflush(stdout)
    return failed == 0 ? 0 : 1
}

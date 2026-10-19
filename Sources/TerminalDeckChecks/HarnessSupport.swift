import Foundation
#if canImport(Darwin)
import Darwin
#endif
import TerminalDeckKit

// MARK: - Temp directories

enum TempSpace {
    /// Unique, per-check scratch directory under the system temp directory.
    static func make(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("runbo-checks-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func subdirectory(_ parent: URL, _ name: String) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func clean(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Waiting

/// Polls `predicate` (sleeping between polls) until it is true or `timeout` elapses.
/// Never loops forever.
@discardableResult
func waitFor(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        usleep(20_000)
    }
    return predicate()
}

/// Same as `waitFor`, but pumps the main run loop between polls so that
/// `SessionEngine`'s main-queue delegate callbacks can be delivered.
@discardableResult
func waitForMain(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return predicate()
}

/// Services the main run loop for a fixed duration.
func pumpMainRunLoop(_ duration: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(duration))
}

// MARK: - Formatting

/// Renders bytes for a failure message without wrecking the one-line output format.
func preview(_ bytes: [UInt8], limit: Int = 300) -> String {
    let text = String(decoding: bytes, as: UTF8.self)
        .replacingOccurrences(of: "\u{1B}", with: "<ESC>")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\u{07}", with: "<BEL>")
    return text.count <= limit ? text : String(text.prefix(limit)) + "…"
}

func preview(_ text: String, limit: Int = 300) -> String { preview(Array(text.utf8), limit: limit) }

// MARK: - Marker helpers

let tdMarkerPrefixBytes: [UInt8] = Array("\u{1B}]1337;TerminalDeck;".utf8)

func tdMarker(_ payload: String, stTerminated: Bool = false) -> [UInt8] {
    tdMarkerPrefixBytes + Array(payload.utf8) + (stTerminated ? [0x1B, 0x5C] : [0x07])
}

func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
        return true
    }
    return false
}

// MARK: - Session record comparison

/// Compares two session records field by field and returns the names of the fields that
/// differ. Dates are compared as *instants on the epoch clock* rather than with `Date ==`.
///
/// Why: `SessionRecord`'s synthesized `==` compares `Date` with `Date ==`, which compares
/// Foundation's internal reference-date (`timeIntervalSinceReferenceDate`) representation.
/// The store persists `timeIntervalSince1970` in a REAL column and rebuilds the Date with
/// `Date(timeIntervalSince1970:)`; that recomputation (`x - 978307200`) rounds differently
/// for ~44% of arbitrary `Date()` values, so two Dates denoting the exact same instant
/// (identical epoch bit patterns, delta 0.0) can compare unequal. Values whose fraction is
/// exactly representable (e.g. whole seconds) are unaffected, which is why the seeded-date
/// store checks can still use `==` directly.
func differingSessionFields(_ lhs: SessionRecord, _ rhs: SessionRecord) -> [String] {
    var differing: [String] = []
    if lhs.id != rhs.id { differing.append("id") }
    if lhs.kind != rhs.kind { differing.append("kind") }
    if lhs.ownerId != rhs.ownerId { differing.append("ownerId") }
    if lhs.title != rhs.title { differing.append("title") }
    if lhs.shell != rhs.shell { differing.append("shell") }
    if lhs.workingDirectory != rhs.workingDirectory { differing.append("workingDirectory") }
    if lhs.startedAt.timeIntervalSince1970.bitPattern != rhs.startedAt.timeIntervalSince1970.bitPattern {
        differing.append("startedAt")
    }
    if lhs.endedAt?.timeIntervalSince1970.bitPattern != rhs.endedAt?.timeIntervalSince1970.bitPattern {
        differing.append("endedAt")
    }
    if lhs.termination != rhs.termination { differing.append("termination") }
    if lhs.lastCommandExitStatus != rhs.lastCommandExitStatus { differing.append("lastCommandExitStatus") }
    if lhs.lastCommandFailed != rhs.lastCommandFailed { differing.append("lastCommandFailed") }
    if lhs.lastCommandStatusUnknown != rhs.lastCommandStatusUnknown { differing.append("lastCommandStatusUnknown") }
    if lhs.launchFailed != rhs.launchFailed { differing.append("launchFailed") }
    if lhs.unexpectedExit != rhs.unexpectedExit { differing.append("unexpectedExit") }
    if lhs.lastCommandText != rhs.lastCommandText { differing.append("lastCommandText") }
    return differing
}

// MARK: - Store construction

/// Creates a unique scratch directory and opens a store in it (the directory *is* the store
/// directory). Returns the store and the directory so the caller can clean up.
func makeStore(_ label: String) throws -> (TerminalDeckStore, URL) {
    let root = try TempSpace.make(label)
    return (try TerminalDeckStore(directory: root), root)
}

// MARK: - Store schema introspection (public `Database` API)

func storeSchemaVersion(_ store: TerminalDeckStore) throws -> Int64? {
    try store.database.query("SELECT version FROM schema_version LIMIT 1;") { $0.int(0) }.first
}

func storeTableNames(_ store: TerminalDeckStore) throws -> [String] {
    try store.database.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;") { $0.string(0) }
}

func storeColumns(_ store: TerminalDeckStore, table: String) throws -> [String] {
    try store.database.query("PRAGMA table_info(\(table));") { $0.string(1) }
}

/// Column order the Kit writes with (also the order `session(from:)` reads).
let expectedSessionColumns = [
    "id", "kind", "owner_id", "title", "shell", "working_directory", "started_at",
    "ended_at", "termination", "last_command_exit_status", "last_command_failed",
    "last_command_status_unknown", "launch_failed", "unexpected_exit", "last_command_text",
]

/// Asserts the `sessions` table has exactly the expected columns.
///
/// The *physical* order is deliberately not asserted: SQLite's `ALTER TABLE ... ADD COLUMN`
/// (the v2 migration) always appends, so a migrated table ends with
/// `last_command_status_unknown` while the INSERT/SELECT lists name their columns explicitly.
/// The read/write alignment is covered by the round-trip and migration checks instead.
func expectSessionColumns(_ store: TerminalDeckStore, _ label: String) throws {
    let columns = try storeColumns(store, table: "sessions")
    try expectEqual(columns.count, expectedSessionColumns.count, "\(label): sessions column count")
    try expectEqual(Set(columns), Set(expectedSessionColumns), "\(label): sessions column names")
    try expect(columns.contains("last_command_status_unknown"), "\(label): sessions must have last_command_status_unknown")
}

// MARK: - Disk write failure injection

/// Result of `injectStoreWriteFailure`: always call `restore()` (the checks do it in a
/// `defer`) so nothing is ever left read-only.
struct WriteFailureInjection {
    let restore: () -> Void
    /// Which mechanism actually blocked writes, for failure/skip messages.
    let mechanism: String
}

/// Makes every write to an open `store` fail, so the harness can prove that a history write
/// failure neither kills a session nor goes unreported.
///
/// The requested recipe is applied — `PRAGMA wal_checkpoint(TRUNCATE)` from a separate process
/// (`sqlite3`), delete the `-wal`/`-shm` sidecars, `chmod 500` the store directory — with one
/// measured addition that makes it deterministic for an *already open* connection:
///
///   0. leave WAL mode first (`PRAGMA journal_mode = DELETE`), while the directory is still
///      writable so the switch can checkpoint and remove the WAL cleanly;
///   1. checkpoint from a separate process and drop the sidecars (the requested recipe);
///   2. `chmod 500` the store directory.
///
/// Why step 0 is needed: with only the requested recipe, an already-open WAL connection keeps
/// writing through its live descriptors to the unlinked `-wal` inode, so writes still succeed
/// on this machine (measured with both `store.diskUsageBytes()` and the external `sqlite3`
/// checkpoint) — and when it *does* block, the connection is left with a dangling WAL that
/// cannot recover after the permissions are restored. Out of WAL mode, every write must create
/// a rollback journal in the read-only directory, which is a real filesystem failure
/// ("attempt to write a readonly database") and recovers cleanly.
///
/// If step 0 fails (e.g. the database is busy), nothing is injected: the caller's probe write
/// then still succeeds and the check reports a SKIP rather than a false PASS.
func injectStoreWriteFailure(_ store: TerminalDeckStore, directory: URL) throws -> WriteFailureInjection {
    let fileManager = FileManager.default

    // Step 0: leave WAL mode (retry briefly in case a background write holds the lock).
    var leftWALMode = false
    for attempt in 0..<5 {
        if (try? store.database.execute("PRAGMA journal_mode = DELETE;")) != nil {
            leftWALMode = true
            break
        }
        usleep(100_000 * UInt32(attempt + 1))
    }

    guard leftWALMode else {
        // Could not change the journal mode: inject nothing, the probe turns this into a SKIP.
        return WriteFailureInjection(restore: {}, mechanism: "none (could not leave WAL mode)")
    }

    // Steps 1-2: the requested recipe.
    _ = checkpointWithExternalSQLite(store.database.filePath)
    for suffix in ["-wal", "-shm"] {
        let sidecar = URL(fileURLWithPath: store.database.filePath + suffix)
        if fileManager.fileExists(atPath: sidecar.path) {
            try fileManager.removeItem(at: sidecar)
        }
    }
    try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

    return WriteFailureInjection(restore: {
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Rebuild a clean WAL now that the directory is writable again.
        try? store.database.execute("PRAGMA journal_mode = WAL;")
    }, mechanism: "read-only store directory; SQLite cannot create its journal (requested recipe, connection out of WAL mode)")
}

/// Runs `sqlite3 <db> "pragma wal_checkpoint(truncate);"` in a child process.
/// Returns false when the tool is missing or the checkpoint failed.
private func checkpointWithExternalSQLite(_ databasePath: String) -> Bool {
    let sqliteURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    guard FileManager.default.isExecutableFile(atPath: sqliteURL.path) else { return false }
    let process = Process()
    process.executableURL = sqliteURL
    process.arguments = [databasePath, "pragma wal_checkpoint(truncate);"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

/// True when the message looks like the read-only injection above (or a closely related
/// filesystem failure), as opposed to some unrelated problem. The injection surfaces as
/// either `SQLITE_READONLY` ("attempt to write a readonly database") or, when the WAL was
/// pulled out from under the open connection, `SQLITE_IOERR` ("disk I/O error"); both are
/// genuine write failures.
func looksLikeWriteFailure(_ message: String) -> Bool {
    let lowered = message.lowercased()
    return lowered.contains("readonly")
        || lowered.contains("read-only")
        || lowered.contains("unable to open")
        || lowered.contains("disk i/o error")
        || lowered.contains("i/o error")
}

func looksLikeWriteFailure(_ error: Error) -> Bool {
    looksLikeWriteFailure("\(error)")
}

// MARK: - PTY event log

/// Thread-safe sink for `PTYSession.Event`s. The PTY reader delivers events off the
/// main thread, so every access goes through the lock.
final class PTYEventLog {
    private let lock = NSLock()
    private var outputs: [UInt8] = []
    private var signals: [SessionSignal] = []
    private var launchFailure: String?
    private var exited = false
    private var exitStatus: Int32 = 0
    private var exitSignal: Int32?

    func record(_ event: PTYSession.Event) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .output(let bytes):
            outputs.append(contentsOf: bytes)
        case .signal(let signal):
            signals.append(signal)
        case .exited(let status, let signal, _):
            exited = true
            exitStatus = status
            exitSignal = signal
        case .launchFailed(let message):
            launchFailure = message
        }
    }

    var allOutput: [UInt8] { lock.lock(); defer { lock.unlock() }; return outputs }
    var outputText: String { String(decoding: allOutput, as: UTF8.self) }
    var allSignals: [SessionSignal] { lock.lock(); defer { lock.unlock() }; return signals }
    var hasExited: Bool { lock.lock(); defer { lock.unlock() }; return exited }
    var exitStatusCode: Int32 { lock.lock(); defer { lock.unlock() }; return exitStatus }
    var exitSignalNumber: Int32? { lock.lock(); defer { lock.unlock() }; return exitSignal }
    var launchFailureMessage: String? { lock.lock(); defer { lock.unlock() }; return launchFailure }

    var commandExitStatuses: [Int32?] {
        lock.lock(); defer { lock.unlock() }
        var statuses: [Int32?] = []
        for signal in signals {
            if case .commandFinished(let status) = signal { statuses.append(status) }
        }
        return statuses
    }

    func hasSignal(_ predicate: (SessionSignal) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return signals.contains(where: predicate)
    }
}

// MARK: - Standard hermetic environment

/// Minimal, fully hermetic shell environment: a scratch HOME, a predictable PATH.
/// Nothing is inherited from the developer's real environment.
func hermeticBaseEnvironment(home: URL, extra: [String: String] = [:]) -> [String: String] {
    var seed: [String: String] = [
        "HOME": home.path,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "USER": "tdchecks",
        "LOGNAME": "tdchecks",
        "LANG": "en_US.UTF-8",
    ]
    for (key, value) in extra { seed[key] = value }
    return ShellShims.baseEnvironment(now: seed)
}

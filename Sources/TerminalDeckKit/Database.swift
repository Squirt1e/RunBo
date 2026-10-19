import Foundation
import SQLite3

/// `sqlite3_bind_*` needs to know the buffer is copied, not borrowed.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let context: String

    public var description: String { "SQLite error \(code) during \(context): \(message)" }
}

/// Minimal SQLite wrapper: enough to run migrations, statements and row reads
/// without pulling a third party dependency into a local-only desktop app.
/// Thread safety: all access is serialised by `lock` (SQLITE_OPEN_FULLMUTEX).
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let path: String
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: result, message: message, context: "open \(path)")
        }
        self.handle = opened
        sqlite3_busy_timeout(opened, 5_000)
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA synchronous = NORMAL;")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private func requireHandle(_ context: String) throws -> OpaquePointer {
        guard let handle else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed", context: context)
        }
        return handle
    }

    /// Runs one or more statements, ignoring rows.
    public func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let handle = try requireHandle("execute")
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(error)
            throw SQLiteError(code: result, message: message, context: sql)
        }
    }

    /// Runs a statement with bound values.
    public func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, context: sql)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)), context: sql)
        }
    }

    /// Runs a query and maps every row.
    public func query<T>(_ sql: String, _ values: [SQLiteValue] = [], _ map: (Row) -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement, context: sql)
        var results: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                results.append(map(Row(statement: statement)))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)), context: sql)
            }
        }
        return results
    }

    /// Holds the connection lock from BEGIN through COMMIT/ROLLBACK. Locking only
    /// individual statements lets other queues start a nested transaction or have
    /// their writes silently committed/rolled back by this one.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public var lastInsertRowId: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    public func changes() -> Int32 {
        guard let handle else { return 0 }
        return sqlite3_changes(handle)
    }

    /// Flushes the WAL back into the main database file (used before reporting disk usage).
    public func checkpoint() {
        try? execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    public var filePath: String { path }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        let handle = try requireHandle("prepare")
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)), context: sql)
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?, context: String) throws {
        guard let statement else { return }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let number):
                result = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                result = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                result = sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            case .blob(let data):
                if data.isEmpty {
                    result = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    result = data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                    }
                }
            }
            guard result == SQLITE_OK else {
                throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)), context: context)
            }
        }
    }
}

public enum SQLiteValue {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public static func date(_ value: Date?) -> SQLiteValue {
        guard let value else { return .null }
        return .real(value.timeIntervalSince1970)
    }

    public static func optText(_ value: String?) -> SQLiteValue {
        guard let value else { return .null }
        return .text(value)
    }

    public static func optInt(_ value: Int32?) -> SQLiteValue {
        guard let value else { return .null }
        return .integer(Int64(value))
    }

    public static func bool(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }
}

/// One result row with typed accessors.
public struct Row {
    let statement: OpaquePointer?

    public func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    public func int32(_ index: Int32) -> Int32 { Int32(sqlite3_column_int64(statement, index)) }
    public func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    public func bool(_ index: Int32) -> Bool { sqlite3_column_int64(statement, index) != 0 }

    public func string(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    public func optionalString(_ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return string(index)
    }

    public func optionalInt32(_ index: Int32) -> Int32? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return int32(index)
    }

    public func optionalDate(_ index: Int32) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: double(index))
    }

    public func date(_ index: Int32) -> Date { Date(timeIntervalSince1970: double(index)) }

    public func data(_ index: Int32) -> Data {
        guard let blob = sqlite3_column_blob(statement, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return Data() }
        return Data(bytes: blob, count: count)
    }
}

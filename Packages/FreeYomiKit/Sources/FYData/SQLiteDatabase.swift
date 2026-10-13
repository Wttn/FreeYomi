import Foundation
import CSQLite
import FYCore

/// Valor de coluna SQLite.
public enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { public var sqlValue: SQLValue { .integer(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .integer(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .real(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .integer(self ? 1 : 0) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .real(timeIntervalSince1970) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// Linha de resultado com acesso por nome de coluna.
public struct SQLRow {
    let columns: [String: Int]
    let values: [SQLValue]

    public subscript(_ name: String) -> SQLValue {
        guard let i = columns[name] else { return .null }
        return values[i]
    }

    public func int64(_ name: String) -> Int64 {
        switch self[name] {
        case .integer(let v): return v
        case .real(let v): return Int64(v)
        case .text(let s): return Int64(s) ?? 0
        default: return 0
        }
    }

    public func int(_ name: String) -> Int { Int(int64(name)) }
    public func bool(_ name: String) -> Bool { int64(name) != 0 }

    public func optionalInt64(_ name: String) -> Int64? {
        if case .null = self[name] { return nil }
        return int64(name)
    }

    public func double(_ name: String) -> Double {
        switch self[name] {
        case .real(let v): return v
        case .integer(let v): return Double(v)
        case .text(let s): return Double(s) ?? 0
        default: return 0
        }
    }

    public func string(_ name: String) -> String { optionalString(name) ?? "" }

    public func optionalString(_ name: String) -> String? {
        switch self[name] {
        case .text(let s): return s
        case .integer(let v): return String(v)
        case .real(let v): return String(v)
        default: return nil
        }
    }

    public func date(_ name: String) -> Date { Date(timeIntervalSince1970: double(name)) }

    public func optionalDate(_ name: String) -> Date? {
        if case .null = self[name] { return nil }
        return date(name)
    }

    public func data(_ name: String) -> Data? {
        if case .blob(let d) = self[name] { return d }
        return nil
    }
}

private let SQLITE_TRANSIENT_PTR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Wrapper fino e thread-safe sobre a API C do SQLite.
///
/// Todas as operações são serializadas por um lock recursivo, o que permite
/// chamar `transaction {}` com consultas aninhadas.
public final class SQLiteDatabase: @unchecked Sendable {
    public let path: String
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    /// Abre (ou cria) o banco. Use `":memory:"` para um banco temporário.
    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "código \(rc)"
            sqlite3_close(db)
            throw FYError.database("não foi possível abrir o banco: \(message)")
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private var errorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "banco fechado"
    }

    /// Executa uma ou mais instruções sem parâmetros.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw FYError.database(message)
        }
    }

    private func prepare(_ sql: String, _ args: [SQLBindable]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw FYError.database("\(errorMessage) — SQL: \(sql)")
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch arg.sqlValue {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .integer(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let s): rc = sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_PTR)
            case .blob(let d):
                rc = d.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(d.count), SQLITE_TRANSIENT_PTR)
                }
            }
            if rc != SQLITE_OK {
                sqlite3_finalize(stmt)
                throw FYError.database("falha ao vincular parâmetro \(idx): \(errorMessage)")
            }
        }
        return stmt
    }

    /// Executa uma instrução parametrizada (INSERT/UPDATE/DELETE).
    @discardableResult
    public func run(_ sql: String, _ args: SQLBindable...) throws -> Int {
        try run(sql, arguments: args)
    }

    @discardableResult
    public func run(_ sql: String, arguments: [SQLBindable]) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, arguments)
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw FYError.database("\(errorMessage) — SQL: \(sql)") }
        return Int(sqlite3_changes(handle))
    }

    /// Executa uma consulta e retorna todas as linhas.
    public func query(_ sql: String, _ args: SQLBindable...) throws -> [SQLRow] {
        try query(sql, arguments: args)
    }

    public func query(_ sql: String, arguments: [SQLBindable]) throws -> [SQLRow] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, arguments)
        defer { sqlite3_finalize(stmt) }

        let count = Int(sqlite3_column_count(stmt))
        var columns: [String: Int] = [:]
        for i in 0..<count {
            columns[String(cString: sqlite3_column_name(stmt, Int32(i)))] = i
        }

        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw FYError.database("\(errorMessage) — SQL: \(sql)") }
            var values: [SQLValue] = []
            values.reserveCapacity(count)
            for i in 0..<Int32(count) {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: values.append(.integer(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i), n > 0 {
                        values.append(.blob(Data(bytes: p, count: n)))
                    } else {
                        values.append(.blob(Data()))
                    }
                default: values.append(.null)
                }
            }
            rows.append(SQLRow(columns: columns, values: values))
        }
        return rows
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Executa `body` em uma transação; desfaz tudo em caso de erro.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("SAVEPOINT fy_tx")
        do {
            let result = try body()
            try execute("RELEASE fy_tx")
            return result
        } catch {
            try? execute("ROLLBACK TO fy_tx")
            try? execute("RELEASE fy_tx")
            throw error
        }
    }

    /// `PRAGMA user_version`, usado pelo `Migrator`.
    public var userVersion: Int {
        get { (try? query("PRAGMA user_version").first?.int("user_version")) ?? 0 }
    }

    func setUserVersion(_ v: Int) throws { try execute("PRAGMA user_version = \(v)") }

    /// Verifica a integridade do arquivo. Retorna `true` se estiver íntegro.
    public func integrityCheck() -> Bool {
        guard let row = try? query("PRAGMA quick_check").first else { return false }
        return row.string("quick_check") == "ok"
    }
}

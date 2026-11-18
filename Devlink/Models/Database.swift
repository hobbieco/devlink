import Foundation
import SQLite3

/// macOS 내장 SQLite 를 쓰는 얇은 래퍼. 필요한 만큼만 (실행 · 준비문 · 값 넣기/읽기 · 트랜잭션).
nonisolated final class Database {
    enum Failure: Error { case sqlite(String) }

    private var handle: OpaquePointer?

    /// path 가 nil 이면 메모리 DB (테스트용)
    init(path: String?) throws {
        let p = path ?? ":memory:"
        guard sqlite3_open_v2(p, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw Failure.sqlite("open \(p): \(message)")
        }
        try exec("PRAGMA foreign_keys = ON")
        if path != nil { try exec("PRAGMA journal_mode = WAL") }
    }

    deinit { sqlite3_close_v2(handle) }

    private var message: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite("\(message) — \(sql)") }
    }

    /// 실패하면 되돌린다
    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    /// INSERT · UPDATE · DELETE
    func run(_ sql: String, _ values: [Value] = []) throws {
        let st = try Statement(self, sql, values)
        guard sqlite3_step(st.pointer) == SQLITE_DONE else { throw Failure.sqlite("\(message) — \(sql)") }
    }

    /// SELECT: 행마다 row 를 부른다
    func query(_ sql: String, _ values: [Value] = [], row: (Row) throws -> Void) throws {
        let st = try Statement(self, sql, values)
        while true {
            switch sqlite3_step(st.pointer) {
            case SQLITE_ROW: try row(Row(pointer: st.pointer))
            case SQLITE_DONE: return
            default: throw Failure.sqlite("\(message) — \(sql)")
            }
        }
    }

    enum Value {
        case text(String), int(Int), bool(Bool), null

        static func optional(_ s: String?) -> Value { s.map { .text($0) } ?? .null }
    }

    struct Row {
        let pointer: OpaquePointer?
        func text(_ i: Int32) -> String { sqlite3_column_text(pointer, i).map { String(cString: $0) } ?? "" }
        func optionalText(_ i: Int32) -> String? {
            sqlite3_column_type(pointer, i) == SQLITE_NULL ? nil : text(i)
        }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(pointer, i)) }
        func bool(_ i: Int32) -> Bool { sqlite3_column_int64(pointer, i) != 0 }
        func uuid(_ i: Int32) -> UUID { UUID(uuidString: text(i)) ?? UUID() }
    }

    private nonisolated final class Statement {
        var pointer: OpaquePointer?

        init(_ db: Database, _ sql: String, _ values: [Value]) throws {
            guard sqlite3_prepare_v2(db.handle, sql, -1, &pointer, nil) == SQLITE_OK else {
                throw Failure.sqlite("\(db.message) — \(sql)")
            }
            // SQLite 가 문자열을 복사하게 한다 (Swift 문자열 수명과 무관하게)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, v) in values.enumerated() {
                let idx = Int32(i + 1)
                switch v {
                case .text(let s): sqlite3_bind_text(pointer, idx, s, -1, transient)
                case .int(let n): sqlite3_bind_int64(pointer, idx, Int64(n))
                case .bool(let b): sqlite3_bind_int64(pointer, idx, b ? 1 : 0)
                case .null: sqlite3_bind_null(pointer, idx)
                }
            }
        }

        deinit { sqlite3_finalize(pointer) }
    }
}

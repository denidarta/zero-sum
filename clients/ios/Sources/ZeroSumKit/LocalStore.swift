import Foundation
import GRDB

/// Everything the app keeps on the device: entity state, the outbox of unsent ops,
/// the pull cursor and this device's id. Entities are stored as JSON, like the server does.
public final class LocalStore {
    public struct Contents {
        public var entities: [Entity] = []
        public var outbox: [Op] = []
        public var cursor: Int64 = 0
        public var deviceId: String?
    }

    private let queue: DatabaseQueue

    /// `path` of `nil` opens an in-memory database (tests).
    public init(path: String? = nil) throws {
        queue = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS entities (
                    kind TEXT NOT NULL, id TEXT NOT NULL, json TEXT NOT NULL,
                    PRIMARY KEY (kind, id));
                CREATE TABLE IF NOT EXISTS outbox (
                    op_id TEXT PRIMARY KEY, ts INTEGER NOT NULL, json TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                """)
        }
    }

    public func load() throws -> Contents {
        try queue.read { db -> Contents in
            let decoder = JSONDecoder()
            func decode<T: Decodable>(_ sql: String) throws -> [T] {
                try Row.fetchAll(db, sql: sql).map { row in
                    let json: String = row["json"]
                    return try decoder.decode(T.self, from: Data(json.utf8))
                }
            }
            var c = Contents()
            c.entities = try decode("SELECT json FROM entities")
            c.outbox = try decode("SELECT json FROM outbox ORDER BY ts, rowid")
            let cursor = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'cursor'")
            c.cursor = cursor.flatMap { Int64($0) } ?? 0
            c.deviceId = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'deviceId'")
            return c
        }
    }

    /// A local edit: the new entity state and the op to send, in one transaction.
    public func saveEdit(_ entity: Entity, _ op: Op) throws {
        try queue.write { db in
            try Self.put(db, entity)
            try db.execute(
                sql: "INSERT OR REPLACE INTO outbox (op_id, ts, json) VALUES (?, ?, ?)",
                arguments: [op.opId, op.ts, try Self.json(op)])
        }
    }

    /// One pulled page: entity states and the new cursor, in one transaction.
    public func savePull(_ entities: [Entity], cursor: Int64) throws {
        try queue.write { db in
            for e in entities { try Self.put(db, e) }
            try Self.setMeta(db, "cursor", String(cursor))
        }
    }

    public func removeOutbox(_ opIds: [String]) throws {
        try queue.write { db in
            for id in opIds { try db.execute(sql: "DELETE FROM outbox WHERE op_id = ?", arguments: [id]) }
        }
    }

    public func setDeviceId(_ id: String) throws {
        try queue.write { db in try Self.setMeta(db, "deviceId", id) }
    }

    private static func put(_ db: Database, _ e: Entity) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO entities (kind, id, json) VALUES (?, ?, ?)",
            arguments: [e.kind.rawValue, e.id, try json(e)])
    }

    private static func setMeta(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [key, value])
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

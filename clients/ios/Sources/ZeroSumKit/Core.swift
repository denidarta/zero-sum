import Foundation
import ZeroSumFFI

public struct CoreFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// The Rust core (crates/core) behind UniFFI. Merge and budget rules live only there,
/// so this app computes exactly what the server and the web client compute.
public enum Core {
    /// Merge `op` into `entity` (`nil` for a new entity). Throws when the op is invalid.
    public static func merge(_ entity: Entity?, _ op: Op) throws -> (state: Entity, changed: Bool) {
        struct Merged: Decodable {
            let state: Entity
            let changed: Bool
        }
        let entityJSON = try entity.map { try json($0) } ?? "null"
        let opJSON = try json(op)
        let out = try wrap { try mergeOp(entityJson: entityJSON, opJson: opJSON) }
        let m = try JSONDecoder().decode(Merged.self, from: Data(out.utf8))
        return (m.state, m.changed)
    }

    /// Derived budget for `YYYY-MM` over all entities. Deleted ones are ignored by the core.
    public static func budget(_ entities: [Entity], month: String) throws -> BudgetMonth {
        let input = try json(entities)
        let out = try wrap { try computeBudget(entitiesJson: input, month: month) }
        return try JSONDecoder().decode(BudgetMonth.self, from: Data(out.utf8))
    }

    /// Deterministic id of the budget entry for a category and month (UUIDv5).
    public static func entryId(category: String, month: String) throws -> String {
        try wrap { try budgetEntryId(categoryId: category, month: month) }
    }

    /// One entity write planned by the core: a field patch, or a tombstone when `deleted`.
    public struct Patch: Decodable, Sendable {
        public let kind: Kind
        public let id: String
        public let fields: [String: JSONValue]
        public let deleted: Bool
    }

    /// Ledger rules: turn an action (transfers, deleting categories, see `crates/core/src/ledger.rs`)
    /// into entity patches. Throws a `CoreFailure` with a message fit for the user when it is not allowed.
    public static func plan(_ entities: [Entity], command: [String: JSONValue]) throws -> [Patch] {
        let input = try json(entities), cmd = try json(command)
        let out = try wrap { try planLedger(entitiesJson: input, commandJson: cmd) }
        return try JSONDecoder().decode([Patch].self, from: Data(out.utf8))
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func wrap<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch CoreError.Invalid(let message) {
            throw CoreFailure(message: message)
        }
    }
}

import Foundation

// Wire types. They mirror crates/core (`model.rs`, `sync.rs`, `budget.rs`) and
// crates/server. Keys are spelled out because `convertFromSnakeCase` would also
// rewrite the keys inside entity `data`.

public enum Kind: String, Codable, CaseIterable, Sendable {
    case account
    case categoryGroup = "category_group"
    case category
    case payee
    case transaction
    case budgetEntry = "budget_entry"
}

public struct Stamp: Codable, Hashable, Sendable {
    public var ts: Int64
    public var op: String
}

public struct Entity: Codable, Hashable, Identifiable, Sendable {
    public var kind: Kind
    public var id: String
    public var data: [String: JSONValue]
    public var stamps: [String: Stamp]
    public var deleted: Bool

    public func string(_ key: String) -> String? { data[key]?.string }
    /// Milliunits for money fields, 0 when missing.
    public func int(_ key: String) -> Int64 { data[key]?.int ?? 0 }
    public func bool(_ key: String, default value: Bool = false) -> Bool { data[key]?.bool ?? value }
    public var name: String { string("name") ?? "" }
}

public struct Op: Codable, Hashable, Sendable {
    public var opId: String
    public var ts: Int64
    public var kind: Kind
    public var entityId: String
    public var fields: [String: JSONValue]
    public var deleted: Bool?

    enum CodingKeys: String, CodingKey {
        case opId = "op_id", ts, kind, entityId = "entity_id", fields, deleted
    }
}

/// An entity as the server sends it in a pull: state plus the sequence of its last change.
public struct Change: Decodable {
    public let seq: Int64
    public let entity: Entity

    enum CodingKeys: String, CodingKey { case seq }

    public init(from decoder: Decoder) throws {
        seq = try decoder.container(keyedBy: CodingKeys.self).decode(Int64.self, forKey: .seq)
        entity = try Entity(from: decoder)
    }
}

public struct OpResult: Codable {
    public let opId: String
    /// `applied`, `stale`, `duplicate` or `rejected`. All are final.
    public let status: String
    public let reason: String?

    enum CodingKeys: String, CodingKey { case opId = "op_id", status, reason }
}

public struct PushOutcome: Decodable {
    public let results: [OpResult]
    public let cursor: Int64
}

public struct PullPage: Decodable {
    public let changes: [Change]
    public let cursor: Int64
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey { case changes, cursor, hasMore = "has_more" }
}

public struct CategoryMonth: Codable, Hashable {
    public let categoryId: String
    public let assigned: Int64
    public let activity: Int64
    public let available: Int64

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id", assigned, activity, available
    }
}

public struct BudgetMonth: Codable, Hashable {
    public let month: String
    public let readyToAssign: Int64
    public let categories: [CategoryMonth]
    /// Live categories whose group is missing or deleted. The core decides, clients only show them.
    public let orphanedCategoryIds: [String]

    enum CodingKeys: String, CodingKey {
        case month, readyToAssign = "ready_to_assign", categories
        case orphanedCategoryIds = "orphaned_category_ids"
    }

    public init(month: String, readyToAssign: Int64, categories: [CategoryMonth], orphanedCategoryIds: [String] = []) {
        self.month = month
        self.readyToAssign = readyToAssign
        self.categories = categories
        self.orphanedCategoryIds = orphanedCategoryIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        readyToAssign = try c.decode(Int64.self, forKey: .readyToAssign)
        categories = try c.decode([CategoryMonth].self, forKey: .categories)
        orphanedCategoryIds = try c.decodeIfPresent([String].self, forKey: .orphanedCategoryIds) ?? []
    }

    public static func empty(_ month: String) -> BudgetMonth {
        BudgetMonth(month: month, readyToAssign: 0, categories: [])
    }
}

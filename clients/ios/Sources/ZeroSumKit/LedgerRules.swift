import Foundation

// Ledger helpers for the UI. The rules (transfer pairs, splits, deleting categories) live in
// the Rust core: `execute` asks it for patches and writes them. Spec: docs/ledger-edits-spec.md.

/// One category line of a split transaction.
public struct SplitLine: Hashable, Sendable {
    public var categoryId: String
    /// Milliunits, same sign as the transaction amount.
    public var amount: Int64
    public var memo: String?

    public init(categoryId: String, amount: Int64, memo: String? = nil) {
        self.categoryId = categoryId
        self.amount = amount
        self.memo = memo
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["category_id": .string(categoryId), "amount": .int(amount)]
        if let memo { o["memo"] = .string(memo) }
        return .object(o)
    }
}

extension Entity {
    /// Split lines of a transaction, empty when it is not split.
    public var splits: [SplitLine] {
        guard case .array(let lines)? = data["splits"] else { return [] }
        return lines.compactMap { v in
            guard case .object(let o) = v, let c = o["category_id"]?.string, let a = o["amount"]?.int else { return nil }
            return SplitLine(categoryId: c, amount: a, memo: o["memo"]?.string)
        }
    }

    public var isTransfer: Bool { string("transfer_account_id") != nil }
}

extension Ledger {
    /// The other leg of a transfer, if it still exists.
    public func partner(of t: Entity) -> Entity? {
        t.string("transfer_transaction_id").flatMap { get(.transaction, $0) }
    }

    /// A transfer leg whose partner is gone, for example after a concurrent delete.
    public func isUnmatched(_ t: Entity) -> Bool { t.isTransfer && partner(of: t) == nil }

    private func onBudget(_ account: String) -> Bool { get(.account, account)?.bool("on_budget", default: true) ?? false }

    /// Whether the form shows a category picker. The core enforces D5 when the transfer is saved.
    public func transferNeedsCategory(from: String, to: String) -> Bool { onBudget(from) && !onBudget(to) }

    /// Plan an action in the core, then write each patch. Throws the core's message when not allowed.
    private func execute(_ command: [String: JSONValue]) throws {
        for p in try Core.plan(Array(entities.values), command: command) {
            if p.deleted { try remove(p.kind, p.id) } else { try edit(p.kind, p.id, p.fields) }
        }
    }

    private static func optional(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }

    /// D4: a transfer is two linked transactions. `amount` is a positive magnitude.
    public func addTransfer(
        date: String, from: String, to: String, amount: Int64, memo: String?, cleared: Bool, categoryId: String?
    ) throws {
        try execute([
            "command": "add_transfer", "ids": .array([.string(Ledger.newID()), .string(Ledger.newID())]),
            "date": .string(date), "from": .string(from), "to": .string(to), "amount": .int(amount),
            "memo": Self.optional(memo), "cleared": .bool(cleared), "category_id": Self.optional(categoryId),
        ])
    }

    /// D8: every edit to one leg is written to both legs, amount sign flipped.
    public func editTransfer(
        _ t: Entity, date: String, amount: Int64, memo: String?, cleared: Bool, categoryId: String?
    ) throws {
        try execute([
            "command": "edit_transfer", "id": .string(t.id), "date": .string(date), "amount": .int(amount),
            "memo": Self.optional(memo), "cleared": .bool(cleared), "category_id": Self.optional(categoryId),
        ])
    }

    /// Edit a regular transaction. D10: never converts to or from a transfer.
    /// Sends only the fields that changed, so edits made elsewhere to other fields survive the merge.
    public func updateTransaction(_ t: Entity, fields: [String: JSONValue], splits: [SplitLine]) throws {
        var changed = fields.filter { (t.data[$0.key] ?? .null) != $0.value }
        if splits != t.splits { changed["splits"] = .array(splits.map(\.json)) }
        if !changed.isEmpty { try edit(.transaction, t.id, changed) }
    }

    /// Delete a transaction. A transfer takes its other leg with it.
    public func removeTransaction(_ t: Entity) throws {
        try execute(["command": "remove_transaction", "id": .string(t.id)])
    }

    /// Live transactions that use a category, directly or in a split line.
    public func transactions(in categoryId: String) -> [Entity] {
        list(.transaction).filter {
            $0.string("category_id") == categoryId || $0.splits.contains { $0.categoryId == categoryId }
        }
    }

    public func categories(in groupId: String) -> [Entity] {
        list(.category).filter { $0.string("group_id") == groupId }
    }

    /// Remove a category. Its budget entries go with it, so the money returns to Ready to Assign.
    public func deleteEmptyCategory(_ id: String) throws {
        try execute(["command": "delete_empty_category", "category_id": .string(id)])
    }

    /// D3, move: re-point every transaction at `target`, then delete the category.
    public func moveTransactions(from id: String, to target: String) throws {
        try execute(["command": "move_category_transactions", "category_id": .string(id), "target": .string(target)])
    }

    /// D3, delete: remove the category's transactions, then the category.
    public func deleteTransactions(in id: String) throws {
        try execute(["command": "delete_category_transactions", "category_id": .string(id)])
    }
}

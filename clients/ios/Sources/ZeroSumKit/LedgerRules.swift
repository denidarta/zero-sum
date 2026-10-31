import Foundation

// Ledger rules shared by the UI: transfer pairs, splits, deleting categories.
// Spec: docs/ledger-edits-spec.md. Same rules as clients/web/src/ledger.ts.
// Budget math itself stays in the Rust core.

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

    /// D5: money leaving the budget for a tracking account must come from a category.
    public func transferNeedsCategory(from: String, to: String) -> Bool { onBudget(from) && !onBudget(to) }

    /// D4: a transfer is two linked transactions. `amount` is a positive magnitude.
    public func addTransfer(
        date: String, from: String, to: String, amount: Int64, memo: String?, cleared: Bool, categoryId: String?
    ) throws {
        let (a, b) = (Ledger.newID(), Ledger.newID())
        let common: [String: JSONValue] = [
            "date": .string(date), "memo": memo.map(JSONValue.string) ?? .null, "cleared": .bool(cleared),
            "category_id": categoryId.map(JSONValue.string) ?? .null,
        ]
        try edit(.transaction, a, common.merging([
            "account_id": .string(from), "amount": .int(-amount),
            "transfer_account_id": .string(to), "transfer_transaction_id": .string(b),
        ]) { $1 })
        try edit(.transaction, b, common.merging([
            "account_id": .string(to), "amount": .int(amount),
            "transfer_account_id": .string(from), "transfer_transaction_id": .string(a),
        ]) { $1 })
    }

    /// D8: every edit to one leg is written to both legs, amount sign flipped.
    public func editTransfer(
        _ t: Entity, date: String, amount: Int64, memo: String?, cleared: Bool, categoryId: String?
    ) throws {
        let sign: Int64 = t.int("amount") < 0 ? -1 : 1
        let common: [String: JSONValue] = [
            "date": .string(date), "memo": memo.map(JSONValue.string) ?? .null, "cleared": .bool(cleared),
            "category_id": categoryId.map(JSONValue.string) ?? .null,
        ]
        try edit(.transaction, t.id, common.merging(["amount": .int(sign * amount)]) { $1 })
        if let p = partner(of: t) {
            try edit(.transaction, p.id, common.merging(["amount": .int(-sign * amount)]) { $1 })
        }
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
        let p = partner(of: t)
        try remove(.transaction, t.id)
        if let p { try remove(.transaction, p.id) }
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
        for e in list(.budgetEntry) where e.string("category_id") == id { try remove(.budgetEntry, e.id) }
        try remove(.category, id)
    }

    /// D3, move: re-point every transaction at `target`, then delete the category.
    public func moveTransactions(from id: String, to target: String) throws {
        for t in transactions(in: id) {
            if t.splits.isEmpty {
                try edit(.transaction, t.id, ["category_id": .string(target)])
            } else {
                let lines = t.splits.map { $0.categoryId == id ? SplitLine(categoryId: target, amount: $0.amount, memo: $0.memo) : $0 }
                try edit(.transaction, t.id, ["splits": .array(lines.map(\.json))])
            }
        }
        try deleteEmptyCategory(id)
    }

    /// D3, delete: remove the category's transactions, then the category.
    public func deleteTransactions(in id: String) throws {
        for t in transactions(in: id) {
            let lines = t.splits
            if lines.isEmpty {
                try removeTransaction(t)
                continue
            }
            // Only the lines in this category go. The rest of the split stays.
            let keep = lines.filter { $0.categoryId != id }
            if keep.isEmpty {
                try remove(.transaction, t.id)
            } else {
                try edit(.transaction, t.id, [
                    "splits": .array(keep.map(\.json)), "amount": .int(keep.reduce(0) { $0 + $1.amount }),
                ])
            }
        }
        try deleteEmptyCategory(id)
    }
}

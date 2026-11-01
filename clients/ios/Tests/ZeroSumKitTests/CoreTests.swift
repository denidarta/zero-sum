import XCTest

@testable import ZeroSumKit

/// These call the real Rust core through the XCFramework, so they also prove the link works.
final class CoreTests: XCTestCase {
    func testEntryIdMatchesRust() throws {
        // Value printed by crates/ffi-uniffi for this input.
        XCTAssertEqual(
            try Core.entryId(category: "00000000-0000-4000-8000-000000000010", month: "2026-10"),
            "3b26c421-45da-5711-b215-51cbcf452c0f")
        XCTAssertThrowsError(try Core.entryId(category: "nope", month: "2026-10"))
    }

    func testMergeIsLastWriterWinsPerField() throws {
        let id = Ledger.newID()
        let created = try Core.merge(nil, op(.payee, id, ["name": "Shop"], ts: 10))
        XCTAssertTrue(created.changed)
        let newer = try Core.merge(created.state, op(.payee, id, ["name": "Cafe"], ts: 20))
        XCTAssertEqual(newer.state.string("name"), "Cafe")
        let older = try Core.merge(newer.state, op(.payee, id, ["name": "Old"], ts: 5))
        XCTAssertFalse(older.changed)
        XCTAssertEqual(older.state.string("name"), "Cafe")
    }

    func testInvalidOpThrows() {
        XCTAssertThrowsError(try Core.merge(nil, op(.payee, Ledger.newID(), ["nmae": "x"], ts: 1)))
    }

    func testBudgetMath() throws {
        let acct = Ledger.newID(), group = Ledger.newID(), cat = Ledger.newID()
        let month = "2026-10"
        let entry = try Core.entryId(category: cat, month: month)
        var entities: [Entity] = []
        func add(_ kind: Kind, _ id: String, _ fields: [String: JSONValue]) throws {
            entities.append(try Core.merge(nil, op(kind, id, fields, ts: 1)).state)
        }
        try add(.account, acct, ["name": "Checking", "kind": "checking", "on_budget": true])
        try add(.categoryGroup, group, ["name": "Bills"])
        try add(.category, cat, ["group_id": .string(group), "name": "Rent"])
        try add(.transaction, Ledger.newID(), ["account_id": .string(acct), "date": "2026-10-01", "amount": 3_000_000])
        try add(.transaction, Ledger.newID(), [
            "account_id": .string(acct), "date": "2026-10-05", "amount": -400_000, "category_id": .string(cat),
        ])
        try add(.budgetEntry, entry, ["category_id": .string(cat), "month": "2026-10", "assigned": 1_000_000])

        let b = try Core.budget(entities, month: month)
        XCTAssertEqual(b.readyToAssign, 2_000_000)
        let row = try XCTUnwrap(b.categories.first { $0.categoryId == cat })
        XCTAssertEqual(row.assigned, 1_000_000)
        XCTAssertEqual(row.activity, -400_000)
        XCTAssertEqual(row.available, 600_000)
        XCTAssertTrue(b.orphanedCategoryIds.isEmpty)
    }
}

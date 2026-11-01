import XCTest

@testable import ZeroSumKit

/// Spec: docs/ledger-edits-spec.md. Budget numbers come from the real Rust core.
@MainActor
final class LedgerRulesTests: XCTestCase {
    private let month = "2026-10"
    private var ledger: Ledger!
    private var checking = "", savings = "", tracking = "", group = "", rent = "", food = ""

    override func setUpWithError() throws {
        ledger = try Ledger(store: LocalStore(), defaults: defaults(server: nil))
        (checking, savings, tracking, group, rent, food) = (
            Ledger.newID(), Ledger.newID(), Ledger.newID(), Ledger.newID(), Ledger.newID(), Ledger.newID()
        )
        for (id, name, on) in [(checking, "Checking", true), (savings, "Savings", true), (tracking, "House", false)] {
            try ledger.edit(.account, id, ["name": .string(name), "kind": "checking", "on_budget": .bool(on)])
        }
        try ledger.edit(.categoryGroup, group, ["name": "Bills"])
        try ledger.edit(.category, rent, ["group_id": .string(group), "name": "Rent"])
        try ledger.edit(.category, food, ["group_id": .string(group), "name": "Food"])
        try ledger.edit(.transaction, Ledger.newID(), ["account_id": .string(checking), "date": "2026-10-01", "amount": 3_000_000])
    }

    private func assign(_ category: String, _ amount: Int64) throws {
        try ledger.edit(.budgetEntry, ledger.entryId(category: category, month: month), [
            "category_id": .string(category), "month": .string(month), "assigned": .int(amount),
        ])
    }

    private func spend(_ category: String, _ amount: Int64) throws -> String {
        let id = Ledger.newID()
        try ledger.edit(.transaction, id, [
            "account_id": .string(checking), "date": "2026-10-05", "amount": .int(-amount), "category_id": .string(category),
        ])
        return id
    }

    private func row(_ category: String) -> CategoryMonth? {
        ledger.budget(month: month).categories.first { $0.categoryId == category }
    }

    private func legs() -> [Entity] { ledger.list(.transaction).filter(\.isTransfer) }

    // MARK: Transfers

    func testTransferCreatesLinkedPairAndOnBudgetTransferIsNeutral() throws {
        try ledger.addTransfer(date: "2026-10-02", from: checking, to: savings, amount: 500_000, memo: nil, cleared: false, categoryId: nil)
        let out = try XCTUnwrap(legs().first { $0.string("account_id") == checking })
        let inn = try XCTUnwrap(legs().first { $0.string("account_id") == savings })
        XCTAssertEqual(out.int("amount"), -500_000)
        XCTAssertEqual(inn.int("amount"), 500_000)
        XCTAssertEqual(ledger.partner(of: out)?.id, inn.id)
        XCTAssertEqual(ledger.partner(of: inn)?.id, out.id)
        XCTAssertEqual(ledger.budget(month: month).readyToAssign, 3_000_000)
        XCTAssertEqual(ledger.balances()[checking], 2_500_000)
        XCTAssertEqual(ledger.balances()[savings], 500_000)
    }

    func testTransferToTrackingAccountCountsAsSpendingInItsCategory() throws {
        XCTAssertTrue(ledger.transferNeedsCategory(from: checking, to: tracking))
        XCTAssertFalse(ledger.transferNeedsCategory(from: tracking, to: checking))
        XCTAssertFalse(ledger.transferNeedsCategory(from: checking, to: savings))
        try ledger.addTransfer(date: "2026-10-02", from: checking, to: tracking, amount: 200_000, memo: nil, cleared: false, categoryId: rent)
        XCTAssertEqual(row(rent)?.activity, -200_000)
    }

    func testEditingOneLegMirrorsTheOtherWithFlippedSign() throws {
        try ledger.addTransfer(date: "2026-10-02", from: checking, to: savings, amount: 500_000, memo: nil, cleared: false, categoryId: nil)
        let inn = try XCTUnwrap(legs().first { $0.string("account_id") == savings })
        try ledger.editTransfer(inn, date: "2026-10-09", amount: 700_000, memo: "move", cleared: true, categoryId: nil)
        let out = try XCTUnwrap(legs().first { $0.string("account_id") == checking })
        XCTAssertEqual(out.int("amount"), -700_000)
        XCTAssertEqual(out.string("date"), "2026-10-09")
        XCTAssertEqual(out.string("memo"), "move")
        XCTAssertTrue(out.bool("cleared"))
        XCTAssertEqual(try XCTUnwrap(ledger.get(.transaction, inn.id)).int("amount"), 700_000)
    }

    func testDeletingOneLegDeletesBoth() throws {
        try ledger.addTransfer(date: "2026-10-02", from: checking, to: savings, amount: 500_000, memo: nil, cleared: false, categoryId: nil)
        try ledger.removeTransaction(try XCTUnwrap(legs().first))
        XCTAssertTrue(legs().isEmpty)
    }

    func testSurvivingLegIsUnmatched() throws {
        try ledger.addTransfer(date: "2026-10-02", from: checking, to: savings, amount: 500_000, memo: nil, cleared: false, categoryId: nil)
        let (a, b) = (legs()[0], legs()[1])
        XCTAssertFalse(ledger.isUnmatched(a))
        try ledger.remove(.transaction, b.id)
        XCTAssertTrue(ledger.isUnmatched(try XCTUnwrap(ledger.get(.transaction, a.id))))
    }

    // MARK: Splits and edits

    func testSplitLinesHitTheirCategories() throws {
        let id = Ledger.newID()
        try ledger.edit(.transaction, id, [
            "account_id": .string(checking), "date": "2026-10-05", "amount": -300_000,
            "splits": .array([
                SplitLine(categoryId: rent, amount: -100_000).json, SplitLine(categoryId: food, amount: -200_000).json,
            ]),
        ])
        XCTAssertEqual(row(rent)?.activity, -100_000)
        XCTAssertEqual(row(food)?.activity, -200_000)
    }

    func testUpdateSendsOnlyChangedFieldsAndRejectsBadSplitSum() throws {
        let id = try spend(food, 100_000)
        var t = try XCTUnwrap(ledger.get(.transaction, id))
        let before = ledger.outbox.count
        try ledger.updateTransaction(t, fields: ["memo": "lunch", "date": "2026-10-05"], splits: [])
        XCTAssertEqual(ledger.outbox.count, before + 1)
        XCTAssertEqual(Set(ledger.outbox.last!.fields.keys), ["memo"])

        t = try XCTUnwrap(ledger.get(.transaction, id))
        try ledger.updateTransaction(t, fields: ["memo": "lunch"], splits: [])  // nothing changed
        XCTAssertEqual(ledger.outbox.count, before + 1)

        XCTAssertThrowsError(try ledger.updateTransaction(
            t, fields: ["category_id": .null],
            splits: [SplitLine(categoryId: rent, amount: -40_000), SplitLine(categoryId: food, amount: -40_000)]))
        XCTAssertEqual(ledger.outbox.count, before + 1)
    }

    func testSplitThenUnsplitInOneEdit() throws {
        let id = try spend(food, 100_000)
        var t = try XCTUnwrap(ledger.get(.transaction, id))
        try ledger.updateTransaction(
            t, fields: ["category_id": .null],
            splits: [SplitLine(categoryId: rent, amount: -60_000), SplitLine(categoryId: food, amount: -40_000)])
        t = try XCTUnwrap(ledger.get(.transaction, id))
        XCTAssertEqual(t.splits.count, 2)
        XCTAssertEqual(row(rent)?.activity, -60_000)
        try ledger.updateTransaction(t, fields: ["category_id": .string(food)], splits: [])
        XCTAssertTrue(try XCTUnwrap(ledger.get(.transaction, id)).splits.isEmpty)
        XCTAssertEqual(row(food)?.activity, -100_000)
    }

    // MARK: Groups and categories

    func testCategoryWithDeletedGroupIsOrphaned() throws {
        XCTAssertTrue(ledger.budget(month: month).orphanedCategoryIds.isEmpty)
        try ledger.remove(.categoryGroup, group)
        XCTAssertEqual(Set(ledger.budget(month: month).orphanedCategoryIds), [rent, food])
        // Moving a category to a live group clears it.
        let other = Ledger.newID()
        try ledger.edit(.categoryGroup, other, ["name": "Fun"])
        try ledger.edit(.category, rent, ["group_id": .string(other)])
        XCTAssertEqual(ledger.budget(month: month).orphanedCategoryIds, [food])
        XCTAssertEqual(ledger.categories(in: other).map(\.id), [rent])
    }

    func testMovingTransactionsKeepsActivityAndFreesAssignedMoney() throws {
        try assign(food, 400_000)
        _ = try spend(food, 100_000)
        XCTAssertEqual(ledger.budget(month: month).readyToAssign, 2_600_000)
        try ledger.moveTransactions(from: food, to: rent)
        XCTAssertNil(ledger.get(.category, food))
        XCTAssertEqual(row(rent)?.activity, -100_000)
        XCTAssertEqual(ledger.budget(month: month).readyToAssign, 3_000_000)
    }

    func testDeletingTransactionsFreesAssignedMoney() throws {
        try assign(food, 400_000)
        let id = try spend(food, 100_000)
        try ledger.deleteTransactions(in: food)
        XCTAssertNil(ledger.get(.category, food))
        XCTAssertNil(ledger.get(.transaction, id))
        XCTAssertEqual(ledger.budget(month: month).readyToAssign, 3_000_000)
    }

    func testDeletingCategoryTrimsItsSplitLinesOnly() throws {
        let id = Ledger.newID()
        try ledger.edit(.transaction, id, [
            "account_id": .string(checking), "date": "2026-10-05", "amount": -300_000,
            "splits": .array([
                SplitLine(categoryId: rent, amount: -100_000).json, SplitLine(categoryId: food, amount: -200_000).json,
            ]),
        ])
        XCTAssertEqual(ledger.transactions(in: food).map(\.id), [id])
        try ledger.deleteTransactions(in: food)
        let t = try XCTUnwrap(ledger.get(.transaction, id))
        XCTAssertEqual(t.int("amount"), -100_000)
        XCTAssertEqual(t.splits.map(\.categoryId), [rent])
    }

    func testMovingTransactionsRepointsSplitLines() throws {
        let id = Ledger.newID()
        try ledger.edit(.transaction, id, [
            "account_id": .string(checking), "date": "2026-10-05", "amount": -300_000,
            "splits": .array([
                SplitLine(categoryId: rent, amount: -100_000).json, SplitLine(categoryId: food, amount: -200_000).json,
            ]),
        ])
        try ledger.moveTransactions(from: food, to: rent)
        XCTAssertEqual(try XCTUnwrap(ledger.get(.transaction, id)).splits.map(\.categoryId), [rent, rent])
    }
}

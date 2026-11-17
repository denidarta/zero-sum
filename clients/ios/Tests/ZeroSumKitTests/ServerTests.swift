import XCTest

@testable import ZeroSumKit

/// End to end against a real server, like clients/web/e2e/smoke.mjs. Skipped unless
/// `ZERO_SUM_TEST_SERVER` is set. Run `scripts/with-server.sh swift test`: it starts a throwaway server.
/// These tests write data, so never point the variable at a real server.
@MainActor
final class ServerTests: XCTestCase {
    private func serverURL() throws -> String {
        guard let url = ProcessInfo.processInfo.environment["ZERO_SUM_TEST_SERVER"] else {
            throw XCTSkip("set ZERO_SUM_TEST_SERVER to run")
        }
        return url
    }

    private func device(_ url: String) throws -> Ledger {
        try Ledger(store: LocalStore(), defaults: defaults(server: url))
    }

    func testTwoDevicesConverge() async throws {
        let url = try serverURL()
        let a = try device(url)
        let b = try device(url)
        let month = Money.thisMonth()
        let acct = Ledger.newID()
        let group = Ledger.newID()
        let cat = Ledger.newID()
        let tx = Ledger.newID()

        // A builds a budget and syncs.
        try a.edit(.account, acct, ["name": "Checking", "kind": "checking"])
        try a.edit(.categoryGroup, group, ["name": "Bills"])
        try a.edit(.category, cat, ["group_id": .string(group), "name": "Rent"])
        try a.edit(
            .transaction, tx,
            [
                "account_id": .string(acct), "date": .string(Money.dateString()), "amount": 3_000_000,
            ])
        try a.edit(
            .budgetEntry, a.entryId(category: cat, month: month),
            [
                "category_id": .string(cat), "month": .string(month), "assigned": 1_000_000,
            ])
        await a.sync()
        XCTAssertEqual(a.state, .idle)
        XCTAssertTrue(a.outbox.isEmpty)

        // B pulls the same state and computes the same budget with the same core.
        await b.sync()
        XCTAssertEqual(b.list(.category).map(\.name).filter { $0 == "Rent" }.count, 1)
        XCTAssertEqual(b.budget(month: month), a.budget(month: month))

        // Both edit different fields of one transaction, then sync both ways.
        try a.edit(.transaction, tx, ["memo": "from A"])
        try b.edit(.transaction, tx, ["amount": 2_500_000])
        await a.sync()
        await b.sync()
        await a.sync()
        let ea = try XCTUnwrap(a.entities["transaction:\(tx)"])
        let eb = try XCTUnwrap(b.entities["transaction:\(tx)"])
        XCTAssertEqual(ea, eb)
        XCTAssertEqual(ea.string("memo"), "from A")
        XCTAssertEqual(ea.int("amount"), 2_500_000)
        XCTAssertEqual(b.budget(month: month), a.budget(month: month))
    }

    func testOfflineEditsFlushWhenServerIsReachable() async throws {
        let url = try serverURL()
        let store = try LocalStore()
        let d = defaults(server: url)
        let offline = try Ledger(store: store, defaults: d, transport: { _ in Down() })
        let id = Ledger.newID()
        try offline.edit(.payee, id, ["name": "Offline payee"])
        await offline.sync()
        XCTAssertEqual(offline.state, .offline)

        let online = try Ledger(store: store, defaults: d)  // same device database, real transport
        XCTAssertEqual(online.outbox.count, 1)
        await online.sync()
        XCTAssertTrue(online.outbox.isEmpty)

        let other = try device(url)
        await other.sync()
        XCTAssertEqual(other.entities["payee:\(id)"]?.name, "Offline payee")
    }
}

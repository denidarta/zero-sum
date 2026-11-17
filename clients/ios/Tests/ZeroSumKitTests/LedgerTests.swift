import XCTest

@testable import ZeroSumKit

@MainActor
final class LedgerTests: XCTestCase {
    func testOfflineEditIsQueuedAndSurvivesRestart() async throws {
        let path = tempDBPath()
        let ledger = try Ledger(
            store: LocalStore(path: path), defaults: defaults(server: "http://localhost:1"), transport: { _ in Down() })
        let id = Ledger.newID()
        try ledger.edit(.account, id, ["name": "Cash", "kind": "cash"])
        await ledger.sync()
        XCTAssertEqual(ledger.state, .offline)
        XCTAssertEqual(ledger.outbox.count, 1)
        XCTAssertEqual(ledger.entities["account:\(id)"]?.name, "Cash")

        let reopened = try Ledger(
            store: LocalStore(path: path), defaults: defaults(server: nil), transport: { _ in Down() })
        XCTAssertEqual(reopened.outbox.count, 1)
        XCTAssertEqual(reopened.list(.account).map(\.name), ["Cash"])
        XCTAssertEqual(reopened.deviceId, ledger.deviceId)
        XCTAssertEqual(reopened.state, .unconfigured)
    }

    func testInvalidEditQueuesNothing() throws {
        let ledger = try Ledger(store: LocalStore(), defaults: defaults(server: nil))
        XCTAssertThrowsError(try ledger.edit(.payee, Ledger.newID(), ["nmae": "x"]))
        XCTAssertTrue(ledger.outbox.isEmpty)
        XCTAssertTrue(ledger.entities.isEmpty)
    }

    func testRemoveHidesEntity() throws {
        let ledger = try Ledger(store: LocalStore(), defaults: defaults(server: nil))
        let id = Ledger.newID()
        try ledger.edit(.payee, id, ["name": "Shop"])
        XCTAssertEqual(ledger.list(.payee).count, 1)
        try ledger.remove(.payee, id)
        XCTAssertEqual(ledger.list(.payee).count, 0)
    }

    func testBudgetUsesCore() throws {
        let ledger = try Ledger(store: LocalStore(), defaults: defaults(server: nil))
        let acct = Ledger.newID()
        try ledger.edit(.account, acct, ["name": "Checking", "kind": "checking"])
        try ledger.edit(
            .transaction, Ledger.newID(), ["account_id": .string(acct), "date": "2026-10-01", "amount": 5_000])
        XCTAssertEqual(ledger.budget(month: "2026-10").readyToAssign, 5_000)
        XCTAssertEqual(ledger.balances()[acct], 5_000)
    }
}

import XCTest

@testable import ZeroSumKit

final class MoneyTests: XCTestCase {
    func testFormat() {
        XCTAssertEqual(Money.format(1_234_500), "1,234.50")
        XCTAssertEqual(Money.format(-400_000), "-400.00")
        XCTAssertEqual(Money.format(0), "0.00")
        XCTAssertEqual(Money.format(1_000_000_000), "1,000,000.00")
        XCTAssertEqual(Money.format(1_235), "1.24")  // half rounds up, like the web client
    }

    func testParse() {
        XCTAssertEqual(Money.parse("12"), 12_000)
        XCTAssertEqual(Money.parse("12.5"), 12_500)
        XCTAssertEqual(Money.parse("1,234.56"), 1_234_560)
        XCTAssertEqual(Money.parse(" -3.005 "), -3_005)
        XCTAssertEqual(Money.parse(".5"), 500)
        XCTAssertEqual(Money.parse("12."), 12_000)
        XCTAssertNil(Money.parse(""))
        XCTAssertNil(Money.parse("."))
        XCTAssertNil(Money.parse("abc"))
        XCTAssertNil(Money.parse("1.2345"))
        XCTAssertNil(Money.parse("99999999999999999999"))
        XCTAssertEqual(Money.parse("9007199254740.991"), 9_007_199_254_740_991)
        XCTAssertNil(Money.parse("9007199254740.992"))
    }

    func testShiftMonth() {
        XCTAssertEqual(Money.shiftMonth("2026-10", by: 1), "2026-11")
        XCTAssertEqual(Money.shiftMonth("2026-12", by: 1), "2027-01")
        XCTAssertEqual(Money.shiftMonth("2026-01", by: -1), "2025-12")
        XCTAssertEqual(Money.shiftMonth("2026-01", by: -13), "2024-12")
    }

    func testDateString() {
        var c = DateComponents()
        c.year = 2026
        c.month = 3
        c.day = 7
        let date = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(Money.dateString(date), "2026-03-07")
    }

    func testDateRoundTrip() throws {
        XCTAssertEqual(Money.dateString(try XCTUnwrap(Money.date(from: "2026-03-07"))), "2026-03-07")
        XCTAssertNil(Money.date(from: "nope"))
    }
}

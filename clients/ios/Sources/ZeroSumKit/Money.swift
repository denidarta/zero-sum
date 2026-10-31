import Foundation

/// Same display and parsing rules as `clients/web/src/money.ts`. Amounts are `Int64` milliunits.
public enum Money {
    /// 1234500 -> "1,234.50"
    public static func format(_ milliunits: Int64) -> String {
        let sign = milliunits < 0 ? "-" : ""
        let cents = (milliunits.magnitude + 5) / 10
        let digits = String(cents / 100)
        var whole = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { whole.append(",") }
            whole.append(ch)
        }
        return "\(sign)\(String(whole.reversed())).\(String(format: "%02d", Int(cents % 100)))"
    }

    private static let pattern = try! NSRegularExpression(pattern: #"^(-?)(\d[\d,]*)?(?:\.(\d{0,3}))?$"#)

    /// "12", "12.5", "1,234.56" -> milliunits. `nil` when invalid.
    public static func parse(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = pattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        func group(_ i: Int) -> String {
            guard let r = Range(m.range(at: i), in: t) else { return "" }
            return String(t[r])
        }
        let whole = group(2).replacingOccurrences(of: ",", with: "")
        let frac = group(3)
        if whole.isEmpty && frac.isEmpty { return nil }
        guard let w = Int64(whole.isEmpty ? "0" : whole) else { return nil }
        let (scaled, overflow) = w.multipliedReportingOverflow(by: 1000)
        if overflow { return nil }
        let f = Int64(frac.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        return group(1).isEmpty ? scaled + f : -(scaled + f)
    }

    // Always Gregorian: the API wants YYYY-MM-DD whatever calendar the device uses.
    private static let gregorian = Calendar(identifier: .gregorian)

    /// Local date as `YYYY-MM-DD`.
    public static func dateString(_ date: Date = Date()) -> String {
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// `YYYY-MM-DD` as a local date, `nil` when malformed.
    public static func date(from string: String) -> Date? {
        let p = string.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return gregorian.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    public static func thisMonth() -> String { String(dateString().prefix(7)) }

    public static func shiftMonth(_ month: String, by delta: Int) -> String {
        let p = month.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2 else { return month }
        let total = p[0] * 12 + (p[1] - 1) + delta
        let year = Int((Double(total) / 12).rounded(.down))
        return String(format: "%04d-%02d", year, total - year * 12 + 1)
    }

    /// "2026-10" -> "October 2026"
    public static func monthTitle(_ month: String) -> String {
        let f = DateFormatter()
        f.calendar = gregorian
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        guard let date = f.date(from: month) else { return month }
        f.locale = .current
        f.dateFormat = "LLLL yyyy"
        return f.string(from: date)
    }
}

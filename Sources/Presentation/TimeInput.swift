import Foundation

/// Typed transaction time. Accepts `HH:mm` (today), `dd.MM HH:mm` (this year) and `dd.MM.yy` / `dd.MM.yyyy HH:mm`;
/// `.`, `-` and `/` work as date separators.
public enum TimeInput {
    public static let hint = "Time: HH:mm or dd.MM.yy HH:mm"

    public static func format(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month, .year, .hour, .minute], from: date)
        return String(format: "%02d.%02d.%02d %02d:%02d", c.day!, c.month!, c.year! % 100, c.hour!, c.minute!)
    }

    public static func parse(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let timePart = parts.last, parts.count <= 2 else { return nil }
        let hm = timePart.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard hm.count == 2, let h = hm[0], let m = hm[1], timePart.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ":") }) else { return nil }

        let today = calendar.dateComponents([.day, .month, .year], from: now)
        var day = today.day!, month = today.month!, year = today.year!
        if parts.count == 2 {
            let d = parts[0].split(whereSeparator: { ".-/".contains($0) }).map { Int($0) }
            guard parts[0].allSatisfy({ $0.isASCII && ($0.isNumber || ".-/".contains($0)) }), (2...3).contains(d.count),
                  let dd = d[0], let mm = d[1] else { return nil }
            day = dd; month = mm
            if d.count == 3 {
                guard let y = d[2] else { return nil }
                year = y < 100 ? 2000 + y : y
            }
        }
        var c = DateComponents(year: year, month: month, day: day, hour: h, minute: m)
        c.calendar = calendar
        guard let date = calendar.date(from: c) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        // Reject overflow such as 31.02 or 25:00, which Calendar silently rolls over.
        guard back.year == year, back.month == month, back.day == day, back.hour == h, back.minute == m else { return nil }
        return date
    }
}

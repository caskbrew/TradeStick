import Foundation

/// Display rules from FR-FMT. Calculations stay exact; only displayed values are rounded (FR-FMT-1).
public enum NumberFormat {
    private static let locale = Locale(identifier: "en_US")
    private static let minus = "\u{2212}"

    private static func plain(_ value: Decimal, min: Int, max: Int, grouping: Bool = false) -> String {
        let style = Decimal.FormatStyle(locale: locale)
            .precision(.fractionLength(min...max))
            .grouping(grouping ? .automatic : .never)
            .rounded(rule: .toNearestOrAwayFromZero)
        return value.formatted(style)
    }

    /// Prices and rates always have the same number of decimals for the same magnitude, everywhere on screen
    /// (`1.3400`, `0.055000`, `67432.10`), so a rate never looks longer than the price next to it.
    public static func price(_ value: Decimal) -> String {
        let magnitude = value < 0 ? -value : value
        var decimals = magnitude >= 1000 ? 2 : 4
        if magnitude > 0 && magnitude < 1 {
            var leadingZeros = 0
            var probe = magnitude
            while probe < Decimal(string: "0.1")! { probe *= 10; leadingZeros += 1 }
            decimals = min(max(leadingZeros + 4, 6), 10)
        }
        return plain(value, min: decimals, max: decimals)
    }

    /// Quote-currency amounts: 2 decimals, up to 4 when |x| < 1 (FR-FMT-3).
    public static func quote(_ value: Decimal) -> String {
        let magnitude = value < 0 ? -value : value
        return plain(value, min: 2, max: magnitude < 1 ? 4 : 2)
    }

    /// Quote amounts of transactions and totals: up to 6 decimals, trailing zeros dropped but never fewer than 2.
    public static func amount(_ value: Decimal) -> String {
        plain(value, min: 2, max: 6, grouping: true)
    }

    /// The value as `quote(_:)` shows it. Signs and colours must follow this, not the raw value, so that a
    /// tiny `+0.003` never appears as a green `+0.00`.
    public static func displayedQuote(_ value: Decimal) -> Decimal {
        let magnitude = value < 0 ? -value : value
        return value.rounded(scale: magnitude < 1 ? 4 : 2)
    }

    /// Percent value as `signedPercent(_:)` shows it (in percent, 2 decimals).
    public static func displayedPercent(_ fraction: Decimal) -> Decimal {
        (fraction * 100).rounded(scale: 2)
    }

    /// Always signed for non-zero values, zero without a sign (FR-UI-14).
    public static func signedQuote(_ value: Decimal) -> String {
        let shown = displayedQuote(value)
        return sign(shown) + quote(shown < 0 ? -shown : shown)
    }

    /// Coin quantity: at least 2 and up to 8 decimals, thousands separators (FR-FMT-4).
    public static func quantity(_ value: Decimal) -> String {
        plain(value, min: 2, max: 8, grouping: true)
    }

    /// `fraction` 0.1188 becomes `+11.88%` (FR-FMT-5).
    public static func signedPercent(_ fraction: Decimal) -> String {
        let percent = (fraction * 100).rounded(scale: 2)
        return sign(percent) + plain(percent < 0 ? -percent : percent, min: 2, max: 2) + "%"
    }

    private static func sign(_ value: Decimal) -> String {
        value > 0 ? "+" : value < 0 ? minus : ""
    }
}

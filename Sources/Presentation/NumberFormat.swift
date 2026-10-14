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

    /// Prices and rates: at least 4 significant digits, at most 10 decimals, trailing zeros dropped but never
    /// fewer than 2 decimals (FR-FMT-2): `0.05333`, `67432.10`.
    public static func price(_ value: Decimal) -> String {
        let magnitude = value < 0 ? -value : value
        var decimals = 2
        if magnitude > 0 && magnitude < 1 {
            var leadingZeros = 0
            var probe = magnitude
            while probe < Decimal(string: "0.1")! { probe *= 10; leadingZeros += 1 }
            decimals = leadingZeros + 4
        }
        return plain(value, min: 2, max: min(max(decimals, 2), 10))
    }

    /// Quote-currency amounts: 2 decimals, up to 4 when |x| < 1 (FR-FMT-3).
    public static func quote(_ value: Decimal) -> String {
        let magnitude = value < 0 ? -value : value
        return plain(value, min: 2, max: magnitude < 1 ? 4 : 2)
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

    /// Coin quantity: up to 8 decimals, no trailing zeros, thousands separators (FR-FMT-4).
    public static func quantity(_ value: Decimal) -> String {
        plain(value, min: 0, max: 8, grouping: true)
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

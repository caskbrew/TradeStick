import Foundation

/// Display rules from FR-FMT. Calculations stay exact; only displayed values are rounded (FR-FMT-1).
public enum NumberFormat {
    private static let locale = Locale(identifier: "en_US")
    private static let minus = "\u{2212}"

    private static func plain(_ value: Decimal, min: Int, max: Int) -> String {
        let style = Decimal.FormatStyle(locale: locale)
            .precision(.fractionLength(min...max))
            .grouping(.never) // no thousands separators anywhere
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

    /// Quote currencies worth cents: always shown with exactly 2 decimals.
    public static func isTwoDecimalCurrency(_ symbol: String) -> Bool {
        ["USDT", "USDC", "FDUSD", "BUSD", "TUSD", "DAI", "USD", "EUR"].contains(symbol.uppercased())
    }

    /// Quote-currency amounts: 2 decimals, up to 4 when |x| < 1 (FR-FMT-3). `fixed`: always exactly 2 (USDT and alike).
    public static func quote(_ value: Decimal, fixed: Bool = false) -> String {
        let magnitude = value < 0 ? -value : value
        return plain(value, min: 2, max: magnitude < 1 && !fixed ? 4 : 2)
    }

    /// Quote amounts of transactions and totals: up to 6 decimals, trailing zeros dropped but never fewer than 2.
    public static func amount(_ value: Decimal) -> String {
        plain(value, min: 2, max: 6)
    }

    /// The value as `quote(_:)` shows it. Signs and colours must follow this, not the raw value, so that a
    /// tiny `+0.003` never appears as a green `+0.00`.
    public static func displayedQuote(_ value: Decimal, fixed: Bool = false) -> Decimal {
        let magnitude = value < 0 ? -value : value
        return value.rounded(scale: magnitude < 1 && !fixed ? 4 : 2)
    }

    /// Percent value as `signedPercent(_:)` shows it (in percent, 2 decimals).
    public static func displayedPercent(_ fraction: Decimal) -> Decimal {
        (fraction * 100).rounded(scale: 2)
    }

    /// Always signed for non-zero values, zero without a sign (FR-UI-14).
    public static func signedQuote(_ value: Decimal, fixed: Bool = false) -> String {
        let shown = displayedQuote(value, fixed: fixed)
        return sign(shown) + quote(shown < 0 ? -shown : shown, fixed: fixed)
    }

    /// The headline result of a sticker: as `signedQuote`, but from a million up shortened (`−122.2M`), because the
    /// full figure would shrink to a few pixels. Callers show the full value in a tip.
    public static func headlineQuote(_ value: Decimal, fixed: Bool = false) -> String {
        let shown = displayedQuote(value, fixed: fixed)
        var scaled = shown.magnitude / 1_000_000
        guard scaled >= 1 else { return signedQuote(value, fixed: fixed) }
        var unit = 0
        while unit < 2, scaled.rounded(scale: 1) >= 1000 { scaled /= 1000; unit += 1 } // 999.96M is 1.0B, not 1000.0M
        return sign(shown) + plain(scaled, min: 1, max: 1) + ["M", "B", "T"][unit]
    }

    /// Coin quantity: at least 2 and up to 8 decimals, no thousands separators.
    public static func quantity(_ value: Decimal) -> String {
        plain(value, min: 2, max: 8)
    }

    /// Signed coin quantity for a profit or loss in coins: 2 decimals from 1 up, 4 below, zero without a sign.
    public static func signedQuantity(_ value: Decimal) -> String {
        let shown = value.rounded(scale: value.magnitude >= 1 ? 2 : 4)
        return sign(shown) + quantity(shown.magnitude)
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

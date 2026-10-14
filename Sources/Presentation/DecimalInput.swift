import Foundation

public enum DecimalInput {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Parses user input (FR-TX-3): `.` or `,` as the decimal separator, spaces as thousands separators.
    /// Rejects negatives, exponents, several separators and anything non-numeric.
    public static func parse(_ text: String) -> Decimal? {
        let cleaned = text.filter { !$0.isWhitespace } // includes no-break spaces
        guard !cleaned.isEmpty,
              cleaned.allSatisfy({ ("0"..."9").contains($0) || $0 == "." || $0 == "," }),
              cleaned.contains(where: { ("0"..."9").contains($0) }),
              cleaned.filter({ $0 == "." || $0 == "," }).count <= 1
        else { return nil }
        return Decimal(string: cleaned.replacingOccurrences(of: ",", with: "."), locale: posix)
    }
}

extension Decimal {
    /// Rounds half away from zero to `scale` decimal places.
    public func rounded(scale: Int) -> Decimal {
        var source = self, result = Decimal()
        NSDecimalRound(&result, &source, scale, .plain)
        return result
    }
}

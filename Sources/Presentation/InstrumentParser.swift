import Domain
import Foundation

/// Turns what the user typed into candidate instruments (FR-NEW-3). The exchange has the final say:
/// the caller tries each candidate with `ExchangeAdapter.supports`.
public enum InstrumentParser {
    /// Common quote assets, longest first, for input without a separator such as `GRAMUSDT`.
    static let knownQuotes = ["FDUSD", "USDT", "USDC", "BUSD", "TUSD", "USDP", "EUR", "TRY", "BRL", "BTC", "ETH", "BNB"]

    public static func candidates(_ text: String) -> [Instrument] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators = CharacterSet(charactersIn: "/-_ ")
        let parts = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
        if parts.count == 2 { return [Instrument(base: parts[0], quote: parts[1])].filter(isValid) }
        guard parts.count == 1 else { return [] }

        let symbol = parts[0].uppercased()
        return knownQuotes
            .filter { symbol.hasSuffix($0) && symbol.count > $0.count }
            .map { Instrument(base: String(symbol.dropLast($0.count)), quote: $0) }
            .filter(isValid)
    }

    private static func isValid(_ i: Instrument) -> Bool {
        let ok = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
        return ok(i.base) && ok(i.quote)
    }
}

import Foundation

/// Normalised trading pair, independent of any exchange's symbol format (FR-EX-6).
public struct Instrument: Hashable, Sendable, CustomStringConvertible {
    public let base: String
    public let quote: String

    public init(base: String, quote: String) {
        self.base = base.trimmingCharacters(in: .whitespaces).uppercased()
        self.quote = quote.trimmingCharacters(in: .whitespaces).uppercased()
    }

    public var description: String { "\(base)/\(quote)" }
}

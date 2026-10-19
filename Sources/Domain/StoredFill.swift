import Foundation

/// A fill exactly as the exchange sent it (one JSON object), before any interpretation.
public struct RawFill: Equatable, Sendable {
    public var id: String
    public var json: String
    public init(id: String, json: String) { self.id = id; self.json = json }
}

/// A raw fill kept locally: the exchange forgets old trades, we do not. `feeRates` holds what a fee paid in a third asset
/// (BNB) was worth in the quote currency when the fill was priced, so it can be valued again without the network.
public struct StoredFill: Equatable, Sendable {
    public var exchange: String
    public var symbol: String
    public var raw: RawFill
    public var feeRates: [String: Decimal]
    public init(exchange: String, symbol: String, raw: RawFill, feeRates: [String: Decimal] = [:]) {
        self.exchange = exchange; self.symbol = symbol; self.raw = raw; self.feeRates = feeRates
    }
}

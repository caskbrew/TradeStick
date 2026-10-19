import Domain
import Foundation

/// What an exchange offers for a user's API key: a check and the trade history of a pair (oldest first).
/// One implementation per exchange, like `ExchangeAdapter` for prices.
public protocol ExchangeAccount: Sendable {
    var id: String { get }
    func check(_ credentials: APICredentials) async throws -> APIKeyCheck
    func trades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade]
    /// The history as the exchange sent it, to be kept (the exchange forgets old trades) and read again with `parse`.
    func rawFills(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [RawFill]
    func parse(_ raw: RawFill) throws -> ImportedTrade
    /// Price of one unit of `asset` in `quote` around `date`, for fees paid in a third asset (BNB); nil if unknown.
    func feeRate(asset: String, quote: String, at date: Date) async -> Decimal?
}

public extension ExchangeAccount {
    func feeRate(asset: String, quote: String, at date: Date) async -> Decimal? { nil }
    func rawFills(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [RawFill] { throw URLError(.unsupportedURL) }
    func parse(_ raw: RawFill) throws -> ImportedTrade { throw URLError(.unsupportedURL) }

    /// The trade history with every fee valued in the quote currency.
    func pricedTrades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade] {
        var rates: [String: [String: Decimal]] = [:]
        return await priced(try await trades(credentials, instrument), instrument, rates: &rates)
    }

    /// Values each fill's fees in the quote currency: a fee in the quote counts as it is, one in the base at the fill's own
    /// rate, any other asset at its hourly price. `rates` (fill id → asset → price) are used first and filled with what is
    /// looked up; with `lookup` off nothing goes to the network and such fees stay unpriced.
    func priced(_ trades: [ImportedTrade], _ instrument: Instrument, rates: inout [String: [String: Decimal]], lookup: Bool = true) async -> [ImportedTrade] {
        var cache: [String: Decimal?] = [:]
        var out: [ImportedTrade] = []
        for var trade in trades {
            trade.feeQuote = 0
            trade.feeUnpriced = []
            for (asset, value) in trade.fees {
                if asset == instrument.quote { trade.feeQuote += value }
                else if asset == instrument.base, let rate = trade.rate { trade.feeQuote += value * rate }
                else if let rate = rates[trade.externalID]?[asset] { trade.feeQuote += value * rate }
                else {
                    let key = "\(asset)/\(Int(trade.occurredAt.timeIntervalSince1970 / 3600))"
                    if lookup, cache[key] == nil { cache[key] = .some(await feeRate(asset: asset, quote: instrument.quote, at: trade.occurredAt)) }
                    if let rate = cache[key] ?? nil { trade.feeQuote += value * rate; rates[trade.externalID, default: [:]][asset] = rate }
                    else { trade.feeUnpriced.append(asset) }
                }
            }
            out.append(trade)
        }
        return out
    }
}

/// A JSON object as compact text with sorted keys (stable, so equal fills give equal text), and back.
func rawJSON(_ object: [String: Any]) throws -> String {
    guard let text = String(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8) else { throw URLError(.cannotParseResponse) }
    return text
}

func jsonObject(_ text: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw URLError(.cannotParseResponse) }
    return object
}

extension BinanceAccountAPI: ExchangeAccount {
    public var id: String { "binance" }
    public func trades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade] {
        try await myTrades(credentials, instrument)
    }
    public func rawFills(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [RawFill] { try await rawTrades(credentials, instrument) }
    public func parse(_ raw: RawFill) throws -> ImportedTrade { try Self.trade(from: try jsonObject(raw.json)) }
    public func feeRate(asset: String, quote: String, at date: Date) async -> Decimal? { await hourlyOpen(symbol: asset + quote, at: date) }
}

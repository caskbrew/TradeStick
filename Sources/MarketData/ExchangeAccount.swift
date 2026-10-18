import Domain
import Foundation

/// What an exchange offers for a user's API key: a check and the trade history of a pair (oldest first).
/// One implementation per exchange, like `ExchangeAdapter` for prices.
public protocol ExchangeAccount: Sendable {
    var id: String { get }
    func check(_ credentials: APICredentials) async throws -> APIKeyCheck
    func trades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade]
    /// Price of one unit of `asset` in `quote` around `date`, for fees paid in a third asset (BNB); nil if unknown.
    func feeRate(asset: String, quote: String, at date: Date) async -> Decimal?
}

public extension ExchangeAccount {
    func feeRate(asset: String, quote: String, at date: Date) async -> Decimal? { nil }

    /// The trade history with every fee valued in the quote currency: a fee in the quote counts as it is, one in the base
    /// at the fill's own rate, any other asset at its hourly price (one lookup per asset and hour).
    func pricedTrades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade] {
        var cache: [String: Decimal?] = [:]
        var out: [ImportedTrade] = []
        for var trade in try await trades(credentials, instrument) {
            for (asset, value) in trade.fees {
                if asset == instrument.quote { trade.feeQuote += value }
                else if asset == instrument.base, let rate = trade.rate { trade.feeQuote += value * rate }
                else {
                    let key = "\(asset)/\(Int(trade.occurredAt.timeIntervalSince1970 / 3600))"
                    if cache[key] == nil { cache[key] = .some(await feeRate(asset: asset, quote: instrument.quote, at: trade.occurredAt)) }
                    if let rate = cache[key] ?? nil { trade.feeQuote += value * rate } else { trade.feeUnpriced.append(asset) }
                }
            }
            out.append(trade)
        }
        return out
    }
}

extension BinanceAccountAPI: ExchangeAccount {
    public var id: String { "binance" }
    public func trades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade] {
        try await myTrades(credentials, instrument)
    }
    public func feeRate(asset: String, quote: String, at date: Date) async -> Decimal? { await hourlyOpen(symbol: asset + quote, at: date) }
}

import Domain
import Foundation

/// What an exchange offers for a user's API key: a check and the trade history of a pair (oldest first).
/// One implementation per exchange, like `ExchangeAdapter` for prices.
public protocol ExchangeAccount: Sendable {
    var id: String { get }
    func check(_ credentials: APICredentials) async throws -> APIKeyCheck
    func trades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade]
}

extension BinanceAccountAPI: ExchangeAccount {
    public var id: String { "binance" }
    public func trades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade] {
        try await myTrades(credentials, instrument)
    }
}

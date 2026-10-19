import Domain
import Foundation
import MarketData
import Persistence

/// The fills of one pair as the app keeps them: everything the exchange ever sent, saved raw, with the fee prices.
/// The exchange only serves recent trades; what it sent once stays here and is shown together with what is new.
public struct FillHistory: Sendable {
    let account: any ExchangeAccount
    let store: TradeStore
    let instrument: Instrument

    public init(account: any ExchangeAccount, store: TradeStore, instrument: Instrument) {
        self.account = account; self.store = store; self.instrument = instrument
    }

    private var symbol: String { "\(instrument.base)/\(instrument.quote)" }

    /// The saved fills, valued without the network (a fee whose price was never saved stays unpriced).
    public func saved() async throws -> [ImportedTrade] {
        try await interpret(try store.fills(exchange: account.id, symbol: symbol), lookup: false)
    }

    /// Asks the exchange, saves what it sent, and returns everything known: saved fills and the new ones.
    public func refresh(_ credentials: APICredentials) async throws -> [ImportedTrade] {
        let fresh = try await account.rawFills(credentials, instrument)
        try store.saveFills(fresh.map { StoredFill(exchange: account.id, symbol: symbol, raw: $0) })
        return try await interpret(try store.fills(exchange: account.id, symbol: symbol), lookup: true)
    }

    private func interpret(_ fills: [StoredFill], lookup: Bool) async throws -> [ImportedTrade] {
        var rates = Dictionary(uniqueKeysWithValues: fills.map { ($0.raw.id, $0.feeRates) })
        let trades = fills.compactMap { try? account.parse($0.raw) } // a fill that no longer parses is skipped, not fatal
        let priced = await account.priced(trades, instrument, rates: &rates, lookup: lookup)
        try store.saveFills(fills.compactMap { f in rates[f.raw.id].flatMap { $0 == f.feeRates ? nil : StoredFill(exchange: f.exchange, symbol: f.symbol, raw: f.raw, feeRates: $0) } })
        return priced.sorted { ($0.occurredAt, $0.externalID) < ($1.occurredAt, $1.externalID) }
    }
}

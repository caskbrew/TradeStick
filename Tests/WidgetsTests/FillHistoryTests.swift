import Domain
import Foundation
import MarketData
import Persistence
import Testing
@testable import Widgets

/// An exchange whose "recent window" the test moves: what it serves is `window`, its fee price is `bnb`.
final class WindowedExchange: ExchangeAccount, @unchecked Sendable {
    let id = "stub"
    var window: [Int] = []
    var bnb: Decimal?
    var down = false
    func check(_ credentials: APICredentials) async throws -> APIKeyCheck { APIKeyCheck() }
    func trades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade] { [] }
    func rawFills(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [RawFill] {
        if down { throw URLError(.notConnectedToInternet) }
        return window.map { RawFill(id: String($0), json: "\($0)") }
    }
    func parse(_ raw: RawFill) throws -> ImportedTrade {
        guard let n = Int(raw.json) else { throw URLError(.cannotParseResponse) }
        return ImportedTrade(externalID: raw.id, side: .buy, quantity: 10, amount: 100, occurredAt: Date(timeIntervalSince1970: Double(n)), fees: ["BNB": d("0.001")])
    }
    func feeRate(asset: String, quote: String, at date: Date) async -> Decimal? { bnb }
}

private func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }

@Suite struct FillHistoryTests {
    let creds = APICredentials(key: "K", secret: "S")
    let pair = Instrument(base: "G", quote: "USDT")

    @Test func whatTheExchangeForgotStaysAndIsShownWithTheNew() async throws {
        let exchange = WindowedExchange()
        let history = FillHistory(account: exchange, store: try TradeStore.inMemory(), instrument: pair)
        exchange.window = [1, 2, 3]
        #expect(try await history.refresh(creds).map(\.externalID) == ["1", "2", "3"])
        exchange.window = [3, 4] // 1 and 2 aged out of the exchange's window
        #expect(try await history.refresh(creds).map(\.externalID) == ["1", "2", "3", "4"])
        #expect(try await history.saved().map(\.externalID) == ["1", "2", "3", "4"])
    }

    @Test func savedTradesAreAvailableWhenTheExchangeIsDown() async throws {
        let exchange = WindowedExchange()
        let history = FillHistory(account: exchange, store: try TradeStore.inMemory(), instrument: pair)
        exchange.window = [1]
        _ = try await history.refresh(creds)
        exchange.down = true
        await #expect(throws: (any Error).self) { try await history.refresh(creds) }
        #expect(try await history.saved().count == 1)
    }

    @Test func theFeePriceIsKeptSoSavedTradesAreValuedOffline() async throws {
        let exchange = WindowedExchange()
        exchange.bnb = 600
        let history = FillHistory(account: exchange, store: try TradeStore.inMemory(), instrument: pair)
        exchange.window = [1]
        #expect(try await history.refresh(creds).first?.feeQuote == d("0.6"))
        exchange.bnb = nil; exchange.down = true // no price and no exchange any more
        let saved = try await history.saved()
        #expect(saved.first?.feeQuote == d("0.6") && saved.first?.feeUnpriced == [])
    }

    @Test func aFeeThatCouldNotBePricedIsRetriedOnTheNextRefresh() async throws {
        let exchange = WindowedExchange()
        let history = FillHistory(account: exchange, store: try TradeStore.inMemory(), instrument: pair)
        exchange.window = [1]
        #expect(try await history.refresh(creds).first?.feeUnpriced == ["BNB"])
        exchange.bnb = 600
        #expect(try await history.refresh(creds).first?.feeQuote == d("0.6"))
    }

    @Test func aSavedFillThatNoLongerParsesIsSkippedNotFatal() async throws {
        let store = try TradeStore.inMemory()
        try store.saveFills([StoredFill(exchange: "stub", symbol: "G/USDT", raw: RawFill(id: "x", json: "garbage"))])
        let history = FillHistory(account: WindowedExchange(), store: store, instrument: pair)
        #expect(try await history.saved().isEmpty)
    }
}

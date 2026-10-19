import Domain
import Foundation
import Testing
@testable import MarketData

@Suite struct RawFillTests {
    let creds = APICredentials(key: "K", secret: "s")
    let gram = Instrument(base: "GRAM", quote: "USDT")

    @Test func poloniexRawFillsParseBackToTheSameTrades() async throws {
        let body = #"[{"id":"1","symbol":"GRAM_USDT","orderId":"8","side":"BUY","createTime":1700000100000,"price":"1.3","quantity":"100","amount":"130","feeCurrency":"GRAM","feeAmount":"0.1"}]"#
        let api = PoloniexAccountAPI(now: { Date() }, send: { _ in (Data(body.utf8), 200) })
        let raw = try await api.rawFills(creds, gram)
        #expect(raw.map(\.id) == ["1"] && raw[0].json.contains(#""feeAmount":"0.1""#))
        #expect(try raw.map(api.parse) == (try await api.trades(creds, gram)))
        #expect(api.id == "poloniex" && BybitAccountAPI().id == "bybit" && BinanceAccountAPI().id == "binance")
    }

    @Test func aPoloniexFillWithoutAnIdFailsInsteadOfBeingDropped() async {
        let api = PoloniexAccountAPI(now: { Date() }, send: { _ in (Data(#"[{"symbol":"GRAM_USDT"}]"#.utf8), 200) })
        await #expect(throws: (any Error).self) { _ = try await api.rawFills(creds, gram) }
    }

    @Test func binanceTradesGoThroughTheSameParser() async throws {
        let body = #"[{"symbol":"GRAMUSDT","id":1,"orderId":1,"price":"0.5","qty":"10","quoteQty":"5","commission":"0","commissionAsset":"GRAM","time":1700000000000,"isBuyer":true,"isMaker":false}]"#
        let api = BinanceAccountAPI(now: { Date() }, send: { _ in (Data(body.utf8), 200) })
        let account: any ExchangeAccount = api
        #expect(try await account.trades(creds, gram).count == 1)
    }

    @Test func anExchangeWithoutSavedHistoryRefusesRawFillsAndHasNoFeeRates() async {
        struct Plain: ExchangeAccount {
            let id = "plain"
            func check(_ credentials: APICredentials) async throws -> APIKeyCheck { fatalError() }
            func trades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade] { [] }
        }
        let plain = Plain()
        #expect(await plain.feeRate(asset: "BNB", quote: "USDT", at: Date()) == nil)
        await #expect(throws: (any Error).self) { _ = try await plain.rawFills(creds, gram) }
        #expect(throws: (any Error).self) { _ = try plain.parse(RawFill(id: "1", json: "{}")) }
    }
}

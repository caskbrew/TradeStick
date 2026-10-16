import Domain
import Foundation
import Testing
@testable import MarketData

@Suite struct PoloniexTests {
    let creds = APICredentials(key: "KEY123", secret: "secret")
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    func account(_ recorder: Recorder, _ reply: @escaping @Sendable (URLRequest) -> (String, Int)) -> PoloniexAccountAPI {
        PoloniexAccountAPI(now: { at }, send: { request in
            recorder.add(request)
            let (body, status) = reply(request)
            return (Data(body.utf8), status)
        })
    }

    func adapter(_ reply: @escaping @Sendable (URL) -> (String, Int)) -> PoloniexAdapter {
        PoloniexAdapter(fetch: { url in let (body, status) = reply(url); return (Data(body.utf8), status) })
    }

    // Reference value computed independently (Python hmac + base64) for the documented payload layout.
    @Test func signatureIsBase64HmacOverMethodPathAndSortedParams() {
        let sig = PoloniexSigner.sign(method: "GET", path: "/trades", params: [("symbols", "ETH_USDT"), ("signTimestamp", "1631018760000"), ("limit", "5")], secret: "secret")
        #expect(sig == "119M5je2NXheChS1MH70GVx1QIRP8kJjBOBcSM/dJz0=")
    }

    @Test func requestsCarryTheDocumentedHeaders() async throws {
        let rec = Recorder()
        _ = try await account(rec) { _ in ("[]", 200) }.check(creds)
        let r = try #require(rec.requests.first)
        #expect(r.url?.absoluteString == "https://api.poloniex.com/accounts")
        #expect(r.value(forHTTPHeaderField: "key") == "KEY123")
        #expect(r.value(forHTTPHeaderField: "signTimestamp") == "1700000000000")
        #expect(r.value(forHTTPHeaderField: "signatureVersion") == "2")
        #expect(r.value(forHTTPHeaderField: "signature") == PoloniexSigner.sign(method: "GET", path: "/accounts", params: [("signTimestamp", "1700000000000")], secret: "secret"))
    }

    @Test func aRejectedKeyReportsThePoloniexMessage() async {
        let rec = Recorder()
        await #expect(throws: PoloniexAPIError.self) {
            _ = try await account(rec) { _ in (#"{"code":21001,"message":"Invalid API key"}"#, 401) }.check(creds)
        }
    }

    @Test func tradesAreParsedAndSortedOldestFirst() async throws {
        let rec = Recorder()
        let body = """
        [{"id":"2","symbol":"GRAM_USDT","orderId":"9","side":"SELL","createTime":1700000500000,"price":"1.4","quantity":"200","amount":"280","feeCurrency":"USDT","feeAmount":"0.28"},
         {"id":"1","symbol":"GRAM_USDT","orderId":"8","side":"BUY","createTime":1700000100000,"price":"1.3","quantity":"100","amount":"130","feeCurrency":"GRAM","feeAmount":"0"}]
        """
        let trades = try await account(rec) { _ in (body, 200) }.trades(creds, Instrument(base: "GRAM", quote: "USDT"))
        #expect(trades.map(\.externalID) == ["1", "2"])
        #expect(trades[0].side == .buy && trades[0].quantity == 100 && trades[0].amount == 130 && trades[0].fees.isEmpty)
        #expect(trades[1].side == .sell && trades[1].fees == ["USDT": Decimal(string: "0.28")!] && trades[1].orderID == "9")
        let url = try #require(rec.requests.first?.url?.absoluteString)
        #expect(url.contains("symbols=GRAM_USDT") && url.contains("limit=1000") && !url.contains("signTimestamp"))
    }

    @Test func fullPagesWalkBackInTime() async throws {
        let rec = Recorder()
        @Sendable func page(from: Int, count: Int, offset: Int) -> String {
            "[" + (0..<count).map { i in
                #"{"id":"\#(from - i)","orderId":"o","side":"BUY","createTime":\#(1_699_999_999_000 - (offset + i) * 1000),"quantity":"1","amount":"1","feeCurrency":"USDT","feeAmount":"0"}"#
            }.joined(separator: ",") + "]"
        }
        let calls = Recorder()
        let trades = try await account(rec) { r in
            calls.add(r)
            return (calls.requests.count == 1 ? page(from: 2000, count: 1000, offset: 0) : page(from: 1000, count: 3, offset: 1000), 200)
        }.trades(creds, Instrument(base: "GRAM", quote: "USDT"))
        #expect(trades.count == 1003)
        #expect(calls.requests.count == 2)
    }

    @Test func marketsListOnlyTradablePairsAndSupportsChecksState() async throws {
        let markets = #"[{"symbol":"GRAM_USDT","baseCurrencyName":"GRAM","quoteCurrencyName":"USDT","state":"NORMAL"},{"symbol":"OLD_USDT","baseCurrencyName":"OLD","quoteCurrencyName":"USDT","state":"PAUSE"}]"#
        let a = adapter { _ in (markets, 200) }
        #expect(try await a.instruments() == [Instrument(base: "GRAM", quote: "USDT")])
        #expect(try await a.supports(Instrument(base: "GRAM", quote: "USDT")))
        #expect(try await adapter { _ in (#"{"code":1002}"#, 404) }.supports(Instrument(base: "NO", quote: "USDT")) == false)
    }

    @Test func snapshotAndSocketMessagesGivePriceOpenAndTime() throws {
        let tick = try PoloniexParsing.ticker24h(Data(#"{"symbol":"GRAM_USDT","open":"1.30","close":"1.40","ts":1700000000123}"#.utf8), now: at)
        #expect(tick.price == Decimal(string: "1.4")! && tick.open24h == Decimal(string: "1.3")! && tick.eventTime == Date(timeIntervalSince1970: 1_700_000_000.123))
        let msg = try PoloniexParsing.message(Data(#"{"channel":"ticker","data":[{"symbol":"GRAM_USDT","open":"1.30","close":"1.41","ts":"1700000001000"}]}"#.utf8), symbol: "GRAM_USDT")
        #expect(msg.ticker?.price == Decimal(string: "1.41")!)
        #expect(try PoloniexParsing.message(Data(#"{"event":"pong"}"#.utf8), symbol: "GRAM_USDT").ticker == nil)
        #expect(try PoloniexParsing.message(Data(#"{"event":"error","message":"bad"}"#.utf8), symbol: "GRAM_USDT").error == "bad")
    }
}

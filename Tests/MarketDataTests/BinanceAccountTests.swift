import Domain
import Foundation
import Testing
@testable import MarketData

/// Records the requests a fake exchange received.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { items } }
    func add(_ r: URLRequest) { lock.withLock { items.append(r) } }
}

@Suite struct BinanceAccountTests {
    let creds = APICredentials(key: "KEY123", secret: "SECRET456")
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    func api(_ recorder: Recorder, _ reply: @escaping @Sendable (URLRequest) -> (String, Int)) -> BinanceAccountAPI {
        BinanceAccountAPI(now: { at }, send: { request in
            recorder.add(request)
            let (body, status) = reply(request)
            return (Data(body.utf8), status)
        })
    }

    // The example from Binance's API documentation ("HMAC SHA256 signature").
    @Test func signatureMatchesTheDocumentedExample() {
        let query = "symbol=LTCBTC&side=BUY&type=LIMIT&timeInForce=GTC&quantity=1&price=0.1&recvWindow=5000&timestamp=1499827319559"
        let secret = "NhqPtmdSJYdKjVHjA7PZj4Mge3R5YNiP1e3UZjInClVN65XAbvqqM6A7H5fATj0j"
        #expect(BinanceSigner.sign(query, secret: secret) == "c8db56825ae71d6d79447849e617115f4a920fa2acdcab2b053c4b2838bd6b71")
    }

    @Test func requestsAreSignedAndCarryTheKeyHeader() async throws {
        let rec = Recorder()
        _ = try await api(rec) { _ in ("{}", 200) }.check(creds)
        let first = try #require(rec.requests.first)
        #expect(first.value(forHTTPHeaderField: "X-MBX-APIKEY") == "KEY123")
        let url = try #require(first.url?.absoluteString)
        #expect(url.hasPrefix("https://api.binance.com/api/v3/account?"))
        let (signed, signature) = try #require(url.components(separatedBy: "?").last.map { q -> (String, String) in
            let r = q.range(of: "&signature=")!
            return (String(q[..<r.lowerBound]), String(q[r.upperBound...]))
        })
        #expect(signed.contains("timestamp=1700000000000"))
        #expect(signature == BinanceSigner.sign(signed, secret: "SECRET456"))
        #expect(!url.contains("SECRET456")) // the secret never leaves the machine
    }

    @Test func tradingOrWithdrawalPermissionsGiveWarnings() async throws {
        let rec = Recorder()
        let result = try await api(rec) { r in
            r.url!.path.contains("apiRestrictions") ? (#"{"enableWithdrawals":true,"enableSpotAndMarginTrading":true}"#, 200) : ("{}", 200)
        }.check(creds)
        #expect(result.warnings.count == 3)
        let readOnly = try await api(Recorder()) { r in
            r.url!.path.contains("apiRestrictions") ? (#"{"enableWithdrawals":false,"enableSpotAndMarginTrading":false}"#, 200) : ("{}", 200)
        }.check(creds)
        #expect(readOnly.warnings.isEmpty && readOnly.readOnly == true && result.readOnly == false)
    }

    @Test func aFailedPermissionLookupDoesNotFailTheCheck() async throws {
        let result = try await api(Recorder()) { r in
            r.url!.path.contains("apiRestrictions") ? (#"{"code":-2015,"msg":"x"}"#, 401) : ("{}", 200)
        }.check(creds)
        #expect(result == APIKeyCheck())
    }

    @Test func binanceErrorsAreReadable() async {
        do {
            _ = try await api(Recorder()) { _ in (#"{"code":-2015,"msg":"Invalid API-key, IP, or permissions for action."}"#, 401) }.check(creds)
            Issue.record("expected an error")
        } catch let error as BinanceAPIError {
            #expect(error.code == -2015)
            #expect("\(error)" == "Invalid API-key, IP, or permissions for action. (-2015)")
        } catch { Issue.record("\(error)") }
    }
}

@Suite struct BinanceMyTradesTests {
    let creds = APICredentials(key: "K", secret: "S")
    let gram = Instrument(base: "GRAM", quote: "USDT")

    func row(_ id: Int, order: Int = 1, buyer: Bool, qty: String = "10", quote: String = "5", time: Int = 1_700_000_000_000, fee: String = "0.00000000") -> String {
        #"{"symbol":"GRAMUSDT","id":\#(id),"orderId":\#(order),"price":"0.5","qty":"\#(qty)","quoteQty":"\#(quote)","commission":"\#(fee)","commissionAsset":"BNB","time":\#(time),"isBuyer":\#(buyer),"isMaker":false}"#
    }

    @Test func fillsBecomeImportedTradesOldestFirst() async throws {
        let body = "[" + [row(2, buyer: false, time: 1_700_000_100_000), row(1, buyer: true, fee: "0.0004")].joined(separator: ",") + "]"
        let api = BinanceAccountAPI(now: { Date() }, send: { _ in (Data(body.utf8), 200) })
        let trades = try await api.myTrades(creds, gram)
        #expect(trades.map(\.externalID) == ["1", "2"])
        #expect(trades[0] == ImportedTrade(externalID: "1", side: .buy, quantity: 10, amount: 5, occurredAt: Date(timeIntervalSince1970: 1_700_000_000), orderID: "1", fees: ["BNB": dec("0.0004")]))
        #expect(trades[1].side == .sell && trades[1].feeText == nil && trades[0].feeText == "0.0004 BNB")
    }

    @Test func rawFillsKeepTheExchangesTextAndParseBackToTheSameTrades() async throws {
        let body = "[" + [row(2, buyer: false, time: 1_700_000_100_000), row(1, buyer: true, fee: "0.0004")].joined(separator: ",") + "]"
        let api = BinanceAccountAPI(now: { Date() }, send: { _ in (Data(body.utf8), 200) })
        let raw = try await api.rawFills(creds, gram)
        #expect(Set(raw.map(\.id)) == ["1", "2"])
        #expect(raw.allSatisfy { $0.json.contains("\"commissionAsset\":\"BNB\"") && $0.json.contains("\"symbol\":\"GRAMUSDT\"") }) // nothing dropped
        let parsed = try raw.map(api.parse).sorted { $0.externalID < $1.externalID }
        #expect(parsed == (try await api.myTrades(creds, gram)))
    }

    @Test func fullPagesAreFollowedWithFromId() async throws {
        let recorder = Recorder()
        let page1 = "[" + (1...1000).map { row($0, buyer: true) }.joined(separator: ",") + "]"
        let page2 = "[" + [row(1001, buyer: false)].joined(separator: ",") + "]"
        let api = BinanceAccountAPI(now: { Date() }, send: { request in
            recorder.add(request)
            return (Data((recorder.requests.count == 1 ? page1 : page2).utf8), 200)
        })
        let trades = try await api.myTrades(creds, gram)
        #expect(trades.count == 1001)
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests[0].url!.query!.contains("fromId=0"))
        #expect(recorder.requests[1].url!.query!.contains("fromId=1001"))
        #expect(recorder.requests[0].url!.query!.contains("symbol=GRAMUSDT"))
    }

    @Test func aBrokenRowFailsInsteadOfBeingSkipped() async {
        let api = BinanceAccountAPI(now: { Date() }, send: { _ in (Data(#"[{"id":1,"qty":"x"}]"#.utf8), 200) })
        await #expect(throws: (any Error).self) { try await api.myTrades(creds, gram) }
    }
}

@Suite struct BinanceInstrumentsTests {
    @Test func onlyTradingSpotPairsAreListedSorted() throws {
        let body = Data(#"""
        {"symbols":[
          {"symbol":"GRAMUSDT","status":"TRADING","isSpotTradingAllowed":true,"baseAsset":"GRAM","quoteAsset":"USDT"},
          {"symbol":"BTCUSDT","status":"TRADING","isSpotTradingAllowed":true,"baseAsset":"BTC","quoteAsset":"USDT"},
          {"symbol":"OLDUSDT","status":"BREAK","isSpotTradingAllowed":true,"baseAsset":"OLD","quoteAsset":"USDT"},
          {"symbol":"MARGINONLY","status":"TRADING","isSpotTradingAllowed":false,"baseAsset":"MAR","quoteAsset":"USDT"}]}
        """#.utf8)
        let list = try BinanceParsing.tradableSpotInstruments(exchangeInfo: body)
        #expect(list == [Instrument(base: "BTC", quote: "USDT"), Instrument(base: "GRAM", quote: "USDT")])
    }
}

@Suite struct FeePricingTests {
    struct Stub: ExchangeAccount {
        let id = "stub"
        let history: [ImportedTrade]
        let bnb: Decimal?
        func check(_ credentials: APICredentials) async throws -> APIKeyCheck { APIKeyCheck() }
        func trades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade] { history }
        func feeRate(asset: String, quote: String, at date: Date) async -> Decimal? { asset == "BNB" ? bnb : nil }
    }
    let creds = APICredentials(key: "K", secret: "S")
    let pair = Instrument(base: "GRAM", quote: "USDT")
    func fill(_ id: String, _ side: Side, _ qty: Decimal, _ amt: Decimal, _ fees: [String: Decimal]) -> ImportedTrade {
        ImportedTrade(externalID: id, side: side, quantity: qty, amount: amt, occurredAt: Date(timeIntervalSince1970: 1_700_000_000), fees: fees)
    }

    @Test func feesAreValuedInQuoteAndCountAsCost() async throws {
        let out = try await Stub(history: [
            fill("1", .buy, 100, 200, ["USDT": 0.2]),          // quote: as is
            fill("2", .buy, 100, 200, ["GRAM": 0.1]),          // base: 0.1 * rate 2
            fill("3", .sell, 100, 300, ["BNB": 0.001]),        // BNB at 600
            fill("4", .buy, 100, 200, ["ETH": 1]),             // unknown asset: not included
        ], bnb: 600).pricedTrades(creds, pair)
        #expect(out.map(\.feeQuote) == [0.2, 0.2, 0.6, 0])
        #expect(out.map(\.netAmount) == [200.2, 200.2, 299.4, 200])
        #expect(out[3].feeUnpriced == ["ETH"])
    }

    @Test func savedRatesPriceAFeeWithoutTheNetwork() async {
        let stub = Stub(history: [], bnb: nil) // the lookup would fail
        var rates: [String: [String: Decimal]] = ["3": ["BNB": 600]]
        let out = await stub.priced([fill("3", .sell, 100, 300, ["BNB": 0.001]), fill("4", .buy, 100, 200, ["BNB": 0.001])], pair, rates: &rates, lookup: false)
        #expect(out[0].feeQuote == 0.6 && out[0].feeUnpriced.isEmpty)
        #expect(out[1].feeQuote == 0 && out[1].feeUnpriced == ["BNB"]) // no saved price, no network: unpriced
    }

    @Test func aLookedUpRateIsReportedForSaving() async {
        var rates: [String: [String: Decimal]] = [:]
        _ = await Stub(history: [], bnb: 600).priced([fill("3", .sell, 100, 300, ["BNB": 0.001])], pair, rates: &rates)
        #expect(rates == ["3": ["BNB": 600]])
    }

    @Test func groupedOrderSumsTheFees() {
        var a = fill("1", .buy, 1, 10, [:]); a.feeQuote = 0.1
        var b = fill("2", .buy, 1, 10, [:]); b.feeQuote = 0.2; b.feeUnpriced = ["ETH"]
        let both = [a, b].map { t -> ImportedTrade in var t = t; t.orderID = "o"; return t }
        let grouped = ImportedTrade.groupedByOrder(both)
        #expect(grouped.count == 1 && grouped[0].feeQuote == 0.3 && grouped[0].feeUnpriced == ["ETH"] && grouped[0].netAmount == 20.3)
    }

    @Test func binanceHourlyOpenReadsTheKline() async {
        let api = BinanceAccountAPI(send: { request in
            #expect(request.url?.absoluteString.contains("symbol=BNBUSDT&interval=1h&startTime=1699999200000") == true)
            return (Data(#"[[1699999200000,"612.5","620","610","615","1",1700002799999,"1",1,"1","1","0"]]"#.utf8), 200)
        })
        #expect(await api.hourlyOpen(symbol: "BNBUSDT", at: Date(timeIntervalSince1970: 1_700_000_000)) == 612.5)
    }
}

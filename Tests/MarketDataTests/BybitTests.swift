import Domain
import Foundation
import Testing
@testable import MarketData

@Suite struct BybitTests {
    let creds = APICredentials(key: "KEY123", secret: "secret")
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    let gram = Instrument(base: "GRAM", quote: "USDT")

    func account(_ recorder: Recorder, _ reply: @escaping @Sendable (URLRequest) -> (String, Int)) -> BybitAccountAPI {
        BybitAccountAPI(now: { at }, send: { request in
            recorder.add(request)
            let (body, status) = reply(request)
            return (Data(body.utf8), status)
        })
    }

    func adapter(_ reply: @escaping @Sendable (URL) -> (String, Int)) -> BybitAdapter {
        BybitAdapter(fetch: { url in let (body, status) = reply(url); return (Data(body.utf8), status) })
    }

    func ok(_ result: String) -> String { #"{"retCode":0,"retMsg":"OK","result":\#(result),"time":1700000000123}"# }

    func exec(_ id: String, side: String = "Buy", qty: String = "10", value: String = "5", time: Int = 1_699_999_000_000, fee: String = "0.01", currency: String = "GRAM", type: String = "Trade") -> String {
        #"{"symbol":"GRAMUSDT","orderId":"o\#(id)","side":"\#(side)","execId":"\#(id)","execPrice":"0.5","execQty":"\#(qty)","execValue":"\#(value)","execTime":"\#(time)","execFee":"\#(fee)","feeCurrency":"\#(currency)","execType":"\#(type)","isMaker":false}"#
    }

    // Reference value computed independently (Python hmac) for the documented payload layout: timestamp+key+recvWindow+query.
    @Test func signatureIsHexHmacOverTimestampKeyRecvWindowAndQuery() {
        #expect(BybitSigner.sign(timestamp: "1658384314791", key: "KEY123", recvWindow: "5000", query: "category=spot&symbol=GRAMUSDT", secret: "secret")
                == "1946a6e59892b3c2b945d8672d8152cf7d3c16ed5ad867404c3b8abae879f62d")
    }

    @Test func requestsCarryTheDocumentedHeadersAndASignatureOfTheSentQuery() async throws {
        let rec = Recorder()
        _ = try await account(rec) { _ in (ok(#"{"readOnly":1,"permissions":{}}"#), 200) }.check(creds)
        let r = try #require(rec.requests.first)
        #expect(r.url?.absoluteString == "https://api.bybit.com/v5/user/query-api")
        #expect(r.value(forHTTPHeaderField: "X-BAPI-API-KEY") == "KEY123" && r.value(forHTTPHeaderField: "X-BAPI-TIMESTAMP") == "1700000000000")
        #expect(r.value(forHTTPHeaderField: "X-BAPI-SIGN") == BybitSigner.sign(timestamp: "1700000000000", key: "KEY123", recvWindow: "10000", query: "", secret: "secret"))
        let rec2 = Recorder()
        _ = try await account(rec2) { _ in (ok(#"{"list":[]}"#), 200) }.rawFills(creds, gram)
        let q = try #require(rec2.requests.first?.url?.query)
        #expect(rec2.requests.first?.value(forHTTPHeaderField: "X-BAPI-SIGN") == BybitSigner.sign(timestamp: "1700000000000", key: "KEY123", recvWindow: "10000", query: q, secret: "secret"))
    }

    @Test func aReadOnlyKeyPassesAndOneThatCanTradeOrWithdrawIsWarnedAbout() async throws {
        let readOnly = try await account(Recorder()) { _ in (ok(#"{"readOnly":1,"permissions":{"Spot":[],"Wallet":["AccountTransfer"]}}"#), 200) }.check(creds)
        #expect(readOnly == APIKeyCheck(warnings: [], readOnly: true))
        let risky = try await account(Recorder()) { _ in (ok(#"{"readOnly":0,"permissions":{"Spot":["SpotTrade"],"Wallet":["Withdraw"]}}"#), 200) }.check(creds)
        #expect(risky.readOnly == false && risky.warnings.contains("Withdrawals are enabled for this key") && risky.warnings.contains("Trading is enabled for this key"))
    }

    @Test func aRejectedKeyReportsBybitsMessageEvenOnHTTP200() async {
        await #expect(throws: BybitAPIError(status: 200, code: 10003, message: "API key is invalid.")) {
            _ = try await account(Recorder()) { _ in (#"{"retCode":10003,"retMsg":"API key is invalid.","result":{}}"#, 200) }.check(creds)
        }
        await #expect(throws: BybitAPIError.self) {
            _ = try await account(Recorder()) { _ in (#"{"retCode":10002,"retMsg":"timestamp"}"#, 403) }.check(creds)
        }
    }

    @Test func executionsBecomeTradesOldestFirstWithTheirFee() async throws {
        let body = ok(#"{"list":["# + [exec("2", side: "Sell", time: 1_699_999_500_000, fee: "0.005", currency: "USDT"), exec("1", fee: "0.01", currency: "GRAM")].joined(separator: ",") + "]}")
        let trades = try await account(Recorder()) { _ in (body, 200) }.trades(creds, gram)
        #expect(trades.map(\.externalID) == ["1", "2"]) // fills on a window's edge or repeated windows are not doubled
        #expect(trades[0].side == .buy && trades[0].quantity == 10 && trades[0].amount == 5 && trades[0].fees == ["GRAM": Decimal(string: "0.01")!] && trades[0].orderID == "o1")
        #expect(trades[1].side == .sell && trades[1].fees == ["USDT": Decimal(string: "0.005")!])
    }

    @Test func aMakerRebateAndNonTradeExecutionsAreNotImportedAsFeesOrFills() async throws {
        let body = ok(#"{"list":["# + [exec("1", fee: "-0.002"), exec("2", type: "Funding")].joined(separator: ",") + "]}")
        let trades = try await account(Recorder()) { _ in (body, 200) }.trades(creds, gram)
        #expect(trades.map(\.externalID) == ["1"] && trades[0].fees.isEmpty)
    }

    @Test func twoYearsOfSevenDayWindowsAreAsked() async throws {
        let rec = Recorder()
        _ = try await account(rec) { _ in (ok(#"{"list":[]}"#), 200) }.rawFills(creds, gram)
        #expect(rec.requests.count == 104)
        let spans = rec.requests.compactMap { r -> Int? in
            let items = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
            guard let s = items.first(where: { $0.name == "startTime" })?.value, let e = items.first(where: { $0.name == "endTime" })?.value else { return nil }
            return Int(e)! - Int(s)!
        }
        #expect(spans.count == 104 && spans.allSatisfy { $0 == 7 * 86_400_000 }) // never wider than the API allows
        #expect(rec.requests.allSatisfy { $0.url!.query!.contains("category=spot") && $0.url!.query!.contains("symbol=GRAMUSDT") })
    }

    @Test func aFullPageIsFollowedByCursorAndAFillSeenTwiceCountsOnce() async throws {
        let calls = Recorder()
        let raw = try await account(calls) { r in
            let query = r.url!.query!
            if query.contains("cursor=NEXT") { return (ok(#"{"list":["# + exec("2") + #"],"nextPageCursor":""}"#), 200) }
            // the first window the walk asks: a page with a cursor; the other windows repeat fill 1 (an edge fill)
            return (ok(#"{"list":["# + exec("1") + #"],"nextPageCursor":"\#(query.contains("endTime=1700000000000") ? "NEXT" : "")"}"#), 200)
        }.rawFills(creds, gram)
        #expect(Set(raw.map(\.id)) == ["1", "2"] && raw.count == 2)
        #expect(calls.requests.contains { $0.url!.query!.contains("cursor=NEXT") })
    }

    @Test func rawFillsParseBackToTheSameTrades() async throws {
        let body = ok(#"{"list":["# + [exec("1"), exec("2", side: "Sell", time: 1_699_999_500_000)].joined(separator: ",") + "]}")
        let api = account(Recorder()) { _ in (body, 200) }
        let raw = try await api.rawFills(creds, gram)
        #expect(raw.allSatisfy { $0.json.contains("\"feeCurrency\":\"GRAM\"") && $0.json.contains("\"execValue\"") }) // nothing dropped
        #expect(try raw.map(api.parse).sorted { $0.externalID < $1.externalID } == (try await api.trades(creds, gram)))
    }

    @Test func hourlyOpenReadsTheKline() async {
        let rec = Recorder()
        let api = account(rec) { _ in (ok(#"{"category":"spot","symbol":"BNBUSDT","list":[["1699999200000","612.5","620","610","615","1","600"]]}"#), 200) }
        #expect(await api.feeRate(asset: "BNB", quote: "USDT", at: Date(timeIntervalSince1970: 1_700_000_000)) == 612.5)
        #expect(rec.requests.first?.url?.query?.contains("symbol=BNBUSDT&interval=60&start=1699999200000") == true)
        #expect(await account(Recorder()) { _ in (#"{"retCode":10001,"retMsg":"params error"}"#, 200) }.feeRate(asset: "XYZ", quote: "USDT", at: at) == nil)
    }

    @Test func instrumentsListOnlyTradingPairsAndSupportsChecksStatus() async throws {
        let list = ok(#"{"category":"spot","list":[{"symbol":"GRAMUSDT","baseCoin":"GRAM","quoteCoin":"USDT","status":"Trading"},{"symbol":"OLDUSDT","baseCoin":"OLD","quoteCoin":"USDT","status":"Closed"}],"nextPageCursor":""}"#)
        let a = adapter { _ in (list, 200) }
        #expect(try await a.instruments() == [gram])
        #expect(try await a.supports(gram))
        #expect(try await a.supports(Instrument(base: "OLD", quote: "USDT")) == false)
        #expect(try await adapter { _ in (#"{"retCode":10001,"retMsg":"params error: symbol invalid"}"#, 200) }.supports(Instrument(base: "NO", quote: "USDT")) == false)
        await #expect(throws: (any Error).self) { _ = try await adapter { _ in ("", 500) }.supports(gram) }
    }

    @Test func snapshotAndSocketMessagesGivePriceOpenAndTime() throws {
        let tick = try BybitParsing.ticker(Data(ok(#"{"category":"spot","list":[{"symbol":"GRAMUSDT","lastPrice":"1.40","prevPrice24h":"1.30"}]}"#).utf8), now: at)
        #expect(tick.price == Decimal(string: "1.4")! && tick.open24h == Decimal(string: "1.3")! && tick.eventTime == Date(timeIntervalSince1970: 1_700_000_000.123))
        let msg = try BybitParsing.message(Data(#"{"topic":"tickers.GRAMUSDT","ts":1700000001000,"type":"snapshot","data":{"symbol":"GRAMUSDT","lastPrice":"1.41","prevPrice24h":"1.30"}}"#.utf8), symbol: "GRAMUSDT")
        #expect(msg.ticker?.price == Decimal(string: "1.41")! && msg.ticker?.eventTime == Date(timeIntervalSince1970: 1_700_000_001))
        #expect(try BybitParsing.message(Data(#"{"success":true,"ret_msg":"pong","op":"ping"}"#.utf8), symbol: "GRAMUSDT").ticker == nil)
        #expect(try BybitParsing.message(Data(#"{"topic":"tickers.OTHERUSDT","data":{"lastPrice":"9"}}"#.utf8), symbol: "GRAMUSDT").ticker == nil)
        #expect(try BybitParsing.message(Data(#"{"success":false,"ret_msg":"handler not found"}"#.utf8), symbol: "GRAMUSDT").error == "handler not found")
    }
}

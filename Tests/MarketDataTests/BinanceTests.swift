import Domain
import Foundation
import Testing
@testable import MarketData

@Suite struct BinanceParsingTests {
    // Recorded shape of a Binance @miniTicker message (E = event time in ms).
    let miniTicker = Data(#"{"e":"24hrMiniTicker","E":1672515782136,"s":"GRAMUSDT","c":"0.05512000","o":"0.05400000","h":"0.0560","l":"0.0530","v":"1000","q":"55"}"#.utf8)

    @Test func miniTickerGivesLastPriceOpenAndEventTime() throws {
        let tick = try #require(try BinanceParsing.miniTicker(miniTicker))
        #expect(tick.price == dec("0.05512"))
        #expect(tick.open24h == dec("0.054"))
        #expect(tick.eventTime == Date(timeIntervalSince1970: 1_672_515_782.136))
    }

    @Test func nonTickerMessagesAreIgnoredAndBadNumbersFail() throws {
        #expect(try BinanceParsing.miniTicker(Data(#"{"result":null,"id":1}"#.utf8)) == nil)
        #expect(throws: (any Error).self) {
            try BinanceParsing.miniTicker(Data(#"{"E":1,"c":"abc","o":"1"}"#.utf8))
        }
    }

    @Test func ticker24hGivesLastAndOpenPrice() throws {
        let body = Data(#"{"symbol":"GRAMUSDT","lastPrice":"0.05500000","openPrice":"0.05000000","volume":"1"}"#.utf8)
        let now = Date(timeIntervalSince1970: 5)
        let tick = try BinanceParsing.ticker24h(body, now: now)
        #expect(tick == PriceTick(price: dec("0.055"), open24h: dec("0.05"), eventTime: now))
    }

    @Test func exchangeInfoMustBeTradingAndSpotAllowed() throws {
        func info(_ status: String, spot: Bool) -> Data {
            Data(#"{"symbols":[{"symbol":"GRAMUSDT","status":"\#(status)","isSpotTradingAllowed":\#(spot)}]}"#.utf8)
        }
        #expect(try BinanceParsing.isTradableSpot(exchangeInfo: info("TRADING", spot: true), symbol: "GRAMUSDT"))
        #expect(!(try BinanceParsing.isTradableSpot(exchangeInfo: info("BREAK", spot: true), symbol: "GRAMUSDT")))
        #expect(!(try BinanceParsing.isTradableSpot(exchangeInfo: info("TRADING", spot: false), symbol: "GRAMUSDT")))
        #expect(!(try BinanceParsing.isTradableSpot(exchangeInfo: info("TRADING", spot: true), symbol: "OTHERUSDT")))
    }

    @Test func symbolIsBaseThenQuote() {
        #expect(BinanceParsing.symbol(gram) == "GRAMUSDT")
    }
}

@Suite struct BinanceAdapterTests {
    @Test func supportsTreatsHttp400AsNotListed() async throws {
        let adapter = BinanceAdapter(fetch: { _ in (Data(#"{"code":-1121,"msg":"Invalid symbol."}"#.utf8), 400) })
        #expect(try await adapter.supports(gram) == false)
    }

    @Test func snapshotRequestsTheRightSymbol() async throws {
        let seen = LockedBox<URL?>(nil)
        let adapter = BinanceAdapter(fetch: { url in
            seen.value = url
            return (Data(#"{"lastPrice":"0.055","openPrice":"0.05"}"#.utf8), 200)
        })
        let tick = try await adapter.snapshot(for: gram)
        #expect(tick.price == dec("0.055"))
        #expect(seen.value?.absoluteString == "https://data-api.binance.vision/api/v3/ticker/24hr?symbol=GRAMUSDT")
    }

    /// AC-3: needs the network. Run with LIVE_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_TESTS"] != nil), .timeLimit(.minutes(1)))
    func liveBinanceListsAndStreamsGramUsdt() async throws {
        let adapter = BinanceAdapter()
        #expect(try await adapter.supports(gram))
        let snap = try await adapter.snapshot(for: gram)
        #expect(snap.price > 0)
        var sawConnected = false
        for try await event in adapter.connect(to: gram) {
            if event == .connected { sawConnected = true }
            if case .tick(let t) = event { #expect(t.price > 0); break }
        }
        #expect(sawConnected)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@Suite struct CoinIconsTests {
    final class Calls: @unchecked Sendable { var urls: [String] = [] }

    @Test func fetchesOnceThenServesFromDiskAndSurvivesFailures() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "icons-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let calls = Calls()
        let catalog = #"{"data":[{"assetCode":"GRAM","logoUrl":"https://x/gram.png"},{"assetCode":"NOLOGO"}]}"#
        let fetch: CoinIcons.Fetch = { url in
            calls.urls.append(url.absoluteString)
            return url.lastPathComponent == "gram.png" ? (Data([1, 2, 3]), 200) : (Data(catalog.utf8), 200)
        }
        let icons = CoinIcons(directory: dir, fetch: fetch)
        #expect(await icons.data(for: "gram") == Data([1, 2, 3]))
        #expect(await CoinIcons(directory: dir, fetch: { _ in throw URLError(.notConnectedToInternet) }).data(for: "GRAM") == Data([1, 2, 3]))
        #expect(await icons.data(for: "NOLOGO") == nil)
        #expect(await icons.data(for: "UNKNOWN") == nil)
        #expect(calls.urls.count == 2) // catalog once + the image once
        #expect(await CoinIcons(directory: nil, fetch: { _ in throw URLError(.timedOut) }).data(for: "BTC") == nil)
    }
}

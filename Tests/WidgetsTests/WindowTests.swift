import Domain
import Foundation
import MarketData
import Persistence
import Security
import SwiftUI
import Testing
@testable import Widgets

/// UI tests on real (off-screen) windows: keys, clicks, focus, sizes. With SNAPSHOT_DIR set they also save the screen gallery.

/// All window tests share one app and one run loop: they must never run at the same time.
@MainActor @Suite(.serialized) enum UITests {}

extension UITests {
@MainActor @Suite(.timeLimit(.minutes(2)), .serialized) struct NewTradeWindowTests {
    let pairs: Set<Instrument> = [
        Instrument(base: "GRAM", quote: "USDT"), Instrument(base: "GRAM", quote: "USDC"), Instrument(base: "BTC", quote: "USDT"),
    ]

    func open(created: @escaping (NewTradeRequest) -> Void = { _ in }, cancelled: @escaping () -> Void = {}) async -> (TestWindow, NewTradeModel) {
        let model = NewTradeModel(adapters: [FakeExchange(id: "binance", listed: pairs), FakeExchange(id: "poloniex", listed: pairs)],
                                  defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let window = TestWindow(NewTradeView(model: model, onCreate: created, onCancel: cancelled))
        await model.loadInstruments()
        window.settle()
        return (window, model)
    }

    @Test func theCursorIsInThePairFieldWhenTheWindowOpens() async throws {
        let (window, _) = await open()
        let field = try #require(window.textField())
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.delegate === field)
        window.snapshot("window-new-trade-empty")
    }

    @Test func theOpenListFloatsOverTheWindowWithoutResizingIt() async throws {
        let (window, _) = await open()
        let before = window.size
        window.type("gram", into: try #require(window.textField()))
        #expect(window.size == before)
        window.snapshot("window-new-trade-list")
        window.press(.escape)
        #expect(window.size == before)
    }

    @Test func arrowsMoveTheHighlightAndReturnPicksThePair() async throws {
        let (window, model) = await open()
        window.type("gram", into: try #require(window.textField()))
        window.press(.down)
        window.press(.returnKey)
        #expect(model.pairText == "GRAM/USDC") // second suggestion
        window.snapshot("window-new-trade-picked")
    }

    @Test func upStopsAtTheFirstPairAndReturnPicksIt() async throws {
        let (window, model) = await open()
        window.type("gram", into: try #require(window.textField()))
        window.press(.up); window.press(.up)
        window.press(.returnKey)
        #expect(model.pairText == "GRAM/USDT")
    }

    @Test func escapeClosesTheListAndKeepsWhatWasTyped() async throws {
        let (window, model) = await open()
        window.type("gram", into: try #require(window.textField()))
        window.press(.escape)
        #expect(model.pairText == "gram")
        window.press(.returnKey) // list closed: Return must not pick anything
        #expect(model.pairText == "gram")
    }

    @Test func aClickOnEmptySpaceClosesTheList() async throws {
        let (window, model) = await open()
        window.type("gram", into: try #require(window.textField()))
        window.click(x: window.size.width / 2, y: 6) // the card's padding
        window.press(.returnKey)
        #expect(model.pairText == "gram") // the list was closed, so Return picked nothing
    }

    @Test func createBuyAndCreateSellSetTheDirection() async throws {
        let box = Box<[NewTradeRequest]>([])
        let (window, model) = await open(created: { box.value.append($0) })
        window.type("gram/usdt", into: try #require(window.textField()))
        window.press(.escape)
        window.click(x: window.size.width / 2, y: window.size.height - 31) // middle button: Create BUY
        try await Task.sleep(for: .milliseconds(400)) // lets the validation Task run
        window.click(x: window.size.width - 64, y: window.size.height - 31) // right button: Create SELL
        try await Task.sleep(for: .milliseconds(400))
        #expect(box.value.map(\.direction) == [.buyFirst, .sellFirst])
        #expect(box.value.allSatisfy { $0.instrument == Instrument(base: "GRAM", quote: "USDT") && $0.exchange == "binance" })
        _ = model
    }

    @Test func cancelButtonCloses() async throws {
        let box = Box(0)
        let (window, _) = await open(cancelled: { box.value += 1 })
        window.click(x: 64, y: window.size.height - 31)
        window.settle(0.2)
        #expect(box.value == 1)
    }

    @Test func switchingToPoloniexLoadsItsPairs() async throws {
        let (window, model) = await open()
        model.exchange = "poloniex"
        await model.loadInstruments()
        window.settle()
        #expect(model.instruments.count == 3)
        window.snapshot("window-new-trade-poloniex")
    }
}


/// Sticker layout with extreme digit counts: the window must keep its size and every number must be drawn (see the gallery).
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

extension UITests {
@MainActor @Suite(.timeLimit(.minutes(2)), .serialized) struct StickerLayoutTests {
    struct Case: Sendable {
        let name: String, base: String, quote: String, direction: Direction
        let txs: [(Side, String, String)]
        let price: String, open: String
    }

    static let cases: [Case] = [
        Case(name: "normal", base: "GRAM", quote: "USDT", direction: .buyFirst, txs: [(.buy, "1000", "50"), (.buy, "500", "30")], price: "0.055", open: "0.0532"),
        Case(name: "tiny-price", base: "SHIB", quote: "USDT", direction: .buyFirst, txs: [(.buy, "1234567890", "12.34")], price: "0.00001234", open: "0.00001100"),
        Case(name: "huge-price", base: "BTC", quote: "USDT", direction: .buyFirst, txs: [(.buy, "0.12345678", "10000.50")], price: "98765.43", open: "90000.12"),
        Case(name: "huge-qty-amount", base: "PEPE", quote: "USDT", direction: .buyFirst, txs: [(.buy, "98765432101.5", "123456789.12")], price: "0.0000123", open: "0.00001"),
        Case(name: "big-profit", base: "BTC", quote: "USDT", direction: .buyFirst, txs: [(.buy, "100", "1000")], price: "123456.78", open: "100"),
        Case(name: "big-loss", base: "ETH", quote: "USDT", direction: .buyFirst, txs: [(.buy, "1000", "9999999.99")], price: "0.01", open: "9999"),
        Case(name: "sell-first", base: "SOL", quote: "USDT", direction: .sellFirst, txs: [(.sell, "2000.5", "110000.25")], price: "58.123456", open: "59"),
        Case(name: "long-pair", base: "1000SATS", quote: "FDUSD", direction: .buyFirst, txs: [(.buy, "999999999", "5")], price: "0.0000005", open: "0.0000004"),
        Case(name: "btc-quote", base: "ETH", quote: "BTC", direction: .buyFirst, txs: [(.buy, "12.5", "0.54321098")], price: "0.0543", open: "0.0540"),
        Case(name: "zero-ish", base: "GRAM", quote: "USDT", direction: .buyFirst, txs: [(.buy, "0.00000001", "0.00000001")], price: "0.00000001", open: "0.00000001"),
    ]

    func sticker(_ c: Case, exchange: String = "binance") async throws -> (TestWindow, StickerModel) {
        let store = try TradeStore.inMemory()
        let fake = FakeExchange(id: exchange)
        let trade = try store.createTrade(exchange: exchange, base: c.base, quote: c.quote, direction: c.direction)
        var t = Date().addingTimeInterval(-7200)
        for tx in c.txs {
            try store.addTransaction(tradeID: trade.id, side: tx.0, quantity: dec(tx.1), amount: dec(tx.2), occurredAt: t)
            t.addTimeInterval(600)
        }
        let model = StickerModel(trade: trade, store: store, hub: MarketDataHub(adapters: [fake]), throttle: .milliseconds(1))
        model.reload()
        await model.refreshSubscription()
        await waitUntil { fake.connectCount == 1 }
        fake.emit(PriceTick(price: dec(c.price), open24h: dec(c.open), eventTime: Date()))
        await waitUntil { model.currentPrice != nil }
        try await Task.sleep(for: .milliseconds(60))
        let window = TestWindow(StickerView(model: model, actions: StickerActions(hide: {}, delete: {})))
        return (window, model)
    }

    @Test func everyDigitCountKeepsTheStickerTheSameSize() async throws {
        var sizes: [String: CGSize] = [:]
        for c in Self.cases {
            let (window, _) = try await sticker(c)
            sizes[c.name] = window.size
            window.snapshot("layout-\(c.name)")
        }
        let reference = try #require(sizes["normal"])
        for (name, size) in sizes { #expect(size == reference, "\(name): \(size) vs \(reference)") }
    }

    @Test func reconnectingDoesNotResizeTheSticker() async throws {
        let (window, _) = try await sticker(Self.cases[0])
        let connected = window.size
        window.snapshot("window-sticker-connected")
        let store = try TradeStore.inMemory()
        let fake = FakeExchange(id: "binance")
        let trade = try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: .buyFirst)
        try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 100, amount: 5, occurredAt: Date().addingTimeInterval(-60))
        let model = StickerModel(trade: trade, store: store, hub: MarketDataHub(adapters: [fake]), throttle: .milliseconds(1))
        model.reload(); await model.refreshSubscription()
        await waitUntil { fake.connectCount == 1 }
        fake.emit(PriceTick(price: dec("0.055"), open24h: dec("0.05"), eventTime: Date()))
        await waitUntil { model.currentPrice != nil }
        let live = TestWindow(StickerView(model: model, actions: StickerActions(hide: {}, delete: {})))
        let before = live.size
        fake.drop()
        await waitUntil { model.price.connection != .connected }
        try await Task.sleep(for: .milliseconds(100))
        live.settle()
        live.snapshot("window-sticker-reconnecting")
        #expect(live.size == before)
        #expect(before == connected)
    }
}
}

extension UITests {
@MainActor @Suite(.timeLimit(.minutes(2)), .serialized) struct DialogWindowTests {
    func keysModel(_ exchange: String, check: @escaping @Sendable (APICredentials) async throws -> APIKeyCheck) -> APIKeysModel {
        APIKeysModel(exchange: exchange, store: InMemoryCredentialStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!, check: check)
    }

    @Test func apiKeysKeepsItsSizeWhileCheckingAndShowsEachExchange() async throws {
        let slow = keysModel("binance") { _ in try await Task.sleep(for: .milliseconds(500)); return APIKeyCheck(readOnly: true) }
        let polo = keysModel("poloniex") { _ in APIKeyCheck() }
        let window = TestWindow(APIKeysView(models: [slow, polo], onClose: {}))
        let idle = window.size
        window.snapshot("window-api-keys-empty")
        slow.keyText = "KEY"; slow.secretText = "SECRET"
        let check = Task { await slow.test() }
        try await Task.sleep(for: .milliseconds(150))
        window.settle()
        window.snapshot("window-api-keys-checking")
        #expect(window.size == idle, "\(window.size) vs \(idle)")
        await check.value
        window.settle()
        window.snapshot("window-api-keys-connected")
        #expect(slow.connected && window.size == idle)

        let poloWindow = TestWindow(APIKeysView(models: [slow, polo], initial: "poloniex", onClose: {}))
        poloWindow.snapshot("window-api-keys-poloniex")
        #expect(poloWindow.size == idle)
    }

    @Test func savingAKeyClosesTheWindow() async throws {
        let model = keysModel("binance") { _ in APIKeyCheck(readOnly: true) }
        let box = Box(0)
        let window = TestWindow(APIKeysView(models: [model], onClose: { box.value += 1 }))
        model.keyText = "KEY"; model.secretText = "SECRET"
        window.click(x: 600 - 14 - 30, y: window.size.height - 31) // Save: the last button of the bottom row
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.status == .ok("Saved") && box.value == 1)
    }

    @Test func aKeychainThatRefusesIsReportedNotTreatedAsNoKey() async throws {
        struct Refusing: CredentialStore {
            func load(exchange: String) throws -> APICredentials? { throw KeychainError(status: errSecAuthFailed) }
            func save(_ credentials: APICredentials, exchange: String) throws {}
            func remove(exchange: String) throws {}
        }
        let model = APIKeysModel(exchange: "binance", store: Refusing(), defaults: UserDefaults(suiteName: UUID().uuidString)!, check: { _ in APIKeyCheck() })
        guard case .failed(let text) = model.status else { Issue.record("no error shown"); return }
        #expect(text.contains("Keychain refused"))
        let window = TestWindow(APIKeysView(models: [model], onClose: {}))
        window.snapshot("window-api-keys-keychain-refused")
    }

    @Test func apiKeysShowsAFailedCheck() async throws {
        let bad = keysModel("poloniex") { _ in throw PoloniexAPIError(status: 401, code: 21001, message: "Invalid API key") }
        let window = TestWindow(APIKeysView(models: [bad], onClose: {}))
        let idle = window.size
        bad.keyText = "KEY"; bad.secretText = "SECRET"
        await bad.test()
        window.settle()
        window.snapshot("window-api-keys-failed")
        #expect(bad.status == .failed("Invalid API key (21001)"))
        #expect(window.size == idle, "\(window.size) vs \(idle)")
    }

    func fills() -> [ImportedTrade] {
        func fill(_ id: Int, _ order: String, _ side: Side, _ qty: Decimal, _ amt: Decimal, _ t: Double) -> ImportedTrade {
            ImportedTrade(externalID: String(id), side: side, quantity: qty, amount: amt, occurredAt: Date(timeIntervalSinceNow: -t), orderID: order, fees: ["BNB": Decimal(string: "0.0004")!])
        }
        return [fill(1, "a", .buy, 298.5, 399.99, 90000), fill(2, "b", .buy, 400, 536, 3000), fill(3, "b", .buy, 100, 134, 2990), fill(4, "c", .sell, 200, 280, 100)]
    }

    @Test func importShowsALoaderThenTheTableInTheSameWindowSize() async throws {
        let rows = fills()
        let model = ImportModel(title: "Import from Binance", pair: "GRAM / USDT", quote: "USDT",
                                fetch: { try await Task.sleep(for: .milliseconds(1500)); return rows },
                                existing: { ["1"] }, commit: { _ in nil })
        let window = TestWindow(ImportView(model: model, onClose: {}))
        let size = window.size
        try await Task.sleep(for: .milliseconds(150))
        window.settle()
        #expect(model.state == .loading)
        window.snapshot("window-import-loading")
        try await Task.sleep(for: .milliseconds(1800))
        window.settle()
        #expect(model.state == .loaded && model.rows.count == 3) // two fills of order b are one row
        window.snapshot("window-import-loaded")
        model.selectAll()
        #expect(model.selection.count == 2) // the old fill is "added" and cannot be picked again
        window.settle()
        window.snapshot("window-import-selected")
        model.filter = .newOnly
        window.settle()
        window.snapshot("window-import-new-only")
        #expect(window.size == size)
    }

    @Test func importShowsAFailureAndAnEmptyList() async throws {
        let failing = ImportModel(title: "Import from Poloniex", pair: "GRAM / USDT", quote: "USDT",
                                  fetch: { throw PoloniexAPIError(status: 401, code: nil, message: "Invalid API key") },
                                  existing: { [] }, commit: { _ in nil })
        let window = TestWindow(ImportView(model: failing, onClose: {}))
        let size = window.size
        try await Task.sleep(for: .milliseconds(300))
        window.settle()
        #expect(failing.state == .failed("Invalid API key"))
        window.snapshot("window-import-failed")
        let empty = ImportModel(title: "Import from Poloniex", pair: "GRAM / USDT", quote: "USDT", fetch: { [] }, existing: { [] }, commit: { _ in nil })
        let emptyWindow = TestWindow(ImportView(model: empty, onClose: {}))
        try await Task.sleep(for: .milliseconds(300))
        emptyWindow.settle()
        emptyWindow.snapshot("window-import-empty")
        #expect(window.size == size && emptyWindow.size == size)
    }
}
}

extension UITests {
@MainActor @Suite(.timeLimit(.minutes(2)), .serialized) struct StickerStatesGalleryTests {
    @Test func stickerStatesAreDrawnAndKeepTheirWidth() async throws {
        let layout = UITests.StickerLayoutTests()
        let (window, model) = try await layout.sticker(UITests.StickerLayoutTests.cases[0], exchange: "poloniex")
        let width = window.size.width
        window.snapshot("window-sticker-live")
        model.openForm(side: .buy)
        model.edit(.quantity, "300"); model.edit(.rate, "0.06")
        window.settle()
        window.snapshot("window-sticker-form")
        #expect(window.size.width == width)
        model.cancelForm()
        model.setExpanded(true)
        window.settle()
        window.snapshot("window-sticker-list")
        #expect(window.size.width == width)
    }

    @Test func importedFeesAreShownInTheHistoryWithoutChangingTheWidth() async throws {
        let layout = UITests.StickerLayoutTests()
        let (window, model) = try await layout.sticker(UITests.StickerLayoutTests.cases[0])
        model.setExpanded(true)
        window.settle()
        let width = window.size.width
        var buy = ImportedTrade(externalID: "f1", side: .buy, quantity: 1000, amount: 54, occurredAt: Date().addingTimeInterval(-300))
        buy.feeQuote = 0.054
        var sell = ImportedTrade(externalID: "f2", side: .sell, quantity: 100, amount: 5.6, occurredAt: Date().addingTimeInterval(-100))
        sell.feeQuote = 0.0056
        #expect(model.importTrades([buy, sell]) == nil)
        window.settle()
        let list = TestWindow(TransactionList(model: model).padding(10).frame(width: ListDrawer.width).background(Color(white: 0.12)).environment(\.colorScheme, .dark))
        list.snapshot("window-history-fees")
        #expect(list.size.width == ListDrawer.width)
        #expect(window.size.width == width)
        #expect(model.transactions.compactMap(\.fee).count == 2)
    }

    @Test func anEmptyStickerShowsZerosNotAnAddButton() async throws {
        let c = UITests.StickerLayoutTests.Case(name: "empty", base: "GRAM", quote: "USDT", direction: .buyFirst, txs: [], price: "0.055", open: "0.05")
        let (window, model) = try await UITests.StickerLayoutTests().sticker(c)
        window.snapshot("window-sticker-empty")
        #expect(model.status == .empty)
        #expect(window.size.width == StickerView.width)
        let (normal, _) = try await UITests.StickerLayoutTests().sticker(UITests.StickerLayoutTests.cases[0])
        #expect(window.size == normal.size, "empty \(window.size) vs normal \(normal.size)")
    }
}
}


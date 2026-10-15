import Domain
import Foundation
import MarketData
import Persistence
import Presentation
import Testing
@testable import Widgets

func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
func at(_ minute: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60) }
let nowFixed = at(100)

@MainActor
func waitUntil(_ condition: () -> Bool) async {
    while !condition() { try? await Task.sleep(for: .milliseconds(2)) }
}

@MainActor
struct Fixture {
    let store: TradeStore
    let fake: FakeExchange
    let hub: MarketDataHub
    let model: StickerModel

    init(direction: Direction = .buyFirst) throws {
        store = try TradeStore.inMemory()
        fake = FakeExchange(id: "fake")
        hub = MarketDataHub(adapters: [fake], sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
        let trade = try store.createTrade(exchange: "fake", base: "GRAM", quote: "USDT", direction: direction)
        model = StickerModel(trade: trade, store: store, hub: hub, throttle: .milliseconds(1), clock: { nowFixed })
    }

    func add(_ side: Side, _ q: String, _ a: String, minute: Int) throws {
        try store.addTransaction(tradeID: model.trade.id, side: side, quantity: dec(q), amount: dec(a), occurredAt: at(minute))
        model.reload()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct StickerModelTests {
    @Test func durationRunsToNowWhileOpenAndStopsAtLastTransactionWhenClosed() throws {
        let f = try Fixture()
        #expect(f.model.duration(at: at(50)) == nil)
        try f.add(.buy, "100", "10", minute: 10)
        #expect(f.model.duration(at: at(40)) == TimeInterval(30 * 60))
        try f.add(.sell, "100", "12", minute: 20)
        #expect(f.model.status == .closed)
        #expect(f.model.duration(at: at(500)) == TimeInterval(10 * 60))
    }

    @Test func editingReplacesTheTransactionAndRejectsBreakingEdits() async throws {
        let f = try Fixture()
        try f.add(.buy, "100", "10", minute: 1)
        try f.add(.sell, "60", "9", minute: 2)
        let buy = f.model.transactions.first { $0.side == .buy }!
        f.model.openEditForm(id: buy.id)
        #expect(f.model.form?.quantityText == "100" && f.model.editingID == buy.id)
        f.model.edit(.quantity, "50") // sell of 60 would exceed the open quantity
        await f.model.submit()
        #expect(f.model.formError != nil && f.model.form != nil)
        f.model.edit(.quantity, "80")
        f.model.edit(.amount, "12")
        await f.model.submit()
        #expect(f.model.form == nil && f.model.editingID == nil)
        #expect(f.model.transactions.count == 2)
        #expect(f.model.transactions.first { $0.id == buy.id }?.amount == 12)
        #expect(f.model.summary.boughtQuantity == 80)
    }

    @Test func emptyTradeSubscribesAndShowsNoPnL() async throws {
        let f = try Fixture()
        #expect(f.model.status == .empty)
        await f.model.refreshSubscription()
        #expect(await f.hub.activeFeedCount == 1) // EMPTY needs the price to suggest a rate (spec 8.3)
    }

    @Test func livePriceDrivesPnLExampleA() async throws {
        let f = try Fixture()
        try f.add(.buy, "1000", "50", minute: 1)
        try f.add(.buy, "500", "30", minute: 2)
        try f.add(.sell, "600", "40", minute: 3)
        await f.model.refreshSubscription()
        await waitUntil { f.fake.connectCount == 1 }
        #expect(f.model.pnl.total == nil) // price unknown: no total yet (FR-PRICE-6)
        #expect(f.model.pnl.realized == 8)

        f.fake.emit(PriceTick(price: dec("0.055"), eventTime: at(1)))
        await waitUntil { f.model.currentPrice == dec("0.055") }
        #expect(f.model.pnl.total == dec("9.5"))
        #expect(f.model.pnl.ratio == dec("0.11875"))
    }

    @Test func closedTradeAndHiddenWindowDoNotSubscribe() async throws {
        let f = try Fixture()
        try f.add(.buy, "100", "10", minute: 1)
        await f.model.refreshSubscription()
        #expect(await f.hub.activeFeedCount == 1)

        await f.model.setVisible(false)
        #expect(await f.hub.activeFeedCount == 0)
        await f.model.setVisible(true)
        #expect(await f.hub.activeFeedCount == 1)

        f.model.openCloseForm()
        f.model.edit(.amount, "12")
        await f.model.submit() // sells everything: CLOSED
        #expect(f.model.status == .closed)
        #expect(await f.hub.activeFeedCount == 0)
        #expect(f.model.pnl.realized == 2)

        f.model.openForm(side: .buy)
        f.model.edit(.quantity, "5")
        f.model.edit(.amount, "1")
        await f.model.submit() // reopens
        #expect(f.model.status == .open)
        #expect(await f.hub.activeFeedCount == 1)
    }

    @Test func closeFormPrefillsWholeQuantityAtCurrentPrice() async throws {
        let f = try Fixture()
        try f.add(.buy, "900", "48", minute: 1)
        await f.model.refreshSubscription()
        await waitUntil { f.fake.connectCount == 1 }
        f.fake.emit(PriceTick(price: dec("0.055"), eventTime: at(1)))
        await waitUntil { f.model.currentPrice != nil }

        f.model.openCloseForm()
        #expect(f.model.form?.side == .sell)
        #expect(f.model.form?.quantity == 900)
        #expect(f.model.form?.amount == dec("49.5"))
        #expect(f.model.canSave)
    }

    @Test func closeFormWithoutPriceStillFillsQuantity() throws {
        let f = try Fixture(direction: .sellFirst)
        try f.add(.sell, "10", "1", minute: 1)
        f.model.openCloseForm()
        #expect(f.model.form?.side == .buy) // Sell-first closes with a buy
        #expect(f.model.form?.quantity == 10)
        #expect(!f.model.canSave) // needs an amount
    }

    @Test func oversellKeepsTheFormOpenAndExplainsWhy() async throws {
        let f = try Fixture()
        try f.add(.buy, "100", "10", minute: 1)
        f.model.openForm(side: .sell)
        f.model.edit(.quantity, "150")
        f.model.edit(.amount, "15")
        await f.model.submit()
        #expect(f.model.form != nil)
        #expect(f.model.formError == "Not enough open quantity: only 100.00 available")
        #expect(f.model.transactions.count == 1)

        f.model.edit(.quantity, "50")
        #expect(f.model.formError == nil) // editing clears the error
    }

    @Test func invalidFormCannotBeSubmitted() async throws {
        let f = try Fixture()
        f.model.openForm(side: .buy)
        f.model.edit(.quantity, "abc")
        f.model.edit(.amount, "5")
        #expect(!f.model.canSave)
        #expect(f.model.formProblems == [.quantityInvalid])
        await f.model.submit()
        #expect(f.model.transactions.isEmpty)
    }

    @Test func deletingAnOpeningTransactionThatSellsDependOnIsRefused() async throws {
        let f = try Fixture()
        try f.add(.buy, "100", "10", minute: 1)
        try f.add(.sell, "50", "6", minute: 2)
        let buy = try #require(f.model.transactions.first)
        await f.model.deleteTransaction(id: buy.id)
        #expect(f.model.transactions.count == 2)
        #expect(f.model.listError?.hasPrefix("Not enough open quantity at ") == true)

        let sell = try #require(f.model.transactions.last)
        await f.model.deleteTransaction(id: sell.id)
        #expect(f.model.transactions.count == 1)
        #expect(f.model.listError == nil)
    }

    @Test func expandedStateIsPersisted() throws {
        let f = try Fixture()
        f.model.setExpanded(true)
        #expect(try f.store.trade(id: f.model.trade.id)?.isExpanded == true)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct TransactionPnLTests {
    @Test func perTransactionPnLAddsUpToTheTradeTotal() async throws {
        let f = try Fixture()
        try f.add(.buy, "1000", "50", minute: 1)
        try f.add(.buy, "500", "30", minute: 2)
        try f.add(.sell, "600", "40", minute: 3)
        await f.model.refreshSubscription()
        await waitUntil { f.fake.connectCount == 1 }
        #expect(f.model.pnl(of: f.model.transactions[0]) == nil)
        f.fake.emit(PriceTick(price: dec("0.055"), open24h: nil, eventTime: Date()))
        await waitUntil { f.model.currentPrice != nil }
        let parts = f.model.transactions.map { f.model.pnl(of: $0)! }
        #expect(parts == [dec("5"), dec("-2.5"), dec("7")]) // 55-50, 27.5-30, 40-33
        #expect(parts.reduce(0, +) == f.model.pnl.total)
    }
}

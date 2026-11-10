import Domain
import Foundation
import MarketData
import Persistence
import Testing
@testable import Widgets

@MainActor @Suite(.timeLimit(.minutes(1))) struct StickerModelMoreTests {
    func fill(_ id: String, _ side: Side, _ qty: Decimal, _ amt: Decimal, minute: Int) -> ImportedTrade {
        ImportedTrade(externalID: id, side: side, quantity: qty, amount: amt, occurredAt: at(minute))
    }

    @Test func pinningIsRememberedAndReported() throws {
        let f = try Fixture()
        defer { UserDefaults.standard.removeObject(forKey: "pinned.\(f.model.trade.id.uuidString)") }
        var seen: [Bool] = []
        f.model.onPinChange = { seen.append($0) }
        f.model.togglePin(); f.model.togglePin(); f.model.togglePin()
        #expect(seen == [true, false, true] && f.model.isPinned)
    }

    @Test func theListToggleNeedsTransactionsAndHistoryButtonCallsBack() throws {
        let f = try Fixture()
        f.model.toggleList()
        #expect(!f.model.trade.isExpanded) // nothing to list
        try f.add(.buy, "100", "10", minute: 1)
        f.model.toggleList()
        #expect(f.model.trade.isExpanded)
        f.model.toggleList()
        #expect(!f.model.trade.isExpanded)
        var called = false
        f.model.onImportHistory = { called = true }
        f.model.importHistory()
        #expect(called)
    }

    @Test func anImportThatBreaksTheLedgerIsRefusedWithAHintAndWritesNothing() throws {
        let f = try Fixture()
        let message = f.model.importTrades([fill("1", .sell, 5, 5, minute: 1)])
        #expect(message?.hasSuffix(". Select the earlier trades too.") == true)
        #expect(f.model.transactions.isEmpty)
        #expect(f.model.importTrades([fill("1", .buy, 5, 5, minute: 1)]) == nil)
        #expect(f.model.transactions.count == 1)
    }

    @Test func recalculatingReportsChangesOrWhyItCannot() throws {
        let f = try Fixture()
        #expect(f.model.importTrades([fill("1", .buy, 10, 10, minute: 1), fill("2", .sell, 4, 6, minute: 2)]) == nil)
        #expect(f.model.reimportTrades([fill("1", .buy, 10, 10, minute: 1), fill("2", .sell, 4, 6, minute: 2)]).changed == 0)
        let changed = f.model.reimportTrades([fill("1", .buy, 10, 12, minute: 1), fill("2", .sell, 4, 6, minute: 2)])
        #expect(changed.changed == 1 && changed.error == nil)
        // a buy that no longer covers the sell: refused as a whole
        let refused = f.model.reimportTrades([fill("1", .buy, 2, 2, minute: 1), fill("2", .sell, 4, 6, minute: 2)])
        #expect(refused.changed == 0 && refused.error != nil)
    }

    @Test func ledgerMessagesNameTheProblem() throws {
        let f = try Fixture()
        #expect(StickerModel.message(for: .nonPositiveValue(transactionID: UUID()), transactions: []).contains("greater than 0"))
        try f.add(.buy, "10", "10", minute: 1)
        let id = try #require(f.model.transactions.first).id
        #expect(StickerModel.message(for: .closingExceedsOpen(transactionID: id, available: 3), transactions: f.model.transactions).contains("only 3"))
    }

    /// Two overlapping refreshes make one subscription, and hiding while one is in flight leaves none.
    @Test func overlappingRefreshesSubscribeOnce() async throws {
        let f = try Fixture()
        try f.add(.buy, "100", "10", minute: 1)
        f.model.reload()
        async let a: Void = f.model.refreshSubscription()
        async let b: Void = f.model.refreshSubscription()
        _ = await (a, b)
        await waitUntil { f.fake.connectCount >= 1 }
        #expect(f.fake.connectCount == 1)
        #expect(await f.hub.activeFeedCount == 1)
        await f.model.setVisible(false)
        #expect(await f.hub.activeFeedCount == 0)
    }

    @Test func theWhatIfPriceMovesByTheGivenShareAndNeverBelowAThousandth() async throws {
        let f = try Fixture()
        try f.add(.buy, "100", "10", minute: 1)
        f.model.reload()
        await f.model.refreshSubscription()
        await waitUntil { f.fake.connectCount >= 1 }
        f.fake.emit(PriceTick(price: 100, eventTime: nowFixed))
        await waitUntil { f.model.livePrice != nil }
        f.model.nudgePreview(by: 0.1, ended: false)
        #expect(f.model.previewPrice == 110)
        f.model.nudgePreview(by: -0.5, ended: false)
        #expect(f.model.previewPrice == 55) // from the previous preview, not from the live price
        f.model.nudgePreview(by: -1, ended: false)
        #expect(f.model.previewPrice == dec("0.55")) // at most -99 % per step
        f.model.nudgePreview(by: -1, ended: false)
        #expect(f.model.previewPrice == dec("0.1")) // the floor: live / 1000
        f.model.endPreview()
        #expect(f.model.previewPrice == nil && f.model.currentPrice == 100)
    }

    @Test func aMenuRowShowsSizeMoneyAndHowLongTheTradeRan() throws {
        let store = try TradeStore.inMemory()
        let trade = try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: .buyFirst)
        let t0 = at(0)
        let open = try TradeCalculator.summarize(direction: .buyFirst, transactions: [Transaction(side: .buy, quantity: 100, amount: 50, occurredAt: t0, sequence: 1)])
        var row = MenuRow.make(trade: trade, summary: open, times: [t0], now: t0.addingTimeInterval(2 * 86400 + 4 * 3600), icon: nil, shown: true)
        #expect(row.exchange == "Binance" && row.isBuy && row.shown && row.quantity == "100.00" && row.invested == "50.00")
        #expect(row.duration == "2d 4h")
        let closed = try TradeCalculator.summarize(direction: .buyFirst, transactions: [
            Transaction(side: .buy, quantity: 100, amount: 50, occurredAt: t0, sequence: 1), Transaction(side: .sell, quantity: 100, amount: 60, occurredAt: t0.addingTimeInterval(3600), sequence: 2)])
        row = MenuRow.make(trade: trade, summary: closed, times: [t0, t0.addingTimeInterval(3600)], now: t0.addingTimeInterval(9 * 86400), icon: nil, shown: false)
        #expect(row.quantity == "—" && row.duration == "1h") // closed: frozen at the last transaction
        let empty = MenuRow.make(trade: trade, summary: .empty(.buyFirst), times: [], now: t0, icon: nil, shown: false)
        #expect(empty.invested == "—" && empty.duration == nil)
    }

    /// The reason a save was refused stays until the user changes something; a field that merely re-reports its text does not clear it.
    @Test func aRefusedSaveKeepsItsReasonUntilSomethingChanges() async throws {
        let f = try Fixture()
        try f.add(.buy, "100", "10", minute: 1)
        f.model.reload()
        f.model.openForm(side: .sell)
        f.model.edit(.quantity, "500"); f.model.edit(.rate, "0.1")
        await f.model.submit()
        #expect(f.model.formError?.hasPrefix("Not enough open quantity") == true)
        f.model.edit(.quantity, "500") // the same text again
        #expect(f.model.formError != nil)
        f.model.edit(.quantity, "50") // a real change
        #expect(f.model.formError == nil)
    }

    @Test func aWhatIfPriceNeverReachesTheStore() async throws {
        let f = try Fixture()
        try f.add(.buy, "100", "10", minute: 1)
        f.model.reload()
        await f.model.refreshSubscription()
        await waitUntil { f.fake.connectCount >= 1 }
        f.fake.emit(PriceTick(price: 2, eventTime: nowFixed))
        await waitUntil { f.model.livePrice != nil }
        let before = try f.store.transactions(tradeID: f.model.trade.id)
        f.model.nudgePreview(by: 0.5, ended: true)
        f.model.endPreview()
        f.model.reload()
        #expect(try f.store.transactions(tradeID: f.model.trade.id) == before)
        #expect(f.model.currentPrice == 2 && f.model.pnl.total == 190) // 100 coins at 2 for a cost of 10
    }
}

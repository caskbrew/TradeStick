import Domain
import Foundation
import MarketData
import Persistence
import SwiftUI
import Testing
@testable import Widgets

/// Screen-gallery states that the other suites do not reach: a closed loss, compact variants, a form refused for lack of coins,
/// a long list, a large import with a partly added order.
extension UITests {
@MainActor @Suite(.timeLimit(.minutes(3)), .serialized) struct MoreStatesTests {
    let layout = UITests.StickerLayoutTests()
    let normal = UITests.StickerLayoutTests.cases[0]

    private func closedModel(sell: Decimal) throws -> StickerModel {
        let store = try TradeStore.inMemory()
        let trade = try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: .buyFirst)
        try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 1000, amount: 50, occurredAt: Date().addingTimeInterval(-7200))
        try store.addTransaction(tradeID: trade.id, side: .sell, quantity: 1000, amount: sell, occurredAt: Date().addingTimeInterval(-3600))
        let model = StickerModel(trade: trade, store: store, hub: MarketDataHub(adapters: [FakeExchange(id: "binance")]), throttle: .milliseconds(1))
        model.reload()
        return model
    }

    @Test func aClosedLossAndTheClosedCardCompact() async throws {
        let model = try closedModel(sell: 41)
        defer { UserDefaults.standard.removeObject(forKey: "compact.\(model.trade.id.uuidString)") }
        let window = TestWindow(StickerView(model: model, actions: StickerActions(hide: {}, delete: {})))
        window.settle(0.3)
        #expect(model.status == .closed && model.headline.total == -9)
        window.snapshot("window-sticker-closed-loss")
        model.toggleCompact()
        window.settle(0.5)
        window.snapshot("window-sticker-closed-compact")
        UserDefaults.standard.removeObject(forKey: "compact.\(model.trade.id.uuidString)")
    }

    @Test func theWhatIfPriceOnTheCompactCard() async throws {
        let (_, model) = try await layout.sticker(normal)
        model.toggleCompact()
        model.nudgePreview(by: -0.2, ended: false)
        let window = TestWindow(StickerView(model: model, actions: StickerActions(hide: {}, delete: {})))
        window.settle(0.5)
        #expect(model.isCompact && model.isPreviewing)
        window.snapshot("window-sticker-whatif-compact")
        model.endPreview()
        UserDefaults.standard.removeObject(forKey: "compact.\(model.trade.id.uuidString)")
    }

    @Test func aSellThatNeedsMoreCoinsThanAreOpen() async throws {
        let (_, model) = try await layout.sticker(normal)
        model.openForm(side: .sell)
        let window = TestWindow(FormWindowView(model: model))
        window.settle(0.4)
        model.edit(.quantity, "999999999"); model.edit(.rate, "0.05")
        await model.submit()
        window.settle(0.3)
        #expect(model.form != nil)
        #expect(model.formError?.hasPrefix("Not enough open quantity") == true) // the ledger refused it and says so in the form
        window.snapshot("window-form-sell-too-much")
    }

    @Test func aLongListScrolls() async throws {
        let store = try TradeStore.inMemory()
        let trade = try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: .buyFirst)
        for i in 0..<40 {
            try store.addTransaction(tradeID: trade.id, side: .buy, quantity: Decimal(100 + i), amount: Decimal(5 + i) / 10, occurredAt: Date().addingTimeInterval(Double(-90_000 + i * 60)))
        }
        let model = StickerModel(trade: trade, store: store, hub: MarketDataHub(adapters: [FakeExchange(id: "binance")]), throttle: .milliseconds(1))
        model.reload()
        model.setExpanded(true)
        let window = TestWindow(ListWindowView(model: model))
        window.settle(0.5)
        #expect(model.transactions.count == 40)
        window.snapshot("window-list-many")
        UserDefaults.standard.removeObject(forKey: "compact.\(trade.id.uuidString)")
    }

    @Test func aBigImportWithAPartlyAddedOrder() async throws {
        var built: [ImportedTrade] = []
        for i in 0..<60 {
            built.append(ImportedTrade(externalID: "f\(i)", side: i % 7 == 6 ? .sell : .buy, quantity: Decimal(100 + i), amount: Decimal(130 + i) / 1, occurredAt: Date(timeIntervalSinceNow: Double(-3_000_000 + i * 40_000)), orderID: i >= 58 ? "split" : "o\(i)", fees: ["BNB": Decimal(string: "0.0004")!]))
        }
        let rows = built
        let model = ImportModel(title: "Import from Binance", pair: "GRAM / USDT", quote: "USDT", fetch: { rows }, existing: { ["f58"] }, commit: { _ in nil })
        let window = TestWindow(ImportView(model: model, onClose: {}))
        await waitUntil { model.state == .loaded }
        window.settle(0.4)
        #expect(model.rows.contains { $0.partlyAdded })
        window.snapshot("window-import-large-partly")
    }
}
}

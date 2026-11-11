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

    /// A long list: the scroller must not take width from the columns (it would cut the last digits off).
    @Test func aLongListHasANarrowScrollerThatKeepsTheDigits() async throws {
        let long = UITests.StickerLayoutTests.Case(name: "long", base: "GRAM", quote: "USDT", direction: .buyFirst,
                                                   txs: (0..<30).map { (.buy, "\(100 + $0 * 37)", "\(5 + $0)") }, price: "0.055", open: "0.05")
        let (_, model) = try await layout.sticker(long)
        let window = TestWindow(TransactionList(model: model).frame(width: ListDrawer.width).background(Color(white: 0.12)).environment(\.colorScheme, .dark))
        window.settle(0.3)
        let scrollView = try #require(window.allViews().compactMap { $0 as? NSScrollView }.first)
        #expect(scrollView.scrollerStyle == .overlay && scrollView.contentView.bounds.width == window.size.width)
        window.snapshot("window-history-long")
    }

    /// Independent of the system's scroll bar setting: the thin scroller is forced, and forced again after the system's own reset.
    @Test func theOverlayScrollerIsForcedAndStaysForced() async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scroll.scrollerStyle = .legacy
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        document.addSubview(OverlayScroller.Probe())
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        #expect(scroll.scrollerStyle == .overlay)
        scroll.scrollerStyle = .legacy // what AppKit does when a mouse is plugged in
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(scroll.scrollerStyle == .overlay)
    }

    /// Deleting: open the row (a double-click), press the trash, answer the question.
    @Test func aTransactionIsDeletedFromItsEditFormAfterAnAnswer() async throws {
        let (_, model) = try await layout.sticker(normal)
        let first = try #require(model.transactions.first)
        model.openEditForm(id: first.id)
        let window = TestWindow(FormWindowView(model: model))
        window.settle(0.4)
        window.snapshot("window-form-edit-delete")
        let (width, height) = (window.size.width, window.size.height)
        let trash = CGPoint(x: 14 + 15, y: height - 27), cancel = CGPoint(x: width - 14 - 70, y: height - 27), delete = CGPoint(x: width - 14 - 25, y: height - 27)
        window.click(x: trash.x, y: trash.y)
        window.settle(0.3)
        window.snapshot("window-form-delete-confirm")
        window.click(x: cancel.x, y: cancel.y) // Cancel of the question: back to the form, nothing deleted
        window.settle(0.3)
        #expect(model.form != nil && model.editingID == first.id && model.transactions.count == 2)
        window.click(x: trash.x, y: trash.y)
        window.click(x: delete.x, y: delete.y)
        await waitUntil { model.transactions.count == 1 }
        #expect(model.transactions.count == 1 && model.form == nil && model.editingID == nil)
    }

    @Test func aDeletionTheLedgerRefusesIsExplainedInTheForm() async throws {
        let (_, model) = try await layout.sticker(UITests.StickerLayoutTests.Case(
            name: "x", base: "GRAM", quote: "USDT", direction: .buyFirst, txs: [(.buy, "100", "10"), (.sell, "50", "7")], price: "0.1", open: "0.1"))
        let buy = try #require(model.transactions.min { $0.occurredAt < $1.occurredAt })
        model.openEditForm(id: buy.id)
        let window = TestWindow(FormWindowView(model: model))
        window.settle(0.4)
        await model.deleteEditing()
        window.settle(0.3)
        #expect(model.transactions.count == 2 && model.form != nil && model.formError != nil)
        window.snapshot("window-form-delete-refused")
    }

    @Test func aNewTransactionsFormHasNoTrash() async throws {
        let (_, model) = try await layout.sticker(normal)
        model.openForm(side: .buy)
        let window = TestWindow(FormWindowView(model: model))
        window.settle(0.4)
        window.snapshot("window-form-add-no-delete")
        #expect(model.editingID == nil)
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

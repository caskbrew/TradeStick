import Domain
import Foundation
import MarketData
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
}

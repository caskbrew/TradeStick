import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

func d(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
func at(_ minute: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60) }

@Suite struct TradeStoreTests {
    func makeTrade(_ store: TradeStore, _ direction: Direction = .buyFirst) throws -> StoredTrade {
        try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: direction)
    }

    @Test func createdTradeIsReadBackWithDefaults() throws {
        let store = try TradeStore.inMemory()
        let created = try makeTrade(store, .sellFirst)
        let all = try store.trades()
        #expect(all == [created])
        #expect(all[0].isVisible && !all[0].isExpanded && all[0].position == nil)
        #expect(try store.trade(id: created.id) == created)
        #expect(try store.trade(id: UUID()) == nil)
    }

    @Test func decimalsRoundTripExactly() throws {
        let store = try TradeStore.inMemory()
        let trade = try makeTrade(store)
        try store.addTransaction(tradeID: trade.id, side: .buy, quantity: d("123456789.12345678"), amount: d("0.00000001"), occurredAt: at(1))
        let tx = try store.transactions(tradeID: trade.id)
        #expect(tx.count == 1)
        #expect(tx[0].quantity == d("123456789.12345678"))
        #expect(tx[0].amount == d("0.00000001"))
        #expect(tx[0].sequence == 1)
    }

    @Test func sequenceIncreasesAndOrderIsTimeThenSequence() throws {
        let store = try TradeStore.inMemory()
        let trade = try makeTrade(store)
        let a = try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 10, amount: 1, occurredAt: at(5))
        let b = try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 10, amount: 1, occurredAt: at(5))
        let c = try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 10, amount: 1, occurredAt: at(1))
        let sequences: [Int] = [a.sequence, b.sequence, c.sequence]
        #expect(sequences == [1, 2, 3])
        #expect(try store.transactions(tradeID: trade.id).map(\.id) == [c.id, a.id, b.id])
    }

    @Test func oversellIsRejectedAndNothingIsWritten() throws {
        let store = try TradeStore.inMemory()
        let trade = try makeTrade(store)
        try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 100, amount: 10, occurredAt: at(1))
        let error = #expect(throws: StoreError.self) {
            try store.addTransaction(tradeID: trade.id, side: .sell, quantity: 101, amount: 11, occurredAt: at(2))
        }
        guard case .ledger(.closingExceedsOpen(_, let available))? = error else {
            Issue.record("expected ledger error, got \(String(describing: error))"); return
        }
        #expect(available == 100)
        #expect(try store.transactions(tradeID: trade.id).count == 1)
    }

    @Test func backdatedSellBeforeBuyIsRejected() throws {
        let store = try TradeStore.inMemory()
        let trade = try makeTrade(store)
        try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 100, amount: 10, occurredAt: at(5))
        #expect(throws: StoreError.self) {
            try store.addTransaction(tradeID: trade.id, side: .sell, quantity: 50, amount: 6, occurredAt: at(1))
        }
        #expect(try store.transactions(tradeID: trade.id).count == 1)
    }

    @Test func deletingAnOpeningTransactionThatLaterSellsDependOnIsRejected() throws {
        let store = try TradeStore.inMemory()
        let trade = try makeTrade(store)
        let buy = try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 100, amount: 10, occurredAt: at(1))
        try store.addTransaction(tradeID: trade.id, side: .sell, quantity: 50, amount: 6, occurredAt: at(2))
        #expect(throws: StoreError.self) { try store.deleteTransaction(tradeID: trade.id, id: buy.id) }
        #expect(try store.transactions(tradeID: trade.id).count == 2)
    }

    @Test func deletingAClosingTransactionIsAllowed() throws {
        let store = try TradeStore.inMemory()
        let trade = try makeTrade(store)
        try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 100, amount: 10, occurredAt: at(1))
        let sell = try store.addTransaction(tradeID: trade.id, side: .sell, quantity: 50, amount: 6, occurredAt: at(2))
        try store.deleteTransaction(tradeID: trade.id, id: sell.id)
        #expect(try store.transactions(tradeID: trade.id).count == 1)
        #expect(throws: StoreError.transactionNotFound(sell.id)) { try store.deleteTransaction(tradeID: trade.id, id: sell.id) }
    }

    @Test func updateKeepsSequenceAndIsValidated() throws {
        let store = try TradeStore.inMemory()
        let trade = try makeTrade(store)
        try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 100, amount: 10, occurredAt: at(1))
        let sell = try store.addTransaction(tradeID: trade.id, side: .sell, quantity: 50, amount: 6, occurredAt: at(2))

        let updated = try store.updateTransaction(tradeID: trade.id, id: sell.id, side: .sell, quantity: 60, amount: 7, occurredAt: at(3))
        #expect(updated.sequence == sell.sequence)
        let stored = try store.transactions(tradeID: trade.id).last
        #expect(stored?.quantity == 60 && stored?.amount == 7)

        #expect(throws: StoreError.self) {
            try store.updateTransaction(tradeID: trade.id, id: sell.id, side: .sell, quantity: 101, amount: 7, occurredAt: at(3))
        }
        #expect(try store.transactions(tradeID: trade.id).last?.quantity == 60)
    }

    @Test func sellFirstTradeValidatesBuysAsClosing() throws {
        let store = try TradeStore.inMemory()
        let trade = try makeTrade(store, .sellFirst)
        try store.addTransaction(tradeID: trade.id, side: .sell, quantity: 100, amount: 6, occurredAt: at(1))
        #expect(throws: StoreError.self) {
            try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 101, amount: 5, occurredAt: at(2))
        }
    }

    @Test func unknownTradeIsReported() throws {
        let store = try TradeStore.inMemory()
        let id = UUID()
        #expect(throws: StoreError.tradeNotFound(id)) {
            try store.addTransaction(tradeID: id, side: .buy, quantity: 1, amount: 1, occurredAt: at(1))
        }
        #expect(throws: StoreError.tradeNotFound(id)) { try store.setVisible(id: id, false) }
        #expect(throws: StoreError.tradeNotFound(id)) { try store.deleteTrade(id: id) }
    }

    @Test func windowStateAndExchangeArePersisted() throws {
        let store = try TradeStore.inMemory()
        let trade = try makeTrade(store)
        try store.setVisible(id: trade.id, false)
        try store.setExpanded(id: trade.id, true)
        try store.setCompact(id: trade.id, true)
        try store.setPosition(id: trade.id, WindowPosition(x: 120.5, topY: 840))
        try store.setExchange(id: trade.id, exchange: "bybit")
        let read = try #require(try store.trade(id: trade.id))
        #expect(!read.isVisible && read.isExpanded && read.isCompact)
        #expect(read.position == WindowPosition(x: 120.5, topY: 840))
        #expect(read.exchange == "bybit")
        try store.setPosition(id: trade.id, nil)
        #expect(try store.trade(id: trade.id)?.position == nil)
    }

    @Test func deletingTradeCascadesToTransactionsAndSurvivesReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let keptID: UUID, goneID: UUID
        do {
            let store = try TradeStore(path: path)
            let kept = try makeTrade(store), gone = try makeTrade(store)
            keptID = kept.id; goneID = gone.id
            try store.addTransaction(tradeID: kept.id, side: .buy, quantity: 5, amount: 1, occurredAt: at(1))
            try store.addTransaction(tradeID: gone.id, side: .buy, quantity: 5, amount: 1, occurredAt: at(1))
            try store.deleteTrade(id: gone.id)
        }
        // Reopen the same file: data persisted, migrations are idempotent.
        let reopened = try TradeStore(path: path)
        #expect(try reopened.trades().map(\.id) == [keptID])
        #expect(try reopened.transactions(tradeID: keptID).count == 1)

        let orphans = try DatabaseQueue(path: path).read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tradeTransaction WHERE tradeID = ?", arguments: [goneID.uuidString])
        }
        #expect(orphans == 0)
    }

    @Test func databaseLivesInTradeStickiesFolderAndIsCreatedOnDemand() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("as-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let url = try TradeStore.databaseURL(inApplicationSupport: base)
        #expect(url.path == base.appendingPathComponent("TradeStickies/tradestickies.sqlite").path)
        let store = try TradeStore(path: url.path) // the folder exists, so SQLite can create the file
        _ = try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: .buyFirst)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

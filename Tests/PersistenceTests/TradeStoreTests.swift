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

    @Test func databaseLivesInTradeStickFolderAndIsCreatedOnDemand() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("as-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let url = try TradeStore.databaseURL(inApplicationSupport: base)
        #expect(url.path == base.appendingPathComponent("TradeStick/tradestick.sqlite").path)
        let store = try TradeStore(path: url.path) // the folder exists, so SQLite can create the file
        _ = try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: .buyFirst)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite struct KeychainCredentialStoreTests {
    @Test func roundTripsThroughTheRealKeychain() throws {
        let store = KeychainCredentialStore(service: "com.caskbrew.tradestick.tests.\(UUID().uuidString)")
        defer { try? store.remove(exchange: "binance") }
        #expect(try store.load(exchange: "binance") == nil)
        try store.save(APICredentials(key: "K1", secret: "S1"), exchange: "binance")
        try store.save(APICredentials(key: "K2", secret: "S2"), exchange: "binance") // replaces
        #expect(try store.load(exchange: "binance") == APICredentials(key: "K2", secret: "S2"))
        try store.remove(exchange: "binance")
        #expect(try store.load(exchange: "binance") == nil)
        try store.remove(exchange: "binance") // removing nothing is fine
    }
}

@Suite struct ImportTradesTests {
    func fill(_ id: String, _ side: Side, _ qty: Decimal, _ amt: Decimal, _ minute: Int) -> ImportedTrade {
        ImportedTrade(externalID: id, side: side, quantity: qty, amount: amt, occurredAt: at(minute))
    }

    @Test func importsInTimeOrderAndSkipsWhatWasImportedBefore() throws {
        let store = try TradeStore.inMemory()
        let trade = try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: .buyFirst)
        // Given out of order: the ledger must still see the buy first.
        #expect(try store.importTrades(tradeID: trade.id, [fill("2", .sell, 5, 3, 10), fill("1", .buy, 10, 4, 0)]) == 2)
        #expect(try store.externalIDs(tradeID: trade.id) == ["1", "2"])
        #expect(try store.importTrades(tradeID: trade.id, [fill("1", .buy, 10, 4, 0), fill("3", .buy, 1, 1, 20)]) == 1) // "1" skipped
        #expect(try store.transactions(tradeID: trade.id).count == 3)
    }

    @Test func aRejectedImportWritesNothing() throws {
        let store = try TradeStore.inMemory()
        let trade = try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: .buyFirst)
        #expect(throws: StoreError.self) {
            try store.importTrades(tradeID: trade.id, [fill("1", .buy, 1, 1, 0), fill("2", .sell, 5, 5, 1)]) // sells more than held
        }
        #expect(try store.transactions(tradeID: trade.id).isEmpty)
        #expect(try store.externalIDs(tradeID: trade.id).isEmpty)
    }

    @Test func manualTransactionsHaveNoExternalIDAndSurviveTheMigration() throws {
        let store = try TradeStore.inMemory()
        let trade = try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: .buyFirst)
        try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 1, amount: 1, occurredAt: at(0))
        #expect(try store.externalIDs(tradeID: trade.id).isEmpty)
    }

    @Test func importedFeeIsKeptApartFromTheAmount() throws {
        let store = try TradeStore.inMemory()
        let trade = try store.createTrade(exchange: "binance", base: "G", quote: "USDT", direction: .buyFirst)
        var buy = ImportedTrade(externalID: "1", side: .buy, quantity: 10, amount: 100, occurredAt: Date(timeIntervalSince1970: 1000))
        buy.feeQuote = 0.5
        var sell = ImportedTrade(externalID: "2", side: .sell, quantity: 10, amount: 120, occurredAt: Date(timeIntervalSince1970: 2000))
        sell.feeQuote = 0.7
        try store.importTrades(tradeID: trade.id, [buy, sell])
        let txs = try store.transactions(tradeID: trade.id)
        #expect(txs.map(\.amount) == [100, 120] && txs.map(\.fee) == [0.5, 0.7] && txs.map(\.cost) == [100.5, 119.3] && txs.map(\.rate) == [10, 12])
    }

    @Test func migrationV5TakesTheFeeOutOfAmountsStoredByV022() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue, upTo: "v4")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO trade (id, exchange, base, quote, direction, createdAt) VALUES ('t','binance','G','USDT','buyFirst',0)")
            try db.execute(sql: "INSERT INTO tradeTransaction (id, tradeID, side, quantity, amount, occurredAt, sequence, fee) VALUES ('a','t','buy','10','100.5',1,1,'0.5'), ('b','t','sell','10','119.3',2,2,'0.7'), ('c','t','buy','1','5',3,3,NULL)")
        }
        try Schema.migrator().migrate(queue)
        let amounts = try queue.read { try String.fetchAll($0, sql: "SELECT amount FROM tradeTransaction ORDER BY sequence") }
        #expect(amounts == ["100", "120", "5"])
    }

    @Test func editingAnImportedFillKeepsItsFee() throws {
        let store = try TradeStore.inMemory()
        let trade = try store.createTrade(exchange: "binance", base: "G", quote: "USDT", direction: .buyFirst)
        var buy = ImportedTrade(externalID: "1", side: .buy, quantity: 10, amount: 100, occurredAt: Date(timeIntervalSince1970: 1000))
        buy.feeQuote = 0.5
        try store.importTrades(tradeID: trade.id, [buy])
        let id = try store.transactions(tradeID: trade.id)[0].id
        try store.updateTransaction(tradeID: trade.id, id: id, side: .buy, quantity: 10, amount: 110, occurredAt: Date(timeIntervalSince1970: 1000))
        let tx = try store.transactions(tradeID: trade.id)[0]
        #expect(tx.amount == 110 && tx.fee == 0.5)
    }

    @Test func migrationsRunTwiceWithoutChangingData() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue)
        try Schema.migrator().migrate(queue)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations") } == 6)
    }

    @Test func savedFillsKeepTheirRawTextAndGainFeeRates() throws {
        let store = try TradeStore.inMemory()
        let raw = RawFill(id: "1", json: #"{"id":1}"#)
        #expect(try store.saveFills([StoredFill(exchange: "binance", symbol: "G/USDT", raw: raw)]) == 1)
        // the same fill again: not new, raw text untouched, the fee price is added
        #expect(try store.saveFills([StoredFill(exchange: "binance", symbol: "G/USDT", raw: RawFill(id: "1", json: "changed"), feeRates: ["BNB": d("612.5")])]) == 0)
        let saved = try store.fills(exchange: "binance", symbol: "G/USDT")
        #expect(saved == [StoredFill(exchange: "binance", symbol: "G/USDT", raw: raw, feeRates: ["BNB": d("612.5")])])
        #expect(try store.fills(exchange: "poloniex", symbol: "G/USDT").isEmpty && (try store.fills(exchange: "binance", symbol: "X/USDT")).isEmpty)
    }

    @Test func recalculatingUpdatesImportedFillsButNotOnesEditedByHand() throws {
        let store = try TradeStore.inMemory()
        let trade = try store.createTrade(exchange: "binance", base: "G", quote: "USDT", direction: .buyFirst)
        try store.importTrades(tradeID: trade.id, [fill("1", .buy, 10, 100, 0), fill("2", .buy, 10, 100, 1)])
        try store.addTransaction(tradeID: trade.id, side: .buy, quantity: 1, amount: 1, occurredAt: at(5)) // manual: no external id
        let second = try #require(store.transactions(tradeID: trade.id).first { $0.occurredAt == at(1) })
        try store.updateTransaction(tradeID: trade.id, id: second.id, side: .buy, quantity: 10, amount: 105, occurredAt: at(1)) // by hand
        var one = fill("1", .buy, 10, 100, 0); one.feeQuote = 0.5
        var two = fill("2", .buy, 10, 100, 1); two.feeQuote = 0.5
        #expect(try store.reimportTrades(tradeID: trade.id, [one, two]) == 1) // only the untouched one
        let all = try store.transactions(tradeID: trade.id)
        #expect(all.map(\.fee) == [0.5, nil, nil] && all[1].amount == 105)
        #expect(try store.reimportTrades(tradeID: trade.id, [one, two]) == 0) // nothing left to change
    }

    @Test func aRecalculationTheLedgerRejectsChangesNothing() throws {
        let store = try TradeStore.inMemory()
        let trade = try store.createTrade(exchange: "binance", base: "G", quote: "USDT", direction: .buyFirst)
        try store.importTrades(tradeID: trade.id, [fill("1", .buy, 10, 100, 0), fill("2", .sell, 10, 120, 1)])
        var smaller = fill("1", .buy, 5, 50, 0); smaller.feeQuote = 0.1 // the sell would then exceed what was bought
        #expect(throws: (any Error).self) { try store.reimportTrades(tradeID: trade.id, [smaller]) }
        #expect(try store.transactions(tradeID: trade.id).first?.quantity == 10)
    }

    @Test func migrationV6KeepsExistingTransactionsAndMarksThemUnedited() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator().migrate(queue, upTo: "v5")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO trade (id, exchange, base, quote, direction, createdAt) VALUES ('T', 'binance', 'G', 'USDT', 'buyFirst', 0)")
            try db.execute(sql: "INSERT INTO tradeTransaction (id, tradeID, side, quantity, amount, occurredAt, sequence, externalID) VALUES ('X', 'T', 'buy', '1', '2', 0, 1, '7')")
        }
        try Schema.migrator().migrate(queue)
        #expect(try queue.read { try Bool.fetchOne($0, sql: "SELECT edited FROM tradeTransaction WHERE id = 'X'") } == false)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM exchangeFill") } == 0)
    }
}

@Suite struct LegacyMigrationTests {
    private func tempBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func movesTheOldFolderAndRenamesTheDatabase() throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("TradeStickies", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: old.appendingPathComponent("tradestickies.sqlite"))
        try Data("wal".utf8).write(to: old.appendingPathComponent("tradestickies.sqlite-wal"))
        #expect(try LegacyMigration.moveDataFolder(in: base, from: "TradeStickies", to: "TradeStick"))
        let new = base.appendingPathComponent("TradeStick")
        #expect(try Data(contentsOf: new.appendingPathComponent("tradestick.sqlite")) == Data("db".utf8))
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("tradestick.sqlite-wal").path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try LegacyMigration.moveDataFolder(in: base, from: "TradeStickies", to: "TradeStick") == false) // second run: nothing to do
    }

    @Test func neverTouchesAnExistingNewFolder() throws {
        let base = try tempBase(); defer { try? FileManager.default.removeItem(at: base) }
        for name in ["TradeStickies", "TradeStick"] { try FileManager.default.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true) }
        #expect(try LegacyMigration.moveDataFolder(in: base, from: "TradeStickies", to: "TradeStick") == false)
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("TradeStickies").path))
    }

    @Test func copiesKeysOnlyWhereTheNewStoreHasNone() {
        let old = InMemoryCredentialStore(), new = InMemoryCredentialStore()
        try? old.save(APICredentials(key: "OLD1", secret: "S"), exchange: "binance")
        try? old.save(APICredentials(key: "OLD2", secret: "S"), exchange: "bybit")
        try? new.save(APICredentials(key: "NEW2", secret: "S"), exchange: "bybit")
        LegacyMigration.copyKeys(from: old, to: new, exchanges: ["binance", "bybit", "poloniex"])
        #expect(try! new.load(exchange: "binance")?.key == "OLD1")
        #expect(try! new.load(exchange: "bybit")?.key == "NEW2")
        #expect(try! new.load(exchange: "poloniex") == nil)
        #expect(try! old.load(exchange: "binance")?.key == "OLD1") // the old item stays
    }
}

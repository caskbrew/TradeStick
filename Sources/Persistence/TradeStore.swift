import Domain
import Foundation
import GRDB

/// Local SQLite storage for trades and their transactions (FR-STORE-1…6).
/// Every mutation is one database transaction (FR-STORE-5) and validates the would-be ledger first (FR-TX-4).
public final class TradeStore: Sendable {
    private let dbQueue: DatabaseQueue

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Schema.migrator().migrate(dbQueue)
    }

    /// `<Application Support>/TradeStickies/tradestickies.sqlite`, creating the directory (FR-STORE-1).
    public static func databaseURL(inApplicationSupport base: URL, folder: String = "TradeStickies") throws -> URL {
        let dir = base.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tradestickies.sqlite")
    }

    /// The real location for the app: `~/Library/Application Support/TradeStickies/tradestickies.sqlite`.
    public static func defaultDatabaseURL(folder: String = "TradeStickies") throws -> URL {
        try databaseURL(inApplicationSupport: FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true), folder: folder)
    }

    public static func inMemory() throws -> TradeStore {
        try TradeStore(queue: DatabaseQueue())
    }

    private init(queue: DatabaseQueue) throws {
        dbQueue = queue
        try Schema.migrator().migrate(queue)
    }

    // MARK: Trades

    public func createTrade(exchange: String, base: String, quote: String, direction: Direction, now: Date = Date()) throws -> StoredTrade {
        // Round-trip through the stored representation so the returned value equals what a later read returns.
        let now = Date(timeIntervalSince1970: now.timeIntervalSince1970)
        let trade = StoredTrade(
            id: UUID(), exchange: exchange, base: base, quote: quote, direction: direction,
            createdAt: now, isVisible: true, isExpanded: false, isCompact: false, position: nil
        )
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO trade (id, exchange, base, quote, direction, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [trade.id.uuidString, exchange, base, quote, direction.rawValue, now.timeIntervalSince1970]
            )
        }
        return trade
    }

    public func trades() throws -> [StoredTrade] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM trade ORDER BY createdAt, rowid").map(Self.trade(from:))
        }
    }

    public func trade(id: UUID) throws -> StoredTrade? {
        try dbQueue.read { db in try Self.fetchTrade(db, id) }
    }

    /// Deletes the trade and, by foreign-key cascade, all its transactions (FR-STORE-6).
    public func deleteTrade(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM trade WHERE id = ?", arguments: [id.uuidString])
            guard db.changesCount == 1 else { throw StoreError.tradeNotFound(id) }
        }
    }

    /// Direction and pair are immutable (FR-NEW-6); the exchange may change (FR-EX-4).
    public func setExchange(id: UUID, exchange: String) throws {
        try updateTrade(id, "exchange = ?", [exchange])
    }

    public func setVisible(id: UUID, _ isVisible: Bool) throws {
        try updateTrade(id, "isVisible = ?", [isVisible])
    }

    public func setExpanded(id: UUID, _ isExpanded: Bool) throws {
        try updateTrade(id, "isExpanded = ?", [isExpanded])
    }

    public func setCompact(id: UUID, _ isCompact: Bool) throws {
        try updateTrade(id, "isCompact = ?", [isCompact])
    }

    public func setPosition(id: UUID, _ position: WindowPosition?) throws {
        try updateTrade(id, "positionX = ?, positionTopY = ?", [position?.x, position?.topY])
    }

    // MARK: Transactions

    /// Transactions in replay order (time, then creation order), as the calculator expects (FR-TX-5).
    public func transactions(tradeID: UUID) throws -> [Transaction] {
        try dbQueue.read { db in try Self.fetchTransactions(db, tradeID) }
    }

    @discardableResult
    public func addTransaction(tradeID: UUID, side: Side, quantity: Decimal, amount: Decimal, occurredAt: Date) throws -> Transaction {
        try dbQueue.write { db in
            guard let trade = try Self.fetchTrade(db, tradeID) else { throw StoreError.tradeNotFound(tradeID) }
            let existing = try Self.fetchTransactions(db, tradeID)
            let next = try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM tradeTransaction WHERE tradeID = ?", arguments: [tradeID.uuidString]) ?? 0
            let new = Transaction(side: side, quantity: quantity, amount: amount, occurredAt: occurredAt, sequence: next + 1)
            try Self.validate(trade.direction, existing + [new])
            try Self.insert(db, new, tradeID: tradeID)
            return new
        }
    }

    /// Exchange trade ids already imported into this trade.
    public func externalIDs(tradeID: UUID) throws -> Set<String> {
        try dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT externalID FROM tradeTransaction WHERE tradeID = ? AND externalID IS NOT NULL", arguments: [tradeID.uuidString]))
        }
    }

    /// Adds fills from the exchange in time order, all or none: if the ledger rejects the result nothing is written.
    /// Fills that were imported before are skipped. Returns how many were added.
    @discardableResult
    public func importTrades(tradeID: UUID, _ trades: [ImportedTrade]) throws -> Int {
        try dbQueue.write { db in
            guard let trade = try Self.fetchTrade(db, tradeID) else { throw StoreError.tradeNotFound(tradeID) }
            let existing = try Self.fetchTransactions(db, tradeID)
            let known = Set(try String.fetchAll(db, sql: "SELECT externalID FROM tradeTransaction WHERE tradeID = ? AND externalID IS NOT NULL", arguments: [tradeID.uuidString]))
            let fresh = trades.filter { !known.contains($0.externalID) }.sorted { ($0.occurredAt, $0.externalID) < ($1.occurredAt, $1.externalID) }
            var next = try Int.fetchOne(db, sql: "SELECT MAX(sequence) FROM tradeTransaction WHERE tradeID = ?", arguments: [tradeID.uuidString]) ?? 0
            let added = fresh.map { t -> (Transaction, String) in
                next += 1
                return (Transaction(side: t.side, quantity: t.quantity, amount: t.amount, occurredAt: t.occurredAt, sequence: next, fee: t.feeQuote > 0 ? t.feeQuote : nil), t.externalID)
            }
            try Self.validate(trade.direction, existing + added.map(\.0))
            for (tx, externalID) in added {
                try Self.insert(db, tx, tradeID: tradeID)
                try db.execute(sql: "UPDATE tradeTransaction SET externalID = ? WHERE id = ?", arguments: [externalID, tx.id.uuidString])
            }
            return added.count
        }
    }

    /// Keeps the transaction's creation order (`sequence`).
    @discardableResult
    public func updateTransaction(tradeID: UUID, id: UUID, side: Side, quantity: Decimal, amount: Decimal, occurredAt: Date) throws -> Transaction {
        try dbQueue.write { db in
            guard let trade = try Self.fetchTrade(db, tradeID) else { throw StoreError.tradeNotFound(tradeID) }
            var all = try Self.fetchTransactions(db, tradeID)
            guard let index = all.firstIndex(where: { $0.id == id }) else { throw StoreError.transactionNotFound(id) }
            all[index].side = side
            all[index].quantity = quantity
            all[index].amount = amount
            all[index].occurredAt = occurredAt
            try Self.validate(trade.direction, all)
            try db.execute(
                sql: "UPDATE tradeTransaction SET side = ?, quantity = ?, amount = ?, occurredAt = ? WHERE id = ?",
                arguments: [side.rawValue, Self.string(quantity), Self.string(amount), occurredAt.timeIntervalSince1970, id.uuidString]
            )
            return all[index]
        }
    }

    public func deleteTransaction(tradeID: UUID, id: UUID) throws {
        try dbQueue.write { db in
            guard let trade = try Self.fetchTrade(db, tradeID) else { throw StoreError.tradeNotFound(tradeID) }
            var all = try Self.fetchTransactions(db, tradeID)
            guard let index = all.firstIndex(where: { $0.id == id }) else { throw StoreError.transactionNotFound(id) }
            all.remove(at: index)
            try Self.validate(trade.direction, all)
            try db.execute(sql: "DELETE FROM tradeTransaction WHERE id = ?", arguments: [id.uuidString])
        }
    }

    // MARK: Helpers

    private func updateTrade(_ id: UUID, _ assignment: String, _ values: [(any DatabaseValueConvertible)?]) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE trade SET \(assignment) WHERE id = ?", arguments: StatementArguments(values + [id.uuidString]))
            guard db.changesCount == 1 else { throw StoreError.tradeNotFound(id) }
        }
    }

    private static func validate(_ direction: Direction, _ transactions: [Transaction]) throws {
        do {
            _ = try TradeCalculator.summarize(direction: direction, transactions: transactions)
        } catch {
            throw StoreError.ledger(error)
        }
    }

    private static func fetchTrade(_ db: Database, _ id: UUID) throws -> StoredTrade? {
        try Row.fetchOne(db, sql: "SELECT * FROM trade WHERE id = ?", arguments: [id.uuidString]).map(trade(from:))
    }

    private static func fetchTransactions(_ db: Database, _ tradeID: UUID) throws -> [Transaction] {
        try Row.fetchAll(
            db, sql: "SELECT * FROM tradeTransaction WHERE tradeID = ? ORDER BY occurredAt, sequence",
            arguments: [tradeID.uuidString]
        ).map(transaction(from:))
    }

    private static func insert(_ db: Database, _ t: Transaction, tradeID: UUID) throws {
        try db.execute(
            sql: "INSERT INTO tradeTransaction (id, tradeID, side, quantity, amount, occurredAt, sequence, fee) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            arguments: [t.id.uuidString, tradeID.uuidString, t.side.rawValue, string(t.quantity), string(t.amount), t.occurredAt.timeIntervalSince1970, t.sequence, t.fee.map(string)]
        )
    }

    /// `Decimal.description` is locale-independent and round-trips exactly.
    static func string(_ d: Decimal) -> String { "\(d)" }

    static func decimal(_ s: String) throws -> Decimal {
        guard let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { throw StoreError.corrupt("decimal: \(s)") }
        return d
    }

    private static func trade(from row: Row) throws -> StoredTrade {
        guard let id = UUID(uuidString: row["id"]), let direction = Direction(rawValue: row["direction"]) else {
            throw StoreError.corrupt("trade row")
        }
        let x: Double? = row["positionX"], topY: Double? = row["positionTopY"]
        return StoredTrade(
            id: id, exchange: row["exchange"], base: row["base"], quote: row["quote"], direction: direction,
            createdAt: Date(timeIntervalSince1970: row["createdAt"]),
            isVisible: row["isVisible"], isExpanded: row["isExpanded"], isCompact: row["isCompact"],
            position: x.flatMap { x in topY.map { WindowPosition(x: x, topY: $0) } }
        )
    }

    private static func transaction(from row: Row) throws -> Transaction {
        guard let id = UUID(uuidString: row["id"]), let side = Side(rawValue: row["side"]) else {
            throw StoreError.corrupt("transaction row")
        }
        return Transaction(
            id: id, side: side, quantity: try decimal(row["quantity"]), amount: try decimal(row["amount"]),
            occurredAt: Date(timeIntervalSince1970: row["occurredAt"]), sequence: row["sequence"],
            fee: (row["fee"] as String?).flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
        )
    }
}

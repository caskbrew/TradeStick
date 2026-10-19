import Foundation
import GRDB

enum Schema {
    /// Forward-only migrations (FR-STORE-4). Never edit a released migration: add a new one.
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "trade") { t in
                t.column("id", .text).primaryKey()
                t.column("exchange", .text).notNull()
                t.column("base", .text).notNull()
                t.column("quote", .text).notNull()
                t.column("direction", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("isVisible", .boolean).notNull().defaults(to: true)
                t.column("isExpanded", .boolean).notNull().defaults(to: false)
                t.column("positionX", .double)
                t.column("positionTopY", .double)
            }
            // Money and quantities are decimal strings, never binary floats (FR-STORE-2).
            try db.create(table: "tradeTransaction") { t in
                t.column("id", .text).primaryKey()
                t.column("tradeID", .text).notNull().references("trade", onDelete: .cascade)
                t.column("side", .text).notNull()
                t.column("quantity", .text).notNull()
                t.column("amount", .text).notNull()
                t.column("occurredAt", .double).notNull()
                t.column("sequence", .integer).notNull()
                t.uniqueKey(["tradeID", "sequence"])
            }
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "trade") { t in t.add(column: "isCompact", .boolean).notNull().defaults(to: false) }
        }

        // The exchange's trade id of an imported fill; manual transactions have none. Unique per trade.
        migrator.registerMigration("v3") { db in
            try db.alter(table: "tradeTransaction") { t in t.add(column: "externalID", .text) }
            try db.execute(sql: "CREATE UNIQUE INDEX tradeTransaction_external ON tradeTransaction(tradeID, externalID) WHERE externalID IS NOT NULL")
        }

        // The fee (quote currency) of an imported fill; it is already inside `amount`, kept to show it.
        migrator.registerMigration("v4") { db in
            try db.alter(table: "tradeTransaction") { t in t.add(column: "fee", .text) }
        }

        // 0.2.2 stored the fee inside `amount` of imported fills: take it out again (the ledger adds it by `Transaction.cost`).
        migrator.registerMigration("v5") { db in
            for row in try Row.fetchAll(db, sql: "SELECT id, side, amount, fee FROM tradeTransaction WHERE fee IS NOT NULL") {
                guard let amount = Decimal(string: row["amount"] as String, locale: Locale(identifier: "en_US_POSIX")),
                      let fee = Decimal(string: row["fee"] as String, locale: Locale(identifier: "en_US_POSIX")) else { continue }
                let raw = (row["side"] as String) == "buy" ? amount - fee : amount + fee
                try db.execute(sql: "UPDATE tradeTransaction SET amount = ? WHERE id = ?", arguments: ["\(raw)", row["id"] as String])
            }
        }

        // The exchange's fills kept as they were sent (it keeps only the last months), and a mark on imported transactions
        // the user edited by hand: a recalculation from the saved fills leaves those alone.
        migrator.registerMigration("v6") { db in
            try db.create(table: "exchangeFill") { t in
                t.column("exchange", .text).notNull()
                t.column("symbol", .text).notNull()
                t.column("fillID", .text).notNull()
                t.column("raw", .text).notNull()
                t.column("feeRates", .text).notNull().defaults(to: "{}")
                t.column("fetchedAt", .double).notNull()
                t.primaryKey(["exchange", "symbol", "fillID"])
            }
            try db.alter(table: "tradeTransaction") { t in t.add(column: "edited", .boolean).notNull().defaults(to: false) }
        }

        return migrator
    }
}

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

        return migrator
    }
}

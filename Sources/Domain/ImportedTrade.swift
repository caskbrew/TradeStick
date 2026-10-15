import Foundation

/// A fill (or, grouped, a whole order) from the exchange's trade history, ready to become a transaction.
/// `externalID` is what the store remembers: the exchange's trade id, or `o<orderId>` for a grouped order.
/// Importing the same one twice is refused.
public struct ImportedTrade: Identifiable, Equatable, Sendable {
    public var externalID: String
    public var side: Side
    public var quantity: Decimal
    public var amount: Decimal
    public var occurredAt: Date
    /// Exchange order this fill belongs to.
    public var orderID: String?
    /// Exchange trade ids behind this row (one for a fill, several for a grouped order).
    public var fillIDs: [String]
    /// Fees per asset, shown for information only; they are not part of the PnL.
    public var fees: [String: Decimal]

    public var id: String { externalID }
    public var rate: Decimal? { quantity > 0 ? amount / quantity : nil }

    public init(
        externalID: String, side: Side, quantity: Decimal, amount: Decimal, occurredAt: Date,
        orderID: String? = nil, fillIDs: [String]? = nil, fees: [String: Decimal] = [:]
    ) {
        self.externalID = externalID
        self.side = side
        self.quantity = quantity
        self.amount = amount
        self.occurredAt = occurredAt
        self.orderID = orderID
        self.fillIDs = fillIDs ?? [externalID]
        self.fees = fees
    }

    public var feeText: String? {
        fees.isEmpty ? nil : fees.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: " + ")
    }

    /// One row per order, like the exchange's web order history: the quantities and amounts of its fills add up, so the
    /// rate is the average price. The time is that of the last fill. Fills without an order stay as they are.
    public static func groupedByOrder(_ fills: [ImportedTrade]) -> [ImportedTrade] {
        var order: [String] = []
        var groups: [String: [ImportedTrade]] = [:]
        for fill in fills {
            let key = fill.orderID.map { "o" + $0 } ?? fill.externalID
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(fill)
        }
        return order.map { key in
            let parts = groups[key]!
            guard parts.count > 1 || parts[0].orderID != nil, let first = parts.first else { return parts[0] }
            var fees: [String: Decimal] = [:]
            for part in parts { for (asset, value) in part.fees { fees[asset, default: 0] += value } }
            return ImportedTrade(
                externalID: key, side: first.side, quantity: parts.reduce(0) { $0 + $1.quantity }, amount: parts.reduce(0) { $0 + $1.amount },
                occurredAt: parts.map(\.occurredAt).max()!, orderID: first.orderID, fillIDs: parts.flatMap(\.fillIDs), fees: fees
            )
        }
    }
}

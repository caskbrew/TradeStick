import Foundation

/// A fill from the exchange's trade history, ready to become a transaction. `externalID` is the exchange's
/// trade id: importing the same fill twice is refused.
public struct ImportedTrade: Identifiable, Equatable, Sendable {
    public var externalID: String
    public var side: Side
    public var quantity: Decimal
    public var amount: Decimal
    public var occurredAt: Date
    /// Shown for information only ("0.0004 BNB"); fees are not part of the PnL.
    public var fee: String?

    public var id: String { externalID }
    public var rate: Decimal? { quantity > 0 ? amount / quantity : nil }

    public init(externalID: String, side: Side, quantity: Decimal, amount: Decimal, occurredAt: Date, fee: String? = nil) {
        self.externalID = externalID
        self.side = side
        self.quantity = quantity
        self.amount = amount
        self.occurredAt = occurredAt
        self.fee = fee
    }
}

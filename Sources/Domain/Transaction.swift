import Foundation

public enum Side: String, Codable, Sendable, Equatable {
    case buy, sell
}

public enum Direction: String, Codable, Sendable, Equatable {
    case buyFirst, sellFirst

    public var openingSide: Side { self == .buyFirst ? .buy : .sell }
    public var closingSide: Side { self == .buyFirst ? .sell : .buy }
}

/// One manually entered transaction. Rate is derived, never stored.
public struct Transaction: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var side: Side
    public var quantity: Decimal
    public var amount: Decimal
    public var occurredAt: Date
    /// Creation order; breaks ties between equal `occurredAt`.
    public var sequence: Int

    public init(id: UUID = UUID(), side: Side, quantity: Decimal, amount: Decimal, occurredAt: Date, sequence: Int) {
        self.id = id
        self.side = side
        self.quantity = quantity
        self.amount = amount
        self.occurredAt = occurredAt
        self.sequence = sequence
    }

    public var rate: Decimal? { quantity > 0 ? amount / quantity : nil }
}

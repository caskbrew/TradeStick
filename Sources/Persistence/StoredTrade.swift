import Domain
import Foundation

/// Top-left corner of a sticker in screen coordinates (AppKit: origin bottom-left, y grows up).
/// The top edge is stored because the window grows downward (FR-TX-8).
public struct WindowPosition: Equatable, Sendable {
    public var x: Double
    public var topY: Double

    public init(x: Double, topY: Double) {
        self.x = x
        self.topY = topY
    }
}

/// A trade as stored. Status, averages and PnL are NOT stored: derive them from the transactions (FR-STORE-3).
public struct StoredTrade: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// Opaque exchange identifier, e.g. "binance". Persistence knows nothing about specific exchanges (FR-EX-2).
    public var exchange: String
    public let base: String
    public let quote: String
    public let direction: Direction
    public let createdAt: Date
    public var isVisible: Bool
    public var isExpanded: Bool
    /// Compact view: price, entry, amount and PnL only.
    public var isCompact: Bool
    public var position: WindowPosition?
}

public enum StoreError: Error, Equatable, Sendable {
    case tradeNotFound(UUID)
    case transactionNotFound(UUID)
    /// The change would break the ledger invariant (FR-TX-3/4); nothing was written.
    case ledger(LedgerError)
    /// A stored value could not be decoded (corrupt or hand-edited database).
    case corrupt(String)
}

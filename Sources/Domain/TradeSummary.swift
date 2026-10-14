import Foundation

public enum TradeStatus: Equatable, Sendable {
    case empty, open, closed
}

public struct PnL: Equatable, Sendable {
    public let realized: Decimal
    /// nil when the current price is unknown.
    public let unrealized: Decimal?
    public let total: Decimal?
    /// total / sum of opening-side amounts, as a fraction (0.1188 = 11.88 %).
    public let ratio: Decimal?

    public init(realized: Decimal, unrealized: Decimal?, total: Decimal?, ratio: Decimal?) {
        self.realized = realized
        self.unrealized = unrealized
        self.total = total
        self.ratio = ratio
    }
}

public struct TradeSummary: Equatable, Sendable {
    public let direction: Direction
    public let hasTransactions: Bool
    public let boughtQuantity: Decimal
    public let boughtAmount: Decimal
    public let soldQuantity: Decimal
    public let soldAmount: Decimal
    public let openQuantity: Decimal
    /// Quote amount attributed to the still-open quantity (average-cost method).
    public let openCost: Decimal
    public let realized: Decimal
    /// Sum of amounts of all opening-side transactions (PnL % base).
    public let openingAmount: Decimal

    public init(
        direction: Direction, hasTransactions: Bool,
        boughtQuantity: Decimal, boughtAmount: Decimal, soldQuantity: Decimal, soldAmount: Decimal,
        openQuantity: Decimal, openCost: Decimal, realized: Decimal, openingAmount: Decimal
    ) {
        self.direction = direction
        self.hasTransactions = hasTransactions
        self.boughtQuantity = boughtQuantity
        self.boughtAmount = boughtAmount
        self.soldQuantity = soldQuantity
        self.soldAmount = soldAmount
        self.openQuantity = openQuantity
        self.openCost = openCost
        self.realized = realized
        self.openingAmount = openingAmount
    }

    /// A trade without transactions.
    public static func empty(_ direction: Direction) -> TradeSummary {
        TradeSummary(
            direction: direction, hasTransactions: false, boughtQuantity: 0, boughtAmount: 0, soldQuantity: 0,
            soldAmount: 0, openQuantity: 0, openCost: 0, realized: 0, openingAmount: 0
        )
    }

    public var status: TradeStatus {
        if !hasTransactions { return .empty }
        return openQuantity > 0 ? .open : .closed
    }

    public var avgBuyRate: Decimal? { boughtQuantity > 0 ? boughtAmount / boughtQuantity : nil }
    public var avgSellRate: Decimal? { soldQuantity > 0 ? soldAmount / soldQuantity : nil }
    public var entryPrice: Decimal? { openQuantity > 0 ? openCost / openQuantity : nil }

    public func pnl(at price: Decimal?) -> PnL {
        guard let price else {
            return PnL(realized: realized, unrealized: nil, total: nil, ratio: nil)
        }
        let unrealized = direction == .buyFirst
            ? openQuantity * price - openCost
            : openCost - openQuantity * price
        let total = realized + unrealized
        let ratio: Decimal? = openingAmount > 0 ? total / openingAmount : nil
        return PnL(realized: realized, unrealized: unrealized, total: total, ratio: ratio)
    }
}

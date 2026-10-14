import Foundation

public enum LedgerError: Error, Equatable, Sendable {
    case nonPositiveValue(transactionID: UUID)
    /// A closing transaction is larger than the open quantity at its point in time.
    case closingExceedsOpen(transactionID: UUID, available: Decimal)
}

public enum TradeCalculator {
    public static func summarize(direction: Direction, transactions: [Transaction]) throws(LedgerError) -> TradeSummary {
        let ordered = transactions

        var boughtQuantity: Decimal = 0, boughtAmount: Decimal = 0
        var soldQuantity: Decimal = 0, soldAmount: Decimal = 0
        var openQuantity: Decimal = 0, openCost: Decimal = 0
        var realized: Decimal = 0, openingAmount: Decimal = 0

        for tx in ordered {
            switch tx.side {
            case .buy: boughtQuantity += tx.quantity; boughtAmount += tx.amount
            case .sell: soldQuantity += tx.quantity; soldAmount += tx.amount
            }

            if tx.side == direction.openingSide {
                openQuantity += tx.quantity
                openCost += tx.amount
                openingAmount += tx.amount
            } else {
                let closedCost = openCost * tx.quantity / openQuantity
                realized += direction == .buyFirst ? tx.amount - closedCost : closedCost - tx.amount
                openQuantity -= tx.quantity
                openCost -= closedCost
            }
        }

        return TradeSummary(
            direction: direction,
            hasTransactions: !ordered.isEmpty,
            boughtQuantity: boughtQuantity, boughtAmount: boughtAmount,
            soldQuantity: soldQuantity, soldAmount: soldAmount,
            openQuantity: openQuantity, openCost: openCost,
            realized: realized, openingAmount: openingAmount
        )
    }
}

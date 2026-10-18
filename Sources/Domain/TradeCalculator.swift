import Foundation

public enum LedgerError: Error, Equatable, Sendable {
    case nonPositiveValue(transactionID: UUID)
    /// A closing transaction is larger than the open quantity at its point in time.
    case closingExceedsOpen(transactionID: UUID, available: Decimal)
}

public enum TradeCalculator {
    /// Replays transactions chronologically (time, then creation order) using the average-cost method.
    public static func summarize(direction: Direction, transactions: [Transaction]) throws(LedgerError) -> TradeSummary {
        let ordered = transactions.sorted {
            // id is a last-resort tie-break so a duplicated sequence cannot make the result depend on input order.
            ($0.occurredAt, $0.sequence, $0.id.uuidString) < ($1.occurredAt, $1.sequence, $1.id.uuidString)
        }

        var boughtQuantity: Decimal = 0, boughtAmount: Decimal = 0
        var soldQuantity: Decimal = 0, soldAmount: Decimal = 0
        var openQuantity: Decimal = 0, openCost: Decimal = 0
        var realized: Decimal = 0, openingAmount: Decimal = 0

        for tx in ordered {
            guard tx.quantity > 0, tx.amount > 0, tx.cost > 0 else {
                throw .nonPositiveValue(transactionID: tx.id)
            }
            switch tx.side {
            case .buy: boughtQuantity += tx.quantity; boughtAmount += tx.cost
            case .sell: soldQuantity += tx.quantity; soldAmount += tx.cost
            }

            if tx.side == direction.openingSide {
                openQuantity += tx.quantity
                openCost += tx.cost
                openingAmount += tx.cost
            } else {
                guard tx.quantity <= openQuantity else {
                    throw .closingExceedsOpen(transactionID: tx.id, available: openQuantity)
                }
                // Multiply before dividing, and take the whole cost on a full close, to avoid repeating-decimal residue.
                let closedCost = tx.quantity == openQuantity ? openCost : openCost * tx.quantity / openQuantity
                realized += direction == .buyFirst ? tx.cost - closedCost : closedCost - tx.cost
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

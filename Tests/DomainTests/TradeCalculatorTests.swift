import Foundation
import Testing
@testable import Domain

@Suite struct TradeCalculatorTests {
    // Spec 5.5, example A.
    static let exampleA = [
        tx(.buy, "1000", "50", minute: 1, seq: 1),
        tx(.buy, "500", "30", minute: 2, seq: 2),
        tx(.sell, "600", "40", minute: 3, seq: 3),
    ]

    @Test func feesCountAsCostOfABuyAndLessProceedsOfASell() throws {
        var buy = tx(.buy, "100", "1000", minute: 1, seq: 1); buy.fee = 10
        var sell = tx(.sell, "40", "480", minute: 2, seq: 2); sell.fee = 8
        #expect(buy.rate == 10 && sell.rate == 12) // the price is the trade's own
        let open = try TradeCalculator.summarize(direction: .buyFirst, transactions: [buy])
        #expect(open.openCost == 1010 && open.entryPrice == 10.1)
        let part = try TradeCalculator.summarize(direction: .buyFirst, transactions: [buy, sell])
        // closed cost 1010 * 40 / 100 = 404; proceeds 480 - 8 = 472
        #expect(part.realized == 68 && part.openCost == 606)
    }

    @Test func feesInASellFirstTrade() throws {
        var open = tx(.sell, "100", "1200", minute: 1, seq: 1); open.fee = 12  // proceeds 1188
        var close = tx(.buy, "100", "1000", minute: 2, seq: 2); close.fee = 10 // cost 1010
        let s = try TradeCalculator.summarize(direction: .sellFirst, transactions: [open, close])
        #expect(s.realized == d("178"))
    }

    @Test func emptyTradeIsEmpty() throws {
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: [])
        #expect(s.status == .empty)
        #expect(s.entryPrice == nil)
        #expect(s.pnl(at: d("0.055")).total == 0)
    }

    @Test func exampleA_buyFirst() throws {
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: Self.exampleA)
        #expect(s.status == .open)
        #expect(s.openQuantity == 900)
        #expect(s.openCost == 48)
        #expect(s.realized == 8)
        #expect(s.boughtQuantity == 1500 && s.boughtAmount == 80)
        #expect(s.soldQuantity == 600 && s.soldAmount == 40)
        #expect(approx(s.entryPrice, "0.0533333333"))
        #expect(approx(s.avgBuyRate, "0.0533333333"))
        #expect(approx(s.avgSellRate, "0.0666666667", tolerance: "0.0000000001"))

        let pnl = s.pnl(at: d("0.055"))
        #expect(pnl.unrealized == d("1.5"))
        #expect(pnl.total == d("9.5"))
        #expect(pnl.ratio == d("0.11875"))
    }

    @Test func exampleB_sellFirst() throws {
        let txs = [
            tx(.sell, "1000", "60", minute: 1, seq: 1),
            tx(.sell, "1000", "50", minute: 2, seq: 2),
            tx(.buy, "500", "20", minute: 3, seq: 3),
        ]
        let s = try TradeCalculator.summarize(direction: .sellFirst, transactions: txs)
        #expect(s.openQuantity == 1500)
        #expect(s.openCost == d("82.5"))
        #expect(s.realized == d("7.5"))
        #expect(s.entryPrice == d("0.055"))

        let pnl = s.pnl(at: d("0.058"))
        #expect(pnl.unrealized == d("-4.5"))
        #expect(pnl.total == 3)
        #expect(approx(pnl.ratio, "0.0272727272", tolerance: "0.0000000001"))
    }

    @Test func exampleC_fullCloseBecomesClosed() throws {
        let txs = Self.exampleA + [tx(.sell, "900", "54", minute: 4, seq: 4)]
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: txs)
        #expect(s.status == .closed)
        #expect(s.openQuantity == 0)
        #expect(s.openCost == 0)
        #expect(s.realized == 14)
        #expect(s.pnl(at: d("0.05")).total == 14) // price no longer matters
        #expect(s.pnl(at: nil).realized == 14)
        #expect(s.pnl(at: d("0.05")).ratio == d("0.175"))
    }

    @Test func unknownPriceKeepsRealized() throws {
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: Self.exampleA)
        let pnl = s.pnl(at: nil)
        #expect(pnl.realized == 8)
        #expect(pnl.unrealized == nil && pnl.total == nil && pnl.ratio == nil)
    }

    @Test func exampleD_oversellIsRejected() {
        let txs = Self.exampleA + [tx(.sell, "1600", "100", minute: 4, seq: 4)]
        #expect(throws: LedgerError.self) {
            try TradeCalculator.summarize(direction: .buyFirst, transactions: txs)
        }
    }

    @Test func backdatedSellBeforeBuyIsRejectedEvenIfTotalsBalance() {
        // Sell at minute 0 precedes the only buy at minute 1: invalid at that moment.
        let txs = [tx(.buy, "100", "10", minute: 1, seq: 1), tx(.sell, "50", "6", minute: 0, seq: 2)]
        let result = Result { () throws(LedgerError) -> TradeSummary in
            try TradeCalculator.summarize(direction: .buyFirst, transactions: txs)
        }
        guard case .failure(let error) = result, case .closingExceedsOpen(let id, let available) = error else {
            Issue.record("expected closingExceedsOpen"); return
        }
        #expect(id == txs[1].id)
        #expect(available == 0)
    }

    @Test func equalTimestampsUseCreationOrder() throws {
        // Same minute: buy has sequence 1, sell sequence 2, so the sell is valid.
        let txs = [tx(.sell, "50", "6", minute: 1, seq: 2), tx(.buy, "100", "10", minute: 1, seq: 1)]
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: txs)
        #expect(s.openQuantity == 50)
        #expect(s.realized == 1)
    }

    @Test func nonPositiveValuesAreRejected() {
        for bad in [tx(.buy, "0", "10", minute: 1, seq: 1), tx(.buy, "10", "0", minute: 1, seq: 1), tx(.buy, "-1", "10", minute: 1, seq: 1)] {
            #expect(throws: LedgerError.self) {
                try TradeCalculator.summarize(direction: .buyFirst, transactions: [bad])
            }
        }
    }

    @Test func fullCloseLeavesNoDecimalResidue() throws {
        // 1/7 is a repeating decimal: without the full-close shortcut openCost ends at 1e-38, not 0.
        let txs = [
            tx(.buy, "7", "1", minute: 1, seq: 1),
            tx(.sell, "1", "1", minute: 2, seq: 2),
            tx(.sell, "6", "1", minute: 3, seq: 3),
        ]
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: txs)
        #expect(s.status == .closed)
        #expect(s.openCost == 0)
        #expect(s.realized == 1) // received 2, spent 1
    }

    @Test func identicalTimeAndSequenceGiveInputOrderIndependentResult() {
        // sequence is not guaranteed unique by the type: the outcome must not depend on array order.
        let a = tx(.buy, "100", "10", minute: 1, seq: 1)
        let b = tx(.sell, "50", "6", minute: 1, seq: 1)
        let forward = Result { () throws(LedgerError) -> TradeSummary in
            try TradeCalculator.summarize(direction: .buyFirst, transactions: [a, b])
        }
        let reversed = Result { () throws(LedgerError) -> TradeSummary in
            try TradeCalculator.summarize(direction: .buyFirst, transactions: [b, a])
        }
        #expect(forward == reversed)
    }

    @Test func oversellErrorNamesTheOffendingTransaction() {
        let bad = tx(.sell, "1600", "100", minute: 4, seq: 4)
        let result = Result { () throws(LedgerError) -> TradeSummary in
            try TradeCalculator.summarize(direction: .buyFirst, transactions: Self.exampleA + [bad])
        }
        #expect(result == .failure(.closingExceedsOpen(transactionID: bad.id, available: 900)))
    }

    @Test func nonPositiveErrorNamesTheOffendingTransaction() {
        let bad = tx(.buy, "0", "10", minute: 1, seq: 1)
        let result = Result { () throws(LedgerError) -> TradeSummary in
            try TradeCalculator.summarize(direction: .buyFirst, transactions: [bad])
        }
        #expect(result == .failure(.nonPositiveValue(transactionID: bad.id)))
    }

    @Test func sellFirstFullCloseAndOverBuy() throws {
        let closed = try TradeCalculator.summarize(direction: .sellFirst, transactions: [
            tx(.sell, "7", "1", minute: 1, seq: 1), tx(.buy, "7", "0.5", minute: 2, seq: 2),
        ])
        #expect(closed.status == .closed && closed.openCost == 0 && closed.realized == d("0.5"))
        let bad = tx(.buy, "8", "1", minute: 2, seq: 2)
        #expect(throws: LedgerError.self) {
            try TradeCalculator.summarize(direction: .sellFirst, transactions: [tx(.sell, "7", "1", minute: 1, seq: 1), bad])
        }
    }
}

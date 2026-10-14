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
}

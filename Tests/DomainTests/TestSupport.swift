import Foundation
@testable import Domain

func d(_ s: String) -> Decimal { Decimal(string: s)! }

/// `minute` offsets from a fixed base date, so tests read as a timeline.
func tx(_ side: Side, _ quantity: String, _ amount: String, minute: Int, seq: Int) -> Transaction {
    Transaction(
        side: side, quantity: d(quantity), amount: d(amount),
        occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60), sequence: seq
    )
}

func approx(_ a: Decimal?, _ b: String, tolerance: String = "0.000000001") -> Bool {
    guard let a else { return false }
    let diff = a - d(b)
    return (diff < 0 ? -diff : diff) <= d(tolerance)
}

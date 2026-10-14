import Domain
import Foundation

/// State of the embedded transaction form with the linked Quantity / Amount / Rate fields (FR-TX-2, FR-TX-2a).
/// Quantity is always typed. Of Amount and Rate, the one edited last is the input and the other is computed.
public struct TransactionDraft: Equatable, Sendable {
    public enum Field: Sendable { case quantity, amount, rate }

    public enum Problem: Equatable, Sendable {
        case quantityInvalid, amountInvalid, rateInvalid, timeInFuture
        public var message: String {
            switch self {
            case .quantityInvalid: "Enter a quantity greater than 0"
            case .amountInvalid: "Enter an amount greater than 0"
            case .rateInvalid: "Enter a rate greater than 0"
            case .timeInFuture: "Time cannot be in the future"
            }
        }
    }

    public var side: Side
    public var occurredAt: Date
    public private(set) var quantityText = ""
    public private(set) var amountText = ""
    public private(set) var rateText = ""
    /// Which of Amount / Rate the user typed last.
    public private(set) var driver: Field = .amount

    public init(side: Side, occurredAt: Date) {
        self.side = side
        self.occurredAt = occurredAt
    }

    /// Pre-fills the form, e.g. `Close` with the whole open quantity at the current price (FR-TX-1a).
    public init(side: Side, occurredAt: Date, quantity: Decimal, rate: Decimal) {
        self.init(side: side, occurredAt: occurredAt)
        edit(.quantity, Self.text(quantity, scale: 8))
        edit(.rate, Self.text(rate, scale: 10))
    }

    /// Pre-fills the form with an existing transaction; Amount is the input, Rate follows.
    public init(side: Side, occurredAt: Date, quantity: Decimal, amount: Decimal) {
        self.init(side: side, occurredAt: occurredAt)
        edit(.quantity, Self.text(quantity, scale: 8))
        edit(.amount, Self.text(amount, scale: 8))
    }

    public mutating func edit(_ field: Field, _ text: String) {
        switch field {
        case .quantity: quantityText = text
        case .amount: amountText = text; driver = .amount
        case .rate: rateText = text; driver = .rate
        }
        recompute()
    }

    /// The computed field is shown dimmed with an `auto` label (FR-TX-2).
    public func isAuto(_ field: Field) -> Bool {
        (field == .amount || field == .rate) && field != driver
    }

    public var quantity: Decimal? { DecimalInput.parse(quantityText) }

    /// The value that would be saved: typed Amount, or `Quantity × Rate` rounded to 8 decimals (FR-TX-2a).
    public var amount: Decimal? {
        switch driver {
        case .amount: return DecimalInput.parse(amountText)
        case .rate:
            guard let q = quantity, let r = DecimalInput.parse(rateText) else { return nil }
            return (q * r).rounded(scale: 8)
        case .quantity: return nil
        }
    }

    /// Problems worth showing: only fields the user has typed into can be reported, plus a future time.
    /// An untouched form is merely not savable (FR-UI-15).
    public func problems(now: Date) -> [Problem] {
        var found: [Problem] = []
        if !quantityText.isEmpty, !(quantity.map { $0 > 0 } ?? false) { found.append(.quantityInvalid) }
        if driver == .amount, !amountText.isEmpty, !(amount.map { $0 > 0 } ?? false) { found.append(.amountInvalid) }
        if driver == .rate, !rateText.isEmpty {
            if let r = DecimalInput.parse(rateText), r > 0 {
                // A valid rate with a valid quantity that still yields no amount rounds to 0 at 8 decimals.
                if quantity.map({ $0 > 0 }) == true, !(amount.map { $0 > 0 } ?? false) { found.append(.amountInvalid) }
            } else {
                found.append(.rateInvalid)
            }
        }
        if occurredAt > now.addingTimeInterval(60) { found.append(.timeInFuture) } // FR-TX-3
        return found
    }

    /// Valid quantity and amount, both greater than zero, time not in the future.
    public func savable(now: Date) -> (quantity: Decimal, amount: Decimal)? {
        guard let q = quantity, q > 0, let a = amount, a > 0, problems(now: now).isEmpty else { return nil }
        return (q, a)
    }

    // MARK: Linking

    private mutating func recompute() {
        switch driver {
        case .amount:
            if let q = quantity, q > 0, let a = DecimalInput.parse(amountText) {
                rateText = Self.text(a / q, scale: 10)
            } else {
                rateText = ""
            }
        case .rate:
            if let a = amount, quantity.map({ $0 > 0 }) == true {
                amountText = Self.text(a, scale: 8)
            } else {
                amountText = ""
            }
        case .quantity:
            break
        }
    }

    /// Editable plain text: no grouping, trailing zeros dropped.
    private static func text(_ value: Decimal, scale: Int) -> String {
        let style = Decimal.FormatStyle(locale: Locale(identifier: "en_US"))
            .precision(.fractionLength(0...scale))
            .grouping(.never)
            .rounded(rule: .toNearestOrAwayFromZero)
        return value.formatted(style)
    }
}

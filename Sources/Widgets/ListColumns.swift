import AppKit
import Presentation

/// Column widths shared by the transaction list and the totals row of the card above it, so each column is one
/// column through both windows. Order: rate, amount, qty, fee, side, pnl. They are fitted to the digits the
/// current trade actually shows and always add up to the full width: no empty space, no narrow squeeze.
struct ListColumns: Equatable {
    static let spacing: CGFloat = 6
    /// Both windows put the columns this far from their edge.
    static let inset: CGFloat = 11
    /// The B/S chip holds one letter.
    static let side: CGFloat = 16

    var rate: CGFloat, amount: CGFloat, qty: CGFloat, fee: CGFloat, pnl: CGFloat

    /// Width of the side and PnL columns with their gaps: the totals row has nothing there.
    var trailing: CGFloat { Self.side + Self.spacing + pnl }

    /// Splits the width left after the gaps and the side column in proportion to what each column needs.
    static func fit(rate: CGFloat, amount: CGFloat, qty: CGFloat, fee: CGFloat, pnl: CGFloat, in total: CGFloat) -> ListColumns {
        let free = total - 2 * inset - side - 5 * spacing
        let sum = max(rate + amount + qty + fee + pnl, 1)
        let k = free / sum
        return ListColumns(rate: rate * k, amount: amount * k, qty: qty * k, fee: fee * k, pnl: pnl * k)
    }
}

/// Text widths of the fonts the columns use, measured once per character.
@MainActor enum Ruler {
    static var cache: [String: CGFloat] = [:]

    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        text.reduce(0) { sum, char in
            let key = "\(char)\(size)\(weight.rawValue)"
            if let known = cache[key] { return sum + known }
            let w = ("\(char)" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)]).width
            cache[key] = w
            return sum + w
        }
    }
}

extension StickerModel {
    /// Widths for this trade: the widest of what each column shows in the list and in the totals row, titles included.
    var columns: ListColumns {
        let fixed = quoteFixed, s = summary, closed = status == .closed
        let rows = transactions
        func need(_ cells: [String], _ title: String) -> CGFloat {
            let body = cells.map { Ruler.width($0, size: 12.5, weight: .regular) }.max() ?? 0
            return max(body, Ruler.width(title, size: 11, weight: .regular)) + 3 // breathing room: a title is never cut
        }
        return .fit(
            rate: need(rows.map { $0.rate.map(NumberFormat.shownPrice) ?? "—" } + [s.entryPrice.map(NumberFormat.shownPrice) ?? "—"], "Rate"),
            amount: need(rows.map { NumberFormat.quote($0.amount, fixed: fixed) } + [closed ? "—" : NumberFormat.quote(s.openCost, fixed: fixed)], trade.quote),
            qty: need(rows.map { NumberFormat.quantity($0.quantity) } + [closed ? "—" : NumberFormat.quantity(s.openQuantity)], trade.base),
            fee: need(rows.map { $0.fee.map { NumberFormat.quote($0, fixed: fixed) } ?? "—" } + [totalFee.map { NumberFormat.quote($0, fixed: fixed) } ?? "—"], "Fee"),
            pnl: need(rows.map { pnl(of: $0).map { NumberFormat.signedQuote($0, fixed: fixed) } ?? "—" }, ""),
            in: StickerView.width
        )
    }
}

import Domain
import MarketData
import Presentation
import SwiftUI

/// Window-level actions the model cannot perform itself.
public struct StickerActions {
    public var hide: () -> Void
    public var delete: () -> Void
    public init(hide: @escaping () -> Void, delete: @escaping () -> Void) {
        self.hide = hide
        self.delete = delete
    }
}

public struct StickerView: View {
    public static let width: CGFloat = 340

    let model: StickerModel
    let actions: StickerActions

    public init(model: StickerModel, actions: StickerActions) {
        self.model = model
        self.actions = actions
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let freshness = model.price.freshness(at: context.date)
            let usable = freshness == .fresh && model.price.connection == .connected
            VStack(alignment: .leading, spacing: 12) {
                StickerHeader(model: model, actions: actions)
                PriceRow(model: model, freshness: freshness, usable: usable)
                Divider().overlay(Theme.divider)
                if model.status == .empty {
                    Text("Add first transaction").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                } else {
                    NumbersBlock(model: model, usable: usable)
                    SideTotals(summary: model.summary)
                }
                Divider().overlay(Theme.divider)
                if model.form != nil {
                    TransactionForm(model: model).transition(.opacity)
                } else {
                    ActionRow(model: model)
                }
                if model.trade.isExpanded { TransactionList(model: model).transition(.opacity) }
            }
            .padding(16)
            .frame(width: Self.width)
            .background(GlassBackground())
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .animation(.easeInOut(duration: 0.22), value: model.form != nil)
            .animation(.easeInOut(duration: 0.22), value: model.trade.isExpanded)
            .contextMenu { // same items as the `⋯` menu (FR-WIN-11)
                Button("Hide Window", action: actions.hide)
                Divider()
                Button("Delete Trade…", role: .destructive, action: actions.delete)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Header

struct StickerHeader: View {
    let model: StickerModel
    let actions: StickerActions

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.monogram(model.trade.base))
                Text(String(model.trade.base.prefix(1))).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.trade.base) / \(model.trade.quote)").font(.system(size: 16, weight: .semibold))
                Text("\(model.trade.direction == .buyFirst ? "BUY-FIRST" : "SELL-FIRST") · Spot · \(model.trade.exchange.capitalized)")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 4)
            StatusBadge(status: model.status)
            Menu {
                Button("Hide Window", action: actions.hide)
                Divider()
                Button("Delete Trade…", role: .destructive, action: actions.delete)
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}

struct StatusBadge: View {
    let status: TradeStatus

    var body: some View {
        Text(status == .open ? "OPEN" : status == .closed ? "CLOSED" : "EMPTY")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Theme.accent.opacity(status == .open ? 0.30 : 0.14)))
            .foregroundStyle(status == .open ? Color.white : Theme.secondaryText)
    }
}

// MARK: Price

struct PriceRow: View {
    let model: StickerModel
    let freshness: Freshness
    let usable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(model.currentPrice.map(NumberFormat.price) ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    .opacity(usable || model.currentPrice == nil ? 1 : 0.5)
                if let change = model.price.change24h { ChangePill(change: change, dimmed: !usable) }
                Spacer(minLength: 0)
                FreshnessLabel(state: model.price, freshness: freshness)
            }
            if model.price.connection == .reconnecting || model.price.connection == .disconnected, model.price.tick != nil || model.price.connection == .disconnected {
                Label(model.price.connection == .disconnected ? "No connection" : "Reconnecting…", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
        }
    }
}

struct ChangePill: View {
    let change: Decimal
    let dimmed: Bool

    var body: some View {
        let color = Theme.pnl(NumberFormat.displayedPercent(change))
        HStack(spacing: 3) {
            Text(NumberFormat.displayedPercent(change) > 0 ? "▲" : NumberFormat.displayedPercent(change) < 0 ? "▼" : "")
            Text(NumberFormat.signedPercent(change)).monospacedDigit()
            Text("24h").foregroundStyle(Theme.secondaryText)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.18)))
        .foregroundStyle(color)
        .opacity(dimmed ? 0.5 : 1)
    }
}

struct FreshnessLabel: View {
    let state: PriceState
    let freshness: Freshness

    var body: some View {
        if freshness == .fresh && state.connection == .connected {
            Text("● Live").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        } else if let received = state.receivedAt {
            Label("Price from " + received.formatted(.dateTime.hour().minute().second()), systemImage: "clock")
                .font(.system(size: 11)).foregroundStyle(Theme.warning)
        } else {
            Text("Waiting for price…").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: Numbers

struct NumbersBlock: View {
    let model: StickerModel
    let usable: Bool

    var body: some View {
        let summary = model.summary, pnl = model.pnl
        let closed = model.status == .closed
        let total = closed ? pnl.realized : pnl.total
        let dim = !closed && !usable

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledValue(label: "Entry (avg)", value: summary.entryPrice.map(NumberFormat.price) ?? "—")
                    LabeledValue(label: "Amount", value: closed ? "—" : "\(NumberFormat.quantity(summary.openQuantity)) \(model.trade.base)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(total.map(NumberFormat.signedQuote) ?? "—").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(model.trade.quote).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                    }
                    .foregroundStyle(Theme.pnl(total.map(NumberFormat.displayedQuote)))
                    .opacity(dim ? 0.45 : 1)
                    if let ratio = closed ? finalRatio(summary) : pnl.ratio {
                        HStack(spacing: 3) {
                            Text(NumberFormat.displayedPercent(ratio) > 0 ? "▲" : NumberFormat.displayedPercent(ratio) < 0 ? "▼" : "")
                            Text(NumberFormat.signedPercent(ratio)).monospacedDigit()
                            if closed { Text("FINAL").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText) }
                        }
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.pnl(NumberFormat.displayedPercent(ratio))).opacity(dim ? 0.45 : 1)
                    }
                }
            }
                if dim, model.currentPrice != nil || model.status == .open {
                Label("based on old price", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func finalRatio(_ s: TradeSummary) -> Decimal? { s.openingAmount > 0 ? s.realized / s.openingAmount : nil }
}

struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
    }
}

struct SideTotals: View {
    let summary: TradeSummary

    var body: some View {
        let bought = line("Bought", summary.boughtQuantity, summary.avgBuyRate)
        let sold = line("Sold", summary.soldQuantity, summary.avgSellRate)
        let opening = summary.direction == .buyFirst
        VStack(alignment: .leading, spacing: 3) {
            Text(opening ? bought : sold)
            Text(opening ? sold : bought)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondaryText)
    }

    private func line(_ title: String, _ quantity: Decimal, _ rate: Decimal?) -> String {
        guard quantity > 0, let rate else { return "\(title) —" }
        return "\(title) \(NumberFormat.quantity(quantity)) @ \(NumberFormat.price(rate))"
    }
}

// MARK: Actions

struct ActionRow: View {
    let model: StickerModel

    var body: some View {
        let opening = model.trade.direction.openingSide
        let open = model.summary.openQuantity > 0
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                pill("Add transaction") { model.openForm(side: opening) }
                if model.status == .open {
                    Button("Close") { model.openCloseForm() }
                        .buttonStyle(PillStyle(fill: Theme.accent)).disabled(!open)
                }
            }
            if model.status != .empty {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { model.setExpanded(!model.trade.isExpanded) }
                } label: {
                    let n = model.transactions.count
                    Text("\(n) transaction\(n == 1 ? "" : "s") \(model.trade.isExpanded ? "⌃" : "⌄")")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func pill(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(PillStyle(fill: Theme.field)).disabled(!enabled)
    }
}

struct PillStyle: ButtonStyle {
    let fill: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.35))
    }
}

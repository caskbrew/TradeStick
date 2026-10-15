import AppKit
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
    public static let width: CGFloat = 420

    let model: StickerModel
    let actions: StickerActions

    public init(model: StickerModel, actions: StickerActions) {
        self.model = model
        self.actions = actions
    }

    /// Width of the form drawer including the gap to the card.
    public static let formDrawerWidth: CGFloat = FormDrawer.gap + FormDrawer.panelWidth

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let freshness = model.price.freshness(at: context.date)
            let usable = freshness == .fresh && model.price.connection == .connected
            let card = VStack(alignment: .leading, spacing: 12) {
                StickerHeader(model: model, actions: actions, live: usable)
                PriceRow(model: model, freshness: freshness, usable: usable)
                if model.status == .empty {
                    Text("Add first transaction").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                } else {
                    NumbersBlock(model: model, usable: usable)
                }
                BottomSection(model: model)
            }
            .padding(16)
            .frame(width: Self.width)
            .background(GlassBackground())
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .contextMenu { // same items as the `⋯` menu (FR-WIN-11)
                Button("Hide Window", action: actions.hide)
                Divider()
                Button("Delete Trade…", role: .destructive, action: actions.delete)
            }
            // The card never moves; the form drawer grows out of one side of it. With both the list and
            // the form open the outline is an "L".
            HStack(alignment: .top, spacing: 0) {
                if model.formOnLeft { FormDrawer(model: model) }
                card
                if !model.formOnLeft { FormDrawer(model: model) }
            }
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.contentSizeChanged($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.formOnLeft ? .topTrailing : .topLeading)
        }
    }
}

/// The add/edit form as a separate glass panel that slides out sideways from the card.
struct FormDrawer: View {
    static let panelWidth: CGFloat = 300
    static let gap: CGFloat = 10
    private static let duration = 0.22

    let model: StickerModel
    @State private var reveal: CGFloat
    @State private var rendered: Bool

    init(model: StickerModel) {
        self.model = model
        let open = model.form != nil
        _reveal = State(initialValue: open ? Self.panelWidth + Self.gap : 0)
        _rendered = State(initialValue: open)
    }

    var body: some View {
        let left = model.formOnLeft
        panel
            .padding(left ? .trailing : .leading, Self.gap)
            .frame(width: reveal, alignment: left ? .topTrailing : .topLeading)
        .clipped()
        .onChange(of: model.form != nil) { _, open in
            if open {
                rendered = true
                withAnimation(.easeInOut(duration: Self.duration)) { reveal = Self.panelWidth + Self.gap }
            } else {
                withAnimation(.easeInOut(duration: Self.duration)) { reveal = 0 }
                Task {
                    try? await Task.sleep(for: .milliseconds(Int(Self.duration * 1000) + 20))
                    if model.form == nil { rendered = false }
                }
            }
        }
    }

    @ViewBuilder
    private var panel: some View {
        if rendered {
            TransactionForm(model: model)
                .padding(16)
                .frame(width: Self.panelWidth)
                .background(GlassBackground())
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
        }
    }
}

// MARK: Bottom section

private struct MeasuringKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True for the invisible copy used only to learn a layout's height: it must not take focus or shortcuts.
    var isMeasuring: Bool {
        get { self[MeasuringKey.self] }
        set { self[MeasuringKey.self] = newValue }
    }
}

/// Actions, form and transaction list. Everything above it never moves. This section sits in a clip whose height
/// animates, so new content is revealed from the top downward as the card grows, and on shrinking the old
/// content stays visible until the clip has closed over it.
struct BottomSection: View {
    let model: StickerModel

    private struct Shape: Equatable {
        var expanded: Bool
    }

    private static let duration = 0.22

    @State private var shown: Shape
    @State private var height: CGFloat?
    @State private var targetHeight: CGFloat = 0

    init(model: StickerModel) {
        self.model = model
        _shown = State(initialValue: Shape(expanded: model.trade.isExpanded))
    }

    private var target: Shape { Shape(expanded: model.trade.isExpanded) }

    var body: some View {
        content(shown)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: height, alignment: .top)
            .clipped()
            // Invisible copy in the target state: tells us how tall the section is going to be.
            .background(alignment: .top) {
                content(target)
                    .environment(\.isMeasuring, true)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden().allowsHitTesting(false).accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { targetHeight = $0 }
            }
            .onChange(of: targetHeight) { _, new in
                if height == nil { height = new } else { withAnimation(.easeInOut(duration: Self.duration)) { height = new } }
            }
            .onChange(of: target) { old, new in
                let shrinking = old.expanded && !new.expanded
                if shrinking {
                    Task {
                        try? await Task.sleep(for: .milliseconds(Int(Self.duration * 1000) + 20))
                        shown = target // by now the clip has closed over the old content
                    }
                } else {
                    shown = new
                }
            }
    }

    @ViewBuilder
    private func content(_ shape: Shape) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ActionRow(model: model)
            if shape.expanded {
                Divider().overlay(Theme.divider)
                TransactionList(model: model)
            }
        }
    }
}

// MARK: Header

struct StickerHeader: View {
    let model: StickerModel
    let actions: StickerActions
    /// Connected and the price is fresh.
    let live: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if let data = model.iconData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().clipShape(Circle())
                } else {
                    Circle().fill(Theme.monogram(model.trade.base))
                    Text(String(model.trade.base.prefix(1))).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 38, height: 38)
            .task { await model.loadIcon() }

            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.trade.base) / \(model.trade.quote)").font(.system(size: 16, weight: .semibold))
                Text("\(model.trade.direction == .buyFirst ? "BUY" : "SELL") · Spot · \(model.trade.exchange.capitalized)")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 4)
            if live { LiveDot() } else if model.wantsPrice { ProgressView().controlSize(.small).scaleEffect(0.7).help("Connecting to the exchange…") }
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

struct LiveDot: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.positive).frame(width: 7, height: 7)
            Text("Live").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        }
    }
}

struct FreshnessLabel: View {
    let state: PriceState
    let freshness: Freshness

    var body: some View {
        if freshness == .fresh && state.connection == .connected {
            EmptyView() // shown as the dot in the header
        } else if let received = state.receivedAt {
            Label("Price \(Elapsed.duration(Date().timeIntervalSince(received))) old", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.warning).lineLimit(1).fixedSize()
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

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PnL").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(total.map(NumberFormat.signedQuote) ?? "—").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.5) // a 4-digit PnL used to wrap its last digit
                        Text(model.trade.quote).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondaryText)
                            .lineLimit(1).fixedSize()
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
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle().fill(Theme.divider).frame(width: 1)

                VStack(alignment: .leading, spacing: 6) {
                    LabeledValue(label: "Entry (avg)", value: summary.entryPrice.map(NumberFormat.price) ?? "—")
                    LabeledValue(label: "Amount", value: closed ? "—" : "\(NumberFormat.quantity(summary.openQuantity)) \(model.trade.base)")
                    LabeledValue(label: "Cost", value: closed ? "—" : "\(NumberFormat.amount(summary.openCost)) \(model.trade.quote)")
                    LabeledValue(label: "Value", value: closed ? "—" : model.currentPrice.map { "\(NumberFormat.amount(summary.openQuantity * $0)) \(model.trade.quote)" } ?? "—")
                }
                .frame(width: 168)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.divider, lineWidth: 1))
            DurationLabel(model: model)
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
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

/// Elapsed trade time, shown under the PnL as trade metadata.
struct DurationLabel: View {
    let model: StickerModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            if let span = model.duration(at: ctx.date) {
                Label(Elapsed.duration(span), systemImage: "clock").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

// MARK: Actions

struct ActionRow: View {
    let model: StickerModel

    var body: some View {
        let opening = model.trade.direction.openingSide
        let open = model.summary.openQuantity > 0
        let expanded = model.trade.isExpanded
        HStack(spacing: 8) {
            if model.status == .open {
                Button { model.openCloseForm() } label: { Label("Close", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .buttonStyle(PillStyle(fill: Theme.accent)).disabled(!open)
            }
            Button { model.openForm(side: opening) } label: { Label("Add", systemImage: "plus").frame(maxWidth: .infinity) }
                .buttonStyle(PillStyle(fill: Theme.field))
                .help("Add a buy or sell record (no order is sent)")
            if model.status != .empty {
                Button { model.setExpanded(!expanded) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "list.bullet")
                        Text("\(model.transactions.count) transaction\(model.transactions.count == 1 ? "" : "s")").monospacedDigit().lineLimit(1).fixedSize()
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(PillStyle(fill: expanded ? Theme.accent.opacity(0.35) : Theme.field, flexible: false))
                .help(expanded ? "Hide transactions" : "Show transactions")
            }
        }
    }
}

struct PillStyle: ButtonStyle {
    let fill: Color
    var flexible = true
    var minHeight: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: flexible ? .infinity : nil, minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.35))
    }
}

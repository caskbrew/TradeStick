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
    public static let width: CGFloat = 330

    let model: StickerModel
    let actions: StickerActions

    public init(model: StickerModel, actions: StickerActions) {
        self.model = model
        self.actions = actions
    }

    /// Width of the form drawer including the gap to the card.
    public static let listWidth: CGFloat = ListDrawer.width
    public static let formDrawerWidth: CGFloat = FormDrawer.gap + FormDrawer.panelWidth

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let freshness = model.price.freshness(at: context.date)
            let usable = freshness == .fresh && model.price.connection == .connected
            let card = VStack(alignment: .leading, spacing: 0) {
              VStack(alignment: .leading, spacing: 4) {
                StickerHeader(model: model, actions: actions, live: usable)
                PriceRow(model: model, freshness: freshness, usable: usable)
                if model.status == .empty {
                    Button { model.addTransaction() } label: { Label("Add first transaction", systemImage: "plus").frame(maxWidth: .infinity) }
                        .buttonStyle(PillStyle(fill: Theme.field))
                } else {
                    CompactNumbers(model: model, usable: usable)
                }
              }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(width: Self.width)
            .background(GlassBackground(radius: 14))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .contextMenu { StickerMenuItems(model: model, actions: actions) } // same items as the `⋯` menu (FR-WIN-11)
            card
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.contentSizeChanged($0) }
                .scaleEffect(model.scale, anchor: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Root of the form's own window: the drawer pinned to the edge that touches the card.
public struct FormWindowView: View {
    let model: StickerModel

    public init(model: StickerModel) { self.model = model }

    public var body: some View {
        FormDrawer(model: model)
            .fixedSize()
            .scaleEffect(model.scale, anchor: model.formOnLeft ? .topTrailing : .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.formOnLeft ? .topTrailing : .topLeading)
    }
}

/// The add/edit form as a separate glass panel that slides out sideways from the card.
struct FormDrawer: View {
    static let panelWidth: CGFloat = 290
    static let gap: CGFloat = 4
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
            TransactionForm(model: model).id(model.formID)
                .frame(minHeight: model.cardHeight - 20, alignment: .top)
                .padding(10)
                .frame(width: Self.panelWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.formHeightChanged($0) }
                .background(GlassBackground(radius: 14))
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
        }
    }
}

// MARK: List drawer

/// The transaction list as a separate glass panel that slides out under the card (or over it).
struct ListDrawer: View {
    static let width: CGFloat = 330
    static let gap: CGFloat = 4
    private static let duration = 0.22

    let model: StickerModel
    @State private var reveal: CGFloat = 0
    @State private var measured: CGFloat = 0

    var body: some View {
        let top = model.listOnTop
        TransactionList(model: model)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(width: Self.width)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = $0; model.listHeightChanged($0 + Self.gap) }
            .background(GlassBackground(radius: 14))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .padding(top ? .bottom : .top, Self.gap)
            .frame(height: reveal, alignment: top ? .bottom : .top)
            .clipped()
            .onChange(of: model.trade.isExpanded) { _, open in move(open) }
            .onChange(of: measured) { _, _ in if model.trade.isExpanded { move(true) } }
            .onAppear { if model.trade.isExpanded { move(true) } }
    }

    private func move(_ open: Bool) {
        withAnimation(.easeInOut(duration: Self.duration)) { reveal = open ? measured + Self.gap : 0 }
    }
}

/// Root of the list's own window.
public struct ListWindowView: View {
    let model: StickerModel

    public init(model: StickerModel) { self.model = model }

    public var body: some View {
        ListDrawer(model: model)
            .fixedSize()
            .scaleEffect(model.scale, anchor: model.listOnTop ? .bottomLeading : .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.listOnTop ? .bottomLeading : .topLeading)
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
                    Text(String(model.trade.base.prefix(1))).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 30, height: 30)
            .task { await model.loadIcon() }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("\(model.trade.base) / \(model.trade.quote)").font(.system(size: 14, weight: .semibold))
                    DurationLabel(model: model)
                }
                HStack(spacing: 8) {
                    Text("\(model.trade.direction == .buyFirst ? "BUY" : "SELL") · Spot · \(model.trade.exchange.capitalized)")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    if live { LiveDot() } else if model.wantsPrice { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12).help("Connecting to the exchange…") }
                }
            }
            Spacer(minLength: 4)
            if model.status != .open { StatusBadge(status: model.status) }
            // Each button is a 26pt circle centred on its glyph: the click area is the circle, not the glyph.
            HStack(spacing: -3) {
            Button { model.togglePin() } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin").rotationEffect(.degrees(-45))
                    .frame(width: 26, height: 26).contentShape(Circle()).offset(y: -6)
            }
            .buttonStyle(.plain).foregroundStyle(model.isPinned ? Color.accentColor : Theme.secondaryText)
            .help(model.isPinned ? "Unpin: allow moving the window" : "Pin: lock the window position")
            ZStack {
                // The glyph is a plain view; the menu on top only catches the click.
                Text("\u{22EE}").font(.system(size: 16, weight: .bold)).allowsHitTesting(false)
                Menu {
                    StickerMenuItems(model: model, actions: actions)
                } label: {
                    Color.clear.frame(width: 26, height: 26).contentShape(Circle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .clipShape(Circle())
            }
            .frame(width: 26, height: 26).offset(y: -6)
            }
            .padding(.trailing, -8)
        }
        .background { ShortcutLayer(model: model, actions: actions) }
    }
}

/// The items of the `⋯` menu and the context menu. Titles carry their shortcut because a SwiftUI menu in
/// a borderless panel does not reliably show or fire `.keyboardShortcut`; `ShortcutLayer` does the firing.
struct StickerMenuItems: View {
    let model: StickerModel
    let actions: StickerActions

    var body: some View {
        let expanded = model.trade.isExpanded
        Button("Add Tx") { model.addTransaction() }.keyboardShortcut("b")
        Button("\(expanded ? "Hide" : "Show") history") { model.toggleList() }
            .keyboardShortcut("l").disabled(model.status == .empty)
        if model.status == .open {
            Divider()
            let closing = model.trade.direction == .buyFirst ? "Sell" : "Buy back"
            Button("\(closing) all at market · \(NumberFormat.quantity(model.summary.openQuantity)) \(model.trade.base)") {
                Task { await model.requestClose(recoverInvestment: false) }
            }
            .keyboardShortcut("e")
            .disabled(model.closePlan(recoverInvestment: false) == nil)
            if model.trade.direction == .buyFirst {
                Button(recoverTitle) { Task { await model.requestClose(recoverInvestment: true) } }.keyboardShortcut("r")
                                        .disabled(model.closePlan(recoverInvestment: true) == nil)
            }
        }
        Divider()
        Button("Zoom In") { model.zoom(by: 0.1) }.keyboardShortcut("+")
        Button("Zoom Out") { model.zoom(by: -0.1) }.keyboardShortcut("-")
        Button("Default") { model.zoom(by: 0) }.keyboardShortcut("0")
        Divider()
        Button(model.isPinned ? "Unpin Window" : "Pin Window") { model.togglePin() }.keyboardShortcut("p")
        Divider()
        Button("Hide Window", action: actions.hide).keyboardShortcut("w")
        Divider()
        Button("Delete Trade…", role: .destructive, action: actions.delete).keyboardShortcut(.delete, modifiers: [.option, .command])
    }
}

extension StickerMenuItems {
    fileprivate var recoverTitle: String {
        guard let quantity = model.recoverQuantity else { return "Sell enough to recover the investment" }
        let invested = model.summary.boughtAmount - model.summary.soldAmount
        return "Sell \(NumberFormat.quantity(quantity)) \(model.trade.base) to recover \(NumberFormat.amount(invested)) \(model.trade.quote)"
    }
}

/// Invisible buttons that own the keyboard shortcuts while the sticker is the key window.
struct ShortcutLayer: View {
    let model: StickerModel
    let actions: StickerActions

    var body: some View {
        Group {
            Button("") { model.toggleForm() }.keyboardShortcut("b")
            Button("") { model.toggleList() }.keyboardShortcut("l")
            Button("") { Task { await model.requestClose(recoverInvestment: false) } }.keyboardShortcut("e")
            Button("") { Task { await model.requestClose(recoverInvestment: true) } }.keyboardShortcut("r")
            Button("") { model.togglePin() }.keyboardShortcut("p")
            Button("") { actions.hide() }.keyboardShortcut("w")
            Button("") { actions.delete() }.keyboardShortcut(.delete, modifiers: [.command, .option])
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
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
                    .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
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
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 7).padding(.vertical, 2)
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

/// Compact view: entry and amount on the left, PnL on the right, no frame and no extras.
struct CompactNumbers: View {
    let model: StickerModel
    let usable: Bool

    var body: some View {
        let summary = model.summary, pnl = model.pnl
        let closed = model.status == .closed
        let total = closed ? pnl.realized : pnl.total
        let ratio = closed ? (summary.openingAmount > 0 ? summary.realized / summary.openingAmount : nil) : pnl.ratio
        let dim = !closed && !usable
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                LabeledValue(label: "Rate", value: summary.entryPrice.map(NumberFormat.price) ?? "—")
                LabeledValue(label: model.trade.base, value: closed ? "—" : NumberFormat.quantity(summary.openQuantity))
                LabeledValue(label: model.trade.quote, value: closed ? "—" : NumberFormat.amount(summary.openCost))
            }
            .frame(maxHeight: .infinity, alignment: .bottomLeading)
            Rectangle().fill(Theme.divider).frame(width: 1)
            VStack(alignment: .trailing, spacing: 2) {
                Text(total.map(NumberFormat.signedQuote) ?? "—").font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .foregroundStyle(Theme.pnl(total.map(NumberFormat.displayedQuote)))
                HStack(spacing: 6) {
                    Text(model.trade.quote).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondaryText)
                    if let ratio {
                        HStack(spacing: 3) {
                            Text(NumberFormat.displayedPercent(ratio) > 0 ? "▲" : NumberFormat.displayedPercent(ratio) < 0 ? "▼" : "")
                            Text(NumberFormat.signedPercent(ratio)).monospacedDigit()
                        }
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.pnl(NumberFormat.displayedPercent(ratio)))
                    }
                }
                .lineLimit(1).fixedSize()
            }
            .layoutPriority(1)
            .opacity(dim ? 0.45 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

/// Elapsed trade time, shown under the PnL as trade metadata.
struct DurationLabel: View {
    let model: StickerModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            if let span = model.duration(at: ctx.date) {
                Label(Elapsed.duration(span), systemImage: "clock").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

// MARK: Actions

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

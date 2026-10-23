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
    public static let width: CGFloat = 280
    /// Padding of the card; the list uses `ListColumns.inset`.
    static let cardInset: CGFloat = 8.5

    let model: StickerModel
    let actions: StickerActions

    public init(model: StickerModel, actions: StickerActions) {
        self.model = model
        self.actions = actions
    }

    /// Width of the form drawer including the gap to the card.
    public static let listWidth: CGFloat = ListDrawer.width
    public static let formDrawerWidth: CGFloat = FormDrawer.gap + FormDrawer.panelWidth

    @State private var fullHeight: CGFloat = 0
    @State private var compactHeight: CGFloat = 0
    @Namespace private var flight

    /// Both layouts stay in the tree, cross-faded; the card's height animates between their two measured heights,
    /// and the window follows (see StickerWindow). Double-click anywhere on the card switches the view.
    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let freshness = model.price.freshness(at: context.date)
            let usable = freshness == .fresh && model.price.connection == .connected
            let compact = model.isCompact
            let full = VStack(alignment: .leading, spacing: 0) {
                StickerHeader(model: model, actions: actions, live: usable, freshness: freshness)
                PriceRow(model: model, usable: usable)
                Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 3.5)
                TotalsRow(model: model).padding(.top, 4.3)
            }
            .padding(.horizontal, Self.cardInset).padding(.top, 5.5).padding(.bottom, 6.5)
            .frame(width: Self.width, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0; model.fullHeight = $0 }
            let short = CompactCard(model: model, live: usable, usable: usable)
                .padding(.horizontal, Self.cardInset).padding(.top, 8).padding(.bottom, 5.2)
                .frame(width: Self.width, alignment: .top)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { compactHeight = $0 }
            let height = compact ? compactHeight : fullHeight
            let card = ZStack(alignment: .top) {
                full.opacity(compact ? 0 : 1).allowsHitTesting(!compact)
                short.opacity(compact ? 1 : 0).allowsHitTesting(compact)
            }
            .frame(width: Self.width, height: height > 0 ? height : nil, alignment: .top)
            .clipped()
            .animation(.easeInOut(duration: 0.25), value: compact)
            .background(StickerGlass(radius: 15))
            .background(WindowDragArea(onDoubleClick: { model.toggleCompact() }))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .environment(\.flight, Flight(space: flight, compact: compact))
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
    static let gap: CGFloat = ListDrawer.gap
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
                .frame(height: model.cardHeight - 16, alignment: .top) // as high as the card
                .padding(8)
                .frame(width: Self.panelWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.formHeightChanged($0) }
                .background(StickerGlass(radius: 15))
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
        }
    }
}

// MARK: List drawer

/// The transaction list as a separate glass panel that slides out under the card (or over it).
struct ListDrawer: View {
    static let width: CGFloat = StickerView.width
    static let gap: CGFloat = 8.0 / 3 // a third of the reference's gap
    private static let duration = 0.22

    let model: StickerModel
    @State private var reveal: CGFloat = 0
    @State private var measured: CGFloat = 0

    var body: some View {
        let top = model.listOnTop
        TransactionList(model: model)
            .frame(width: Self.width)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured = $0; model.listHeightChanged($0 + Self.gap) }
            .background(StickerGlass(radius: 15))
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

/// The coin's logo, or a coloured monogram while there is none.
struct CoinIcon: View {
    let model: StickerModel
    let size: CGFloat

    var body: some View {
        ZStack {
            if let data = model.iconData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().clipShape(Circle())
            } else {
                Circle().fill(Theme.monogram(model.trade.base))
                Text(String(model.trade.base.prefix(1))).font(.system(size: size * 0.47, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .task { await model.loadIcon() }
    }
}

struct StickerHeader: View {
    let model: StickerModel
    let actions: StickerActions
    /// Connected and the price is fresh.
    let live: Bool
    let freshness: Freshness

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CoinIcon(model: model, size: 27)
                .flies("icon", short: false)
                .overlay(WindowDragArea(onDoubleClick: { model.toggleCompact() }))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("\(model.trade.base) / \(model.trade.quote)").font(.system(size: 15, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                        .flies("title", .leading, short: false)
                    DurationLabel(model: model).flies("time", short: false)
                }
                .frame(height: 18)
                HStack(spacing: 5) {
                    Text("\(live || !model.wantsPrice ? (model.trade.direction == .buyFirst ? "BUY · " : "SELL · ") : "")\(model.trade.exchange.capitalized)").lineLimit(1).layoutPriority(1) // the side steps aside while the note needs the room
                    Text("·")
                    if live { LiveDot() } else if model.wantsPrice {
                        ConnectionNote(state: model.price, freshness: freshness)
                    }
                }
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
                .frame(height: 14)
            }
            .overlay(WindowDragArea(onDoubleClick: { model.toggleCompact() }))
            Spacer(minLength: 4)
            if model.status != .open && model.status != .empty { StatusBadge(status: model.status) }
            // Each button is a 26pt circle centred on its glyph: the click area is the circle, not the glyph.
            HStack(spacing: 0) {
                Button { model.togglePin() } label: {
                    Image(systemName: model.isPinned ? "pin.fill" : "pin").font(.system(size: 13)).rotationEffect(.degrees(-45))
                        .frame(width: 26, height: 26).contentShape(Circle())
                }
                .buttonStyle(.plain).foregroundStyle(model.isPinned ? Theme.pin : Theme.secondaryText)
                .help(model.isPinned ? "Unpin: allow moving the window" : "Pin: lock the window position")
                .offset(x: 9) // closer to the menu dots
                ZStack {
                    // The glyph is a plain view; the menu on top only catches the click.
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).rotationEffect(.degrees(90)).allowsHitTesting(false)
                    Menu {
                        StickerMenuItems(model: model, actions: actions)
                    } label: {
                        Color.clear.frame(width: 26, height: 26).contentShape(Circle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .clipShape(Circle())
                }
                .frame(width: 26, height: 26)
            }
            .padding(.trailing, -7).offset(y: -1.5)
        }
        .frame(height: 32, alignment: .top)
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
        Button("Add Transaction") { model.addTransaction() }.keyboardShortcut("b")
        Button("Import Transaction") { model.importHistory() }.keyboardShortcut("b", modifiers: [.command, .shift])
        Button("\(expanded ? "Hide" : "Show") Transactions") { model.toggleList() }
            .keyboardShortcut("l").disabled(model.status == .empty)
        Toggle("Compact", isOn: Binding(get: { model.isCompact }, set: { _ in model.toggleCompact() })).keyboardShortcut("s")
        Divider()
        Button("Zoom \(model.zoomPercent(by: StickerModel.zoomStep))%") { model.zoom(by: StickerModel.zoomStep) }
            .keyboardShortcut("+").disabled(model.scale >= StickerModel.scaleRange.upperBound)
        Button("Zoom \(model.zoomPercent(by: -StickerModel.zoomStep))%") { model.zoom(by: -StickerModel.zoomStep) }
            .keyboardShortcut("-").disabled(model.scale <= StickerModel.scaleRange.lowerBound)
        Button("Zoom 100%") { model.zoom(by: 0) }.keyboardShortcut("0")
        Divider()
        Button(model.isPinned ? "Unpin Window" : "Pin Window") { model.togglePin() }.keyboardShortcut("p")
        Button("Hide Window", action: actions.hide).keyboardShortcut("w")
        Divider()
        Button("Delete Stick…", role: .destructive, action: actions.delete).keyboardShortcut(.delete, modifiers: [.option, .command])
    }
}

/// Invisible buttons that own the keyboard shortcuts while the sticker is the key window.
struct ShortcutLayer: View {
    let model: StickerModel
    let actions: StickerActions

    var body: some View {
        Group {
            Button("") { model.toggleForm() }.keyboardShortcut("b")
            Button("") { model.importHistory() }.keyboardShortcut("b", modifiers: [.command, .shift])
            Button("") { model.toggleList() }.keyboardShortcut("l")
            Button("") { model.toggleCompact() }.keyboardShortcut("s")
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

extension StickerModel {
    /// The trade's headline result: PnL in the quote currency (realized once closed) and its percent.
    var headline: (total: Decimal?, ratio: Decimal?) {
        let pnl = pnl, closed = status == .closed
        return (closed ? pnl.realized : pnl.total, closed ? (summary.openingAmount > 0 ? summary.realized / summary.openingAmount : nil) : pnl.ratio)
    }
}

/// The current price, big.
struct PriceText: View {
    let model: StickerModel
    let usable: Bool
    var size: CGFloat = 29
    var height: CGFloat = 35

    var body: some View {
        Text(model.currentPrice.map(NumberFormat.shownPrice) ?? "—")
            .font(.system(size: size, weight: .bold)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.4)
            .opacity(usable || model.currentPrice == nil ? 1 : 0.5)
            .frame(height: height, alignment: .leading)
    }
}

/// The result in the quote currency, big and flush right; the currency is a small tag laid over the end of the
/// number, with a clear rounded margin round it that hides a little of the digits. With `fill` the number is
/// enlarged (within the row's height) until it is that wide.
struct ResultText: View {
    let model: StickerModel
    let usable: Bool
    var size: CGFloat = 29
    var unit: CGFloat = 9.5
    var height: CGFloat = 35
    var fill: CGFloat?
    var room: CGFloat? // the width the number may take: a longer one shrinks to it

    var body: some View {
        let total = model.headline.total
        let text = total.map { NumberFormat.signedQuote($0, fixed: model.quoteFixed) } ?? "—"
        let fontSize = fill.map { min(max(size * $0 / max(Ruler.width(text, size: size, weight: .bold), 1), size), size * 1.2) }
            ?? room.map { min(size, size * $0 / max(Ruler.width(text, size: size, weight: .bold), 1)) } ?? size
        let margin: CGFloat = 3 // the same on all four sides of the letters (cap height, not line height, vertically)
        let box = CGSize(width: Ruler.width(model.trade.quote, size: unit, weight: .bold) + 2 * margin, height: unit * 0.73 + 2 * margin)
        ZStack(alignment: .bottomTrailing) {
            Text(text).font(.system(size: fontSize, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.25)
                .frame(maxWidth: .infinity, alignment: .trailing).frame(height: height, alignment: .bottom) // a shrunk number still sits on the tag
                .offset(y: -(size - fontSize) * 0.15) // and not so deep in it, the smaller it is
                .mask(Notch(size: box, drop: 1.5, push: margin).fill(style: FillStyle(eoFill: true)))
            Text(model.trade.quote).font(.system(size: unit, weight: .bold)).lineLimit(1)
                .frame(width: box.width, height: box.height).offset(x: margin, y: 1.5) // the letters end where the line under them ends
        }
        .foregroundStyle(Theme.pnl(total.map { NumberFormat.displayedQuote($0, fixed: model.quoteFixed) }))
        .opacity(model.status != .closed && !usable ? 0.45 : 1)
        .frame(height: height)
    }
}

/// The whole rectangle with a rounded hole in its bottom right corner (even-odd fill): cuts a number round its tag.
struct Notch: Shape {
    let size: CGSize
    var drop: CGFloat = 0
    var push: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -10, dy: -10)) // wider than the row, so the digits are not cut at its edges
        path.addRoundedRect(in: CGRect(x: rect.maxX - size.width + push, y: rect.maxY - size.height + drop, width: size.width, height: size.height), cornerSize: CGSize(width: 4, height: 4))
        return path
    }
}

/// The 24h change as coloured text: arrow, percent without a sign, "24h".
struct ChangeText: View {
    let change: Decimal
    var size: CGFloat = 13

    var body: some View {
        let shown = NumberFormat.displayedPercent(change)
        let text = NumberFormat.signedPercent(change)
        HStack(spacing: 5) {
            Text(shown > 0 ? "▲" : shown < 0 ? "▼" : "")
            HStack(spacing: 7) {
                Text(text.hasPrefix("+") || text.hasPrefix("\u{2212}") ? String(text.dropFirst()) : text).monospacedDigit().fontWeight(.semibold).minimumScaleFactor(0.5)
                Text("24h").foregroundStyle(Theme.secondaryText).fontWeight(.regular).minimumScaleFactor(0.5)
            }
        }
        .font(.system(size: size, weight: .medium)).foregroundStyle(Theme.pnl(shown)).lineLimit(1)
    }
}

/// Price and 24h change on the left, a divider, the result on the right: its big number, and under it the
/// percent and the profit in coins (what stays after selling enough to get the investment back).
struct PriceRow: View {
    let model: StickerModel
    let usable: Bool

    var body: some View {
        let ratio = model.headline.ratio, coins = model.gramPnL
        // The price column is as wide as the price (at most so wide that the result keeps its room); no flexible
        // views here, so nothing can push the row wider than the card.
        let priceWidth = min(Ruler.width(model.currentPrice.map(NumberFormat.shownPrice) ?? "—", size: 29, weight: .bold) + 2, 138)
        let room = StickerView.width - 2 * StickerView.cardInset - max(priceWidth, 86) - 17
        // The line under the result and the currency tag are the same size: both shrink by what the line needs.
        let percentText = ratio.map { NumberFormat.signedPercent($0) }, gramText = coins.map { "\(NumberFormat.signedQuantity($0)) \(model.trade.base)" }
        let lineWidth = Ruler.width(percentText ?? "", size: 9.5, weight: .medium) + Ruler.width(gramText ?? "", size: 9.5, weight: .regular) + (percentText != nil && gramText != nil ? 5 : 0)
        let lineSize = 9.5 * min(1, (room - 12) / max(lineWidth, 1))
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                PriceText(model: model, usable: usable).flies("price", .leading, short: false)
                // Hidden while the price is stale (the header says why); the room stays, so the card keeps its height.
                Group { if usable, let change = model.price.change24h { ChangeText(change: change) } else { Color.clear } }
                    .frame(height: 16, alignment: .leading)
            }
            .frame(width: max(priceWidth, 86), alignment: .leading)
            Rectangle().fill(Theme.line).frame(width: 1, height: 41.5).padding(.top, 6)
            VStack(alignment: .trailing, spacing: 0) {
                ResultText(model: model, usable: usable, size: 33, unit: lineSize, height: 39, room: room).flies("result", .trailing, short: false)
                // One Text, so both parts shrink together when the room is short.
                Group {
                    let percent = ratio.map { Text(NumberFormat.signedPercent($0)).fontWeight(.medium).foregroundColor(Theme.pnl(NumberFormat.displayedPercent($0))) }
                    let gram = coins.map { Text("\(NumberFormat.signedQuantity($0)) \(model.trade.base)").foregroundColor(Theme.secondaryText) }
                    if let percent, let gram { percent + Text("  ") + gram } else if let percent { percent } else if let gram { gram } else { Text("") }
                }
                .monospacedDigit().font(.system(size: lineSize)).lineLimit(1).minimumScaleFactor(0.4) // the size of the currency tag
                .help(coins.map { _ in "Profit in \(model.trade.base): what is left after selling enough at the current price to get the investment back" } ?? "")
                .opacity(model.status != .closed && !usable ? 0.45 : 1)
                .frame(height: 12, alignment: .trailing)
            }
            .frame(width: room, alignment: .trailing)
        }
        .fixedSize(horizontal: false, vertical: true) // the divider is as high as the row
    }
}

/// The short view: logo, pair and live dot, then the 24h change, the duration and a chevron; the price and the result under them.
struct CompactCard: View {
    let model: StickerModel
    let live: Bool
    let usable: Bool

    var body: some View {
        let pair = "\(model.trade.base)/\(model.trade.quote)"
        let top = 21.5 + 10 + Ruler.width(pair, size: 12.3, weight: .bold) + 7 + 7 // icon, name, dot
        let leftWidth = min(max(top, Ruler.width(model.currentPrice.map(NumberFormat.shownPrice) ?? "—", size: 27.5, weight: .bold) + 8), 122)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    CoinIcon(model: model, size: 19.5).flies("icon", short: true).padding(.leading, 2)
                    Text("\(model.trade.base)/\(model.trade.quote)").font(.system(size: 12.3, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                        .flies("title", .leading, short: true).padding(.leading, 10)
                    Group {
                        if live { Circle().fill(Theme.dot).frame(width: 6.6, height: 6.6) }
                        else if model.wantsPrice { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12) }
                    }
                    .padding(.leading, 7)
                }
                .frame(height: 17.2)
                PriceText(model: model, usable: usable, size: 27.5, height: 33).flies("price", .leading, short: true).padding(.leading, 6)
            }
            .frame(width: leftWidth, alignment: .leading)
            // The divider has a gap between the two rows.
            VStack(spacing: 0) {
                Rectangle().fill(Theme.line).frame(width: 1, height: 15.8)
                Color.clear.frame(width: 1, height: 7)
                Rectangle().fill(Theme.line).frame(width: 1, height: 22.6)
            }
            .padding(.leading, 6).padding(.top, 1)
            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 0) {
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        if let span = model.duration(at: ctx.date) { Text(Elapsed.duration(span)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1) }
                    }
                    .flies("time", short: true)
                    Spacer(minLength: 6)
                    Button { model.togglePin() } label: {
                        Image(systemName: model.isPinned ? "pin.fill" : "pin").font(.system(size: 11)).rotationEffect(.degrees(-45))
                            .frame(width: 16, height: 17.2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(model.isPinned ? Theme.pin : Theme.secondaryText).padding(.leading, 8)
                    .help(model.isPinned ? "Unpin: allow moving the window" : "Pin: lock the window position")
                    Button { model.toggleCompact() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 10.5, weight: .semibold)).frame(width: 12, height: 17.2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).padding(.leading, 3).help("Expand")
                }
                .frame(height: 17.2)
                ResultText(model: model, usable: usable, size: 27.5, unit: 9, height: 33, fill: StickerView.width - 2 * StickerView.cardInset - leftWidth - 16.5)
                    .flies("result", .trailing, short: true)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 9.5)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct LiveDot: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.dot).frame(width: 7.5, height: 7.5)
            Text("Live")
        }
    }
}

/// In the header while the price is not live: a spinner, what is going on and for how long.
struct ConnectionNote: View {
    let state: PriceState
    let freshness: Freshness

    var body: some View {
        HStack(spacing: 3) {
            ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 11, height: 11)
            note
        }
    }

    @ViewBuilder private var note: some View {
        let age = state.receivedAt.map { Elapsed.duration(Date().timeIntervalSince($0)) }
        if state.connection == .reconnecting || state.connection == .disconnected {
            Text(age.map { "Reconnect \($0)" } ?? "Reconnecting").font(.system(size: 10.5)).foregroundStyle(Theme.warning).lineLimit(1).fixedSize()
                .help(age.map { "No connection for \($0)" } ?? "Connecting to the exchange")
        } else if let age {
            Text("Reconnect \(age)").font(.system(size: 10.5)).foregroundStyle(Theme.warning).lineLimit(1).fixedSize()
        } else {
            Text("Connecting…").font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1).fixedSize()
        }
    }
}

// MARK: Numbers

/// Titles and totals of the trade: Avg, the coin, the quote currency and Fee, each title over its number, with an
/// even gap between them.
struct TotalsRow: View {
    let model: StickerModel

    var body: some View {
        let summary = model.summary, closed = model.status == .closed
        let items: [(String, String)] = [
            ("Avg", summary.entryPrice.map(NumberFormat.shownPrice) ?? "—"),
            (model.trade.base, closed ? "—" : NumberFormat.quantity(summary.openQuantity)),
            (model.trade.quote, closed ? "—" : NumberFormat.quote(summary.openCost, fixed: model.quoteFixed)),
            ("Fee", model.totalFee.map { NumberFormat.quote($0, fixed: model.quoteFixed) } ?? "—"),
        ]
        let natural = items.map { max(Ruler.width($0.0, size: 11, weight: .regular), Ruler.width($0.1, size: 13, weight: .medium)) }
        let room = StickerView.width - 2 * StickerView.cardInset - 3 // the numbers start 3pt inside the card's padding
        let shrink = min(1, (room - 3 * 8) / max(natural.reduce(0, +), 1))
        let gap = min(30, max(8, (room - natural.reduce(0, +) * shrink) / 3))
        HStack(alignment: .top, spacing: gap) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: -0.5) {
                    Text(items[i].0).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).frame(height: 13)
                    Text(items[i].1).font(.system(size: 13, weight: .medium)).monospacedDigit().frame(height: 16) // scaled-down digits must not shrink the row
                }
                .lineLimit(1).minimumScaleFactor(0.3)
                .frame(width: natural[i] * shrink, alignment: .leading)
            }
        }
        .padding(.leading, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DurationLabel: View {
    let model: StickerModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            if let span = model.duration(at: ctx.date) {
                HStack(spacing: 5) {
                    Image(systemName: "clock").font(.system(size: 11.5))
                    Text(Elapsed.duration(span)).font(.system(size: 12.5))
                }
                .foregroundStyle(Theme.secondaryText).lineLimit(1)
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
            .padding(.horizontal, flexible ? 0 : 16) // a button that is not stretched needs room around its text
            .frame(maxWidth: flexible ? .infinity : nil, minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.35))
    }
}

/// Drags the window by pressing anywhere on it, at once, even when the app is not active (the first click does
/// not get lost on activating the app) and with any mouse or trackpad. Does nothing while the window is pinned,
/// that is, while `isMovableByWindowBackground` is off.
struct WindowDragArea: NSViewRepresentable {
    /// A double-click, also while the window is pinned.
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) { (view as? DragView)?.onDoubleClick = onDoubleClick }

    final class DragView: NSView {
        var onDoubleClick: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick { onDoubleClick(); return }
            guard let window, window.isMovableByWindowBackground else { return }
            window.performDrag(with: event)
        }
    }
}

/// Shared elements of the two views fly between their places while the card folds: the view of the side the card
/// is going to holds the place, the other follows it (position only, so neither layout changes size).
struct Flight: Sendable {
    let space: Namespace.ID
    let compact: Bool
}

extension EnvironmentValues {
    @Entry var flight: Flight?
}

private struct Flies: ViewModifier {
    @Environment(\.flight) private var flight
    let id: String, anchor: UnitPoint, short: Bool

    func body(content: Content) -> some View {
        if let flight {
            content.matchedGeometryEffect(id: id, in: flight.space, properties: .position, anchor: anchor, isSource: flight.compact == short)
        } else {
            content
        }
    }
}

extension View {
    func flies(_ id: String, _ anchor: UnitPoint = .center, short: Bool) -> some View { modifier(Flies(id: id, anchor: anchor, short: short)) }
}

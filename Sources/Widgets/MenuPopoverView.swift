import AppKit
import Domain
import Persistence
import Presentation
import SwiftUI

/// One trade in the menu-bar popover. Built by the app from its stored trade and, when the sticker is up, the live price.
public struct MenuRow: Identifiable, Equatable {
    public let id: UUID
    public let base: String, quote: String, exchange: String
    public let isBuy: Bool
    /// Open quantity, ready to show; "—" once the trade is closed.
    public let quantity: String
    public let icon: Data?
    /// How long the trade has run (or ran), and the money put into it, ready to show.
    public let duration: String?, invested: String
    /// The sticker is on screen.
    public let shown: Bool

    public init(id: UUID, base: String, quote: String, exchange: String, isBuy: Bool, quantity: String, icon: Data?, shown: Bool = false, duration: String? = nil, invested: String = "—") {
        self.id = id; self.base = base; self.quote = quote; self.exchange = exchange
        self.isBuy = isBuy; self.quantity = quantity; self.icon = icon; self.shown = shown; self.duration = duration; self.invested = invested
    }
}

extension MenuRow {
    /// The row of a trade: open size and money put in, how long it ran (to `now` while open, to the last transaction once closed).
    public static func make(trade: StoredTrade, summary: TradeSummary, times: [Date], now: Date, icon: Data?, shown: Bool) -> MenuRow {
        let closed = summary.status == .closed
        let duration = times.min().map { first in Elapsed.duration((closed ? times.max()! : max(now, first)).timeIntervalSince(first)) }
        return MenuRow(
            id: trade.id, base: trade.base, quote: trade.quote, exchange: trade.exchange.capitalized, isBuy: trade.direction == .buyFirst,
            quantity: closed ? "—" : NumberFormat.quantity(summary.openQuantity), icon: icon, shown: shown,
            duration: duration, invested: summary.hasTransactions ? NumberFormat.quote(summary.openingAmount) : "—"
        )
    }
}

/// Everything the popover does goes back to the app through these closures.
public struct MenuActions {
    public var rows: () -> [MenuRow]
    public var open: (UUID) -> Void
    public var newStick: () -> Void
    public var apiKeys: () -> Void
    public var about: () -> Void
    public var restart: (() -> Void)?
    public var quit: () -> Void
    public var launchAtLogin: () -> Bool
    public var setLaunchAtLogin: ((Bool) -> Void)?

    public init(rows: @escaping () -> [MenuRow], open: @escaping (UUID) -> Void, newStick: @escaping () -> Void,
                apiKeys: @escaping () -> Void, about: @escaping () -> Void, restart: (() -> Void)?, quit: @escaping () -> Void,
                launchAtLogin: @escaping () -> Bool, setLaunchAtLogin: ((Bool) -> Void)?) {
        self.rows = rows; self.open = open; self.newStick = newStick; self.apiKeys = apiKeys; self.about = about
        self.restart = restart; self.quit = quit; self.launchAtLogin = launchAtLogin; self.setLaunchAtLogin = setLaunchAtLogin
    }
}

/// Whether the panel is on screen: while it is not, nothing is read or refreshed.
@MainActor @Observable public final class MenuState {
    public var open = false
    /// Esc inside the panel.
    @ObservationIgnored public var onEscape: (() -> Void)?
    public init(open: Bool = false) { self.open = open }
}

public struct MenuPopoverView: View {
    let actions: MenuActions
    let logo: NSImage?
    let state: MenuState
    @State private var login = false

    public init(actions: MenuActions, logo: NSImage?, state: MenuState = MenuState(open: true)) { self.actions = actions; self.logo = logo; self.state = state }

    static let width: CGFloat = 332
    static let maxList: CGFloat = 5 * 46 + 4 * 5

    public var body: some View {
        VStack(spacing: 6) {
            header
            // Re-read every second: the prices move while the popover is open.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let rows = state.open ? actions.rows() : []
                if rows.isEmpty { empty } else { list(rows) }
            }
            Divider().overlay(Theme.divider)
            footer
        }
        .padding(8)
        .frame(width: Self.width)
        .background(GlassBackground(radius: 20))
        .onExitCommand { state.onEscape?() }
        .onChange(of: state.open, initial: true) { _, open in if open { login = actions.launchAtLogin() } } // it may have been changed in System Settings meanwhile
    }

    private var header: some View {
        HStack(spacing: 10) {
            Group { if let logo { Image(nsImage: logo).resizable().interpolation(.high) } else { Color.clear } }
                .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("TradeStick").font(.system(size: 16, weight: .semibold))
            Spacer()
            GlassButton(symbol: "plus", help: "New Stick", keys: "⇧⌘N", action: actions.newStick).keyboardShortcut("n", modifiers: [.command, .shift])
            GlassButton(symbol: "key", help: "API Keys", keys: "⇧⌘K", action: actions.apiKeys).keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }

    private func list(_ rows: [MenuRow]) -> some View {
        let content = VStack(spacing: 5) { ForEach(rows) { row in TradeCard(row: row) { actions.open(row.id) } } }
        return Group {
            if rows.count > 5 { ScrollView { content }.scrollIndicators(.automatic).frame(height: Self.maxList) } else { content }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("No trades yet").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            Button("New Stick", action: actions.newStick).controlSize(.small)
        }
        .frame(maxWidth: .infinity).frame(height: 46)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Label("Launch at Login", systemImage: "laptopcomputer").font(.system(size: 12)).lineLimit(1).fixedSize().padding(.leading, 4)
                .opacity(actions.setLaunchAtLogin == nil ? 0.45 : 1)
                .help(actions.setLaunchAtLogin == nil ? "Only the installed app can start at login" : "")
            Toggle("Launch at Login", isOn: Binding(get: { login }, set: { login = $0; actions.setLaunchAtLogin?($0); login = actions.launchAtLogin() }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(actions.setLaunchAtLogin == nil)
            Spacer(minLength: 0)
            GlassButton(symbol: "info.circle", help: "About", keys: "", above: true, action: actions.about)
            GlassButton(symbol: "arrow.clockwise", help: "Restart", keys: "⇧⌘R", above: true, action: actions.restart ?? {}).disabled(actions.restart == nil)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            GlassButton(symbol: "power", help: "Quit", keys: "⌘Q", above: true, action: actions.quit)
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

private struct GlassButton: View {
    let symbol: String, help: String, keys: String
    var above = false
    let action: () -> Void
    @State private var hover = false
    @State private var tip = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 36, height: 28)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.16 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain).accessibilityLabel(help)
        .overlay(alignment: above ? .topTrailing : .bottomTrailing) {
            if tip {
                HStack(spacing: 6) { Text(help); if !keys.isEmpty { Text(keys).foregroundStyle(Theme.secondaryText) } }
                    .font(.system(size: 11, weight: .medium)).fixedSize().padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(red: 0.10, green: 0.10, blue: 0.15)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.18)))
                    .offset(y: above ? -32 : 32).allowsHitTesting(false)
            }
        }
        .zIndex(tip ? 1 : 0)
        .onHover { inside in
            hover = inside
            if !inside { tip = false; return }
            Task { try? await Task.sleep(for: .milliseconds(350)); if hover { tip = true } }
        }
    }
}

private struct TradeCard: View {
    let row: MenuRow
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                // Both blocks have fixed edges, so the dividers of all the cards stand one under another.
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(row.base) / \(row.quote)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(row.isBuy ? "BUY" : "SELL").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1).fixedSize()
                            .background(Capsule().fill((row.isBuy ? Theme.positive : Theme.negative).opacity(0.22)))
                            .foregroundStyle(row.isBuy ? Theme.positive : Theme.negative)
                        Text(row.exchange + (row.duration.map { " · \($0)" } ?? "")).font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondaryText).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .frame(width: 142, alignment: .leading)
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1).padding(.vertical, 2)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(row.invested) \(row.quote)").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    Text("\(row.quantity) \(row.base)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                }
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 9).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hover ? 0.13 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(row.shown ? 0.38 : 0.12), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .accessibilityLabel("\(row.base)/\(row.quote) \(row.isBuy ? "buy" : "sell") on \(row.exchange)")
        .accessibilityValue("invested \(row.invested) \(row.quote), \(row.quantity) \(row.base)\(row.duration.map { ", \($0)" } ?? "")\(row.shown ? ", sticker is open" : "")")
        .accessibilityAddTraits(row.shown ? [.isButton, .isSelected] : .isButton)
    }

    private var icon: some View {
        ZStack {
            if let data = row.icon, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().clipShape(Circle())
            } else {
                Circle().fill(Theme.monogram(row.base))
                Text(String(row.base.prefix(1))).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 26, height: 26)
    }
}

private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

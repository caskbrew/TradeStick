import AppKit
import Domain
import MarketData
import Persistence
import SwiftUI
import Widgets

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: TradeStore!
    private var hub: MarketDataHub!
    private let adapters: [any ExchangeAdapter] = [BinanceAdapter()]
    private var statusItem: NSStatusItem!
    private var windows: [UUID: StickerWindow] = [:]
    private var newTradeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar agent, no Dock icon
        do {
            // Developer overrides: a separate database file and demo data (spec example A).
            let path: String
            if let override = ProcessInfo.processInfo.environment["TRADESTICKER_DB"] { path = override } else { path = try TradeStore.defaultDatabaseURL().path }
            store = try TradeStore(path: path)
            if CommandLine.arguments.contains("--seed-demo"), try store.trades().isEmpty { try seedDemo() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "TradeSticker could not open its database"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        hub = MarketDataHub(adapters: adapters)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "TradeSticker")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        for trade in (try? store.trades()) ?? [] where trade.isVisible { open(trade, activate: false) }
    }

    private func seedDemo() throws {
        let trade = try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: .buyFirst)
        let t0 = Date().addingTimeInterval(-3600)
        for (i, tx) in [(Side.buy, "1000", "50"), (.buy, "500", "30"), (.sell, "600", "40")].enumerated() {
            try store.addTransaction(
                tradeID: trade.id, side: tx.0, quantity: Decimal(string: tx.1)!, amount: Decimal(string: tx.2)!,
                occurredAt: t0.addingTimeInterval(Double(i) * 600)
            )
        }
    }

    // MARK: Windows

    private func open(_ trade: StoredTrade, activate: Bool) {
        if let existing = windows[trade.id] {
            existing.show(activate: activate)
            Task { await existing.model.setVisible(true) }
            return
        }
        let model = StickerModel(trade: trade, store: store, hub: hub)
        let window = StickerWindow(model: model, store: store, index: windows.count)
        window.onDelete = { [weak self] in self?.confirmDelete(trade.id) }
        windows[trade.id] = window
        window.show(activate: activate)
        Task { await model.setVisible(true); await model.refreshSubscription() }
    }

    private func confirmDelete(_ id: UUID) {
        guard let window = windows[id] else { return }
        let count = window.model.transactions.count
        let alert = NSAlert()
        alert.messageText = "Delete \(window.model.trade.base)/\(window.model.trade.quote) trade?"
        alert.informativeText = "This permanently deletes the trade and its \(count) transaction\(count == 1 ? "" : "s")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        window.close()
        windows[id] = nil
        Task {
            await window.model.setVisible(false) // drops the price subscription
            try? store.deleteTrade(id: id)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let new = NSMenuItem(title: "New Trade…", action: #selector(showNewTrade), keyEquivalent: "n")
        new.target = self
        menu.addItem(new)

        let trades = (try? store.trades()) ?? []
        if !trades.isEmpty { menu.addItem(.separator()) }
        for trade in trades {
            let visible = windows[trade.id]?.isVisible ?? false
            let item = NSMenuItem(
                title: "\(trade.base)/\(trade.quote) · \(trade.direction == .buyFirst ? "Buy-first" : "Sell-first")",
                action: #selector(toggle(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = trade.id
            item.state = visible ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TradeSticker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggle(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, let trade = try? store.trade(id: id) else { return }
        if let window = windows[id], window.isVisible {
            window.hide()
        } else {
            open(trade, activate: true)
        }
    }

    @objc private func showNewTrade() {
        if let existing = newTradeWindow {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let model = NewTradeModel(adapters: adapters)
        let view = NewTradeView(
            model: model,
            onCreate: { [weak self] request in self?.create(request) },
            onCancel: { [weak self] in self?.closeNewTrade() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "New Trade"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        newTradeWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func closeNewTrade() {
        newTradeWindow?.close()
        newTradeWindow = nil
    }

    private func create(_ request: NewTradeRequest) {
        closeNewTrade()
        guard let trade = try? store.createTrade(
            exchange: request.exchange, base: request.instrument.base, quote: request.instrument.quote, direction: request.direction
        ) else { return }
        open(trade, activate: true) // FR-NEW-4: the sticker opens empty with the form ready
        windows[trade.id]?.model.openForm(side: trade.direction.openingSide)
    }
}

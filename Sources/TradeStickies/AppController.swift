import AppKit
import Network
import os
import Domain
import MarketData
import Persistence
import SwiftUI
import Widgets

struct DevGuardError: Error, CustomStringConvertible {
    var description: String { "A dev build refuses to open the installed app's data (Application Support/TradeStickies)." }
}

/// Frameless dialog like the stickers (the card draws its own glass); a borderless window must opt in to taking keys.
final class DialogWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    convenience init(content: NSViewController) {
        self.init(contentViewController: content)
        styleMask = [.borderless]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: TradeStore!
    private var hub: MarketDataHub!
    private var pathMonitor: NWPathMonitor?
    /// Only the installed app (bundle id set by scripts/package.sh) touches the real data. Anything else
    /// (`swift run`, a dev build) uses its own folder, so development never damages the user's trades.
    static let isInstalled = Bundle.main.bundleIdentifier == "com.caskbrew.tradestickies"
    static let dataFolder = isInstalled ? "TradeStickies" : "TradeStickies-Dev"
    private let icons = CoinIcons(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "\(AppController.dataFolder)/icons"))
    private let adapters: [any ExchangeAdapter] = [BinanceAdapter()]
    private var statusItem: NSStatusItem!
    private var windows: [UUID: StickerWindow] = [:]
    private var newTradeWindow: NSWindow?
    private var apiKeysWindow: NSWindow?
    /// The installed app and dev builds keep their keys apart, like their data.
    private let credentials: any CredentialStore = KeychainCredentialStore(service: AppController.isInstalled ? "com.caskbrew.tradestickies" : "com.caskbrew.tradestickies.dev")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar agent, no Dock icon
        do {
            // Developer overrides: a separate database file and demo data (spec example A).
            let path: String
            if let override = ProcessInfo.processInfo.environment["TRADESTICKIES_DB"] { path = override } else { path = try TradeStore.defaultDatabaseURL(folder: Self.dataFolder).path }
            // A dev build must never open the installed app's database, whatever the override says.
            if !Self.isInstalled, path.contains("/Application Support/TradeStickies/") { throw DevGuardError() }
            store = try TradeStore(path: path)
            if CommandLine.arguments.contains("--seed-demo"), try store.trades().isEmpty { try seedDemo() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "TradeStickies could not open its database"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        hub = MarketDataHub(adapters: adapters)
        installEditMenu()
        watchConnectivity()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let url = Bundle.module.url(forResource: "MenuBarIconTemplate", withExtension: "png"), let icon = NSImage(contentsOf: url) {
            icon.size = NSSize(width: 20 * icon.size.width / icon.size.height, height: 20)
            icon.isTemplate = true // black + alpha: macOS tints it for light and dark menu bars
            statusItem.button?.image = icon
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "TradeStickies")
        }
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png") { NSApp.applicationIconImage = NSImage(contentsOf: url) } // shown in alerts
        if !Self.isInstalled { statusItem.button?.title = " DEV" } // a dev instance is never mistaken for the real one
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        for trade in (try? store.trades()) ?? [] where trade.isVisible { open(trade, activate: false) }
        if CommandLine.arguments.contains("--selftest-window") { Task { await selfTestWindow() } }
    }

    /// A menu-bar agent has no main menu, and without an Edit menu ⌘C / ⌘V / ⌘A / ⌘Z do nothing in text fields.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, action, key, mods) in [
            ("Undo", Selector(("undo:")), "z", NSEvent.ModifierFlags.command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            edit.addItem(item)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Sockets die silently when the Mac sleeps or the network changes: reconnect on wake and when the
    /// network comes back after being gone.
    private func watchConnectivity() {
        let hub = hub!
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task {
                try? await Task.sleep(for: .seconds(2)) // let Wi-Fi come up
                await hub.reconnectAll()
            }
        }
        let monitor = NWPathMonitor()
        let wasOffline = OSAllocatedUnfairLock(initialState: false)
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            let recovered = wasOffline.withLock { offline -> Bool in
                defer { offline = !online }
                return offline && online
            }
            if recovered { Task { await hub.reconnectAll() } }
        }
        monitor.start(queue: DispatchQueue(label: "tradestickies.network"))
        pathMonitor = monitor
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

    /// Developer check for "the window jumps": samples the frame while the list opens and closes and prints
    /// how far the top edge moved. A steady top edge and a monotonic height mean no jump.
    private func selfTestWindow() async {
        guard let window = windows.values.first else { print("selftest: no window"); NSApp.terminate(nil); return }
        func sample(_ label: String, _ change: () -> Void) async {
            try? await Task.sleep(for: .milliseconds(600))
            let start = window.frame
            var tops: [CGFloat] = [start.maxY], heights: [CGFloat] = [start.height], cards: [CGFloat] = [window.currentCardHeight]
            change()
            for _ in 0..<150 { // ~1.2 s at 8 ms
                try? await Task.sleep(for: .milliseconds(8))
                tops.append(window.frame.maxY); heights.append(window.frame.height); cards.append(window.currentCardHeight)
            }
            let steps = Set(heights.map { ($0 * 10).rounded() }).count
            var path: [CGFloat] = []
            for h in heights where path.last != h { path.append(h) }
            var cardPath: [CGFloat] = []
            for c in cards where cardPath.last != c { cardPath.append(c) }
            print("selftest \(label): card \(cardPath.map { Int($0) })")
            print("selftest \(label): top moved \(tops.max()! - tops.min()!) pt, heights \(path.map { Int($0) }), steps \(steps)")
        }
        if let dir = ProcessInfo.processInfo.environment["TRADESTICKIES_FRAMES"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .milliseconds(800))
            window.capture(to: URL(fileURLWithPath: dir).appendingPathComponent("expand-0.png"))
            window.model.setExpanded(true)
            for i in 1...6 {
                try? await Task.sleep(for: .milliseconds(35))
                window.capture(to: URL(fileURLWithPath: dir).appendingPathComponent("expand-\(i).png"))
                window.captureList(to: URL(fileURLWithPath: dir).appendingPathComponent("list-\(i).png"))
            }
            try? await Task.sleep(for: .milliseconds(600))
            window.captureList(to: URL(fileURLWithPath: dir).appendingPathComponent("list-final.png"))
            print("listOnTop", window.model.listOnTop, "listFrame", window.listFrame)
            window.model.setExpanded(false)
            for i in 1...6 {
                try? await Task.sleep(for: .milliseconds(35))
                window.capture(to: URL(fileURLWithPath: dir).appendingPathComponent("collapse-\(i).png"))
            }
            window.model.setExpanded(true)
            try? await Task.sleep(for: .milliseconds(500))
            window.model.openForm(side: .buy)
            for i in 1...6 {
                try? await Task.sleep(for: .milliseconds(35))
                window.capture(to: URL(fileURLWithPath: dir).appendingPathComponent("form-\(i).png"))
            }
            try? await Task.sleep(for: .milliseconds(600))
            window.capture(to: URL(fileURLWithPath: dir).appendingPathComponent("form-L.png"))
            window.captureForm(to: URL(fileURLWithPath: dir).appendingPathComponent("form-panel.png"))
            print("frame", window.frame, "form", window.formFrame, "list", window.listFrame)
            window.model.cancelForm()
            for i in 1...6 {
                try? await Task.sleep(for: .milliseconds(35))
                window.capture(to: URL(fileURLWithPath: dir).appendingPathComponent("formclose-\(i).png"))
            }
            try? await Task.sleep(for: .milliseconds(600))
            print("frame after close", window.frame)
            NSApp.terminate(nil)
            return
        }
        await sample("expand") { window.model.setExpanded(true) }
        await sample("collapse") { window.model.setExpanded(false) }
        await sample("open form") { window.model.openForm(side: .buy) }
        await sample("close form") { window.model.cancelForm() }
        NSApp.terminate(nil)
    }

    // MARK: Windows

    private func open(_ trade: StoredTrade, activate: Bool) {
        if let existing = windows[trade.id] {
            existing.show(activate: activate)
            Task { await existing.model.setVisible(true) }
            return
        }
        let model = StickerModel(trade: trade, store: store, hub: hub, icons: icons)
        let window = StickerWindow(model: model, store: store, index: windows.count)
        window.onDelete = { [weak self] in self?.confirmDelete(trade.id) }
        model.onImportHistory = { [weak self, weak model] in
            if let model { self?.showImport(for: model) }
        }
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
        let new = NSMenuItem(title: "New Tx", action: #selector(showNewTrade), keyEquivalent: "n")
        new.target = self
        menu.addItem(new)

        let trades = (try? store.trades()) ?? []
        if !trades.isEmpty { menu.addItem(.separator()) }
        for trade in trades {
            let visible = windows[trade.id]?.isVisible ?? false
            let item = NSMenuItem(
                title: "\(trade.base)/\(trade.quote) \(trade.direction == .buyFirst ? "BUY" : "SELL") \(trade.exchange.capitalized)",
                action: #selector(toggle(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = trade.id
            item.state = visible ? .on : .off
            item.toolTip = visible ? "Bring this sticker to the current desktop" : "Show this sticker"
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let keys = NSMenuItem(title: "API Keys", action: #selector(openAPIKeysWindow), keyEquivalent: ",")
        keys.target = self
        menu.addItem(keys)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Shows a hidden sticker, or pulls a visible one to the desktop you are on. Hiding is in the sticker's `⋯` menu.
    @objc private func toggle(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, let trade = try? store.trade(id: id) else { return }
        open(trade, activate: true)
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

    @objc private func openAPIKeysWindow() { showAPIKeys() }

    private func showAPIKeys() {
        if let existing = apiKeysWindow {
            NSApp.activate()
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let api = BinanceAccountAPI()
        let model = APIKeysModel(store: credentials, check: { try await api.check($0) })
        let view = APIKeysView(model: model, onClose: { [weak self] in self?.apiKeysWindow?.close(); self?.apiKeysWindow = nil })
        let window = DialogWindow(content: NSHostingController(rootView: view))
        window.title = "API Keys"
        window.center()
        apiKeysWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private var importWindows: [UUID: NSWindow] = [:]

    /// Pick fills from the exchange's trade history for one trade. Without a saved API key the key window opens instead.
    private func showImport(for sticker: StickerModel) {
        let trade = sticker.trade
        importWindows[trade.id]?.close() // always start fresh: the list is re-read from the exchange
        guard let keys = credentials.load(exchange: trade.exchange) else { showAPIKeys(); return }
        let api = BinanceAccountAPI()
        let instrument = Instrument(base: trade.base, quote: trade.quote)
        let store = self.store!
        let model = ImportModel(
            title: "Import from Binance", pair: "\(trade.base) / \(trade.quote)", quote: trade.quote,
            fetch: { try await api.myTrades(keys, instrument) },
            existing: { (try? store.externalIDs(tradeID: trade.id)) ?? [] },
            commit: { sticker.importTrades($0) }
        )
        let window = DialogWindow(content: NSHostingController(rootView: ImportView(model: model, onClose: { [weak self] in
            self?.importWindows[trade.id]?.close()
            self?.importWindows[trade.id] = nil
        })))
        window.title = "Import from Binance"
        window.center()
        importWindows[trade.id] = window
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

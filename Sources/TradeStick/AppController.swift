import AppKit
import Network
import os
import Domain
import MarketData
import Persistence
import SwiftUI
import Widgets

struct DevGuardError: Error, CustomStringConvertible {
    var description: String { "A dev build refuses to open the installed app's data (Application Support/TradeStick)." }
}

/// Frameless dialog like the stickers (the card draws its own glass); a borderless window must opt in to taking keys.
final class DialogWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    /// Closing the last dialog hands the focus back to the previous app first: otherwise AppKit makes a sticker the key
    /// window and macOS switches to the desktop that sticker is on.
    override func close() {
        if !NSApp.windows.contains(where: { $0 !== self && $0 is DialogWindow && $0.isVisible }) {
            ZoomPanel.keyBlocked = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ZoomPanel.keyBlocked = false }
            NSApp.deactivate()
        }
        super.close()
    }

    /// The size is only final once SwiftUI has laid the content out, so centre after ordering front (same run-loop pass: no visible jump).
    override func makeKeyAndOrderFront(_ sender: Any?) {
        if !isVisible { alphaValue = 0 } // invisible until it has its final place and size
        super.makeKeyAndOrderFront(sender)
        contentView?.layoutSubtreeIfNeeded()
        centerOnScreen()
        // SwiftUI may still change the window's size after this pass; keep it centred unless the user has already moved it.
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, isVisible, frame.origin == centeredOrigin || delay == 0.05 else { return }
                centerOnScreen()
                alphaValue = 1
            }
        }
    }

    private var centeredOrigin = NSPoint.zero

    /// Esc closes the dialog; set by the owner when closing also has to forget the window.
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { (onEscape ?? { self.close() })() }

    /// Exactly in the middle of the screen the pointer is on (`center()` sits above the middle).
    func centerOnScreen() {
        let mouse = NSEvent.mouseLocation // in the menu bar the pointer sits on the very edge of its screen: allow a point of slack
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        centeredOrigin = NSPoint(x: (area.midX - frame.width / 2).rounded(), y: (area.midY - frame.height / 2).rounded())
        setFrameOrigin(centeredOrigin)
    }

    convenience init(content: NSViewController) {
        self.init(contentViewController: content)
        styleMask = [.borderless]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.moveToActiveSpace] // opens on the desktop you are on
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: TradeStore!
    private var hub: MarketDataHub!
    private var pathMonitor: NWPathMonitor?
    /// Only the installed app (bundle id set by scripts/package.sh) touches the real data. Anything else
    /// (`swift run`, a dev build) uses its own folder, so development never damages the user's trades.
    static let isInstalled = Bundle.main.bundleIdentifier == "com.caskbrew.tradestick"
    static let dataFolder = isInstalled ? "TradeStick" : "TradeStick-Dev"
    private let icons = CoinIcons(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "\(AppController.dataFolder)/icons"))
    private let adapters: [any ExchangeAdapter] = [BinanceAdapter(), PoloniexAdapter(), BybitAdapter()]
    private let accounts: [any ExchangeAccount] = [BinanceAccountAPI(), PoloniexAccountAPI(), BybitAccountAPI()]
    private var statusItem: NSStatusItem!
    private var windows: [UUID: StickerWindow] = [:]
    private var newTradeWindow: NSWindow?
    private var apiKeysWindow: NSWindow?
    /// The installed app and dev builds keep their keys apart, like their data.
    private let credentials: any CredentialStore = KeychainCredentialStore(service: AppController.isInstalled ? "com.caskbrew.tradestick" : "com.caskbrew.tradestick.dev")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar agent, no Dock icon
        do {
            // Before the rename the folder and keychain service were called "TradeStickies": carry them over once.
            if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                try LegacyMigration.moveDataFolder(in: base, from: Self.isInstalled ? "TradeStickies" : "TradeStickies-Dev", to: Self.dataFolder)
            }
            let legacy = "com.caskbrew.tradestickies" + (Self.isInstalled ? "" : ".dev")
            LegacyMigration.copyKeys(from: KeychainCredentialStore(service: legacy), to: credentials, exchanges: adapters.map(\.id))
            // Developer overrides: a separate database file and demo data (spec example A).
            let path: String
            if let override = ProcessInfo.processInfo.environment["TRADESTICK_DB"] { path = override } else { path = try TradeStore.defaultDatabaseURL(folder: Self.dataFolder).path }
            // A dev build must never open the installed app's database, whatever the override says.
            if !Self.isInstalled, path.contains("/Application Support/TradeStick/") { throw DevGuardError() }
            store = try TradeStore(path: path)
            if CommandLine.arguments.contains("--seed-demo"), try store.trades().isEmpty { try seedDemo() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "TradeStick could not open its database"
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
            statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "TradeStick")
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
        monitor.start(queue: DispatchQueue(label: "tradestick.network"))
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
        if let dir = ProcessInfo.processInfo.environment["TRADESTICK_FRAMES"] {
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
        let new = NSMenuItem(title: "New Stick", action: #selector(showNewTrade), keyEquivalent: "n")
        new.keyEquivalentModifierMask = [.command, .shift]
        new.target = self
        menu.addItem(new)
        let keys = NSMenuItem(title: "API Keys", action: #selector(openAPIKeysWindow), keyEquivalent: "k")
        keys.keyEquivalentModifierMask = [.command, .shift]
        keys.target = self
        menu.addItem(keys)

        menu.addItem(.separator())
        let trades = (try? store.trades()) ?? []
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
        if !trades.isEmpty { menu.addItem(.separator()) }
        let about = NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let restart = NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "r")
        restart.keyEquivalentModifierMask = [.command, .shift]
        restart.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Restart") // like the one macOS gives Quit
        restart.target = self
        restart.isEnabled = Bundle.main.bundlePath.hasSuffix(".app") // a bare `swift run` binary cannot be reopened
        menu.addItem(restart)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Shows a hidden sticker, or pulls a visible one to the desktop you are on. Hiding is in the sticker's `⋯` menu.
    @objc private func toggle(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID, let trade = try? store.trade(id: id) else { return }
        open(trade, activate: true)
    }

    /// Dialogs are ordered front first (they open on this desktop), then the app activates: it finds a window here and does not switch desktops.
    private func activateAfterShowing() { NSApp.activate() }

    @objc private func showNewTrade() {
        if let existing = newTradeWindow {
            existing.makeKeyAndOrderFront(nil)
            activateAfterShowing()
            return
        }
        let model = NewTradeModel(adapters: adapters)
        let view = NewTradeView(
            model: model,
            onCreate: { [weak self] request in self?.create(request) },
            onCancel: { [weak self] in self?.closeNewTrade() }
        )
        let window = DialogWindow(content: NSHostingController(rootView: view))
        window.title = "New Trade"
        window.onEscape = { [weak self] in self?.closeNewTrade() }
        newTradeWindow = window
        window.makeKeyAndOrderFront(nil)
        activateAfterShowing()
    }

    /// Starts a fresh copy of the app a moment after this one has quit (handy after `brew upgrade`).
    @objc private func restart() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    private var aboutWindow: NSWindow?

    @objc private func showAbout() {
        if aboutWindow == nil {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev build"
            let icon = Bundle.module.url(forResource: "AppIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
            let close = { [weak self] in self?.aboutWindow?.close(); self?.aboutWindow = nil }
            let window = DialogWindow(content: NSHostingController(rootView: AboutView(version: version, icon: icon, onClose: close)))
            window.title = "About TradeStick"
            window.onEscape = close
            aboutWindow = window
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
        activateAfterShowing()
    }

    @objc private func openAPIKeysWindow() { showAPIKeys() }

    private func showAPIKeys(exchange: String? = nil) {
        if let existing = apiKeysWindow {
            if exchange == nil {
                existing.makeKeyAndOrderFront(nil)
                activateAfterShowing()
                return
            }
            existing.close() // reopen on the requested exchange
        }
        let models = accounts.map { account in
            APIKeysModel(exchange: account.id, store: credentials, check: { try await account.check($0) })
        }
        let close = { [weak self] in self?.apiKeysWindow?.close(); self?.apiKeysWindow = nil }
        let view = APIKeysView(models: models, initial: exchange, onClose: close)
        let window = DialogWindow(content: NSHostingController(rootView: view))
        window.title = "API Keys"
        window.onEscape = close
        apiKeysWindow = window
        window.makeKeyAndOrderFront(nil)
        activateAfterShowing()
    }

    private var importWindows: [UUID: NSWindow] = [:]

    /// Pick fills from the exchange's trade history for one trade. Without a saved API key the key window opens instead.
    private func showImport(for sticker: StickerModel) {
        let trade = sticker.trade
        importWindows[trade.id]?.close() // always start fresh: the list is re-read from the exchange
        guard let account = accounts.first(where: { $0.id == trade.exchange }) else { return }
        guard let keys = (try? credentials.load(exchange: trade.exchange)) ?? nil else { showAPIKeys(exchange: trade.exchange); return }
        let instrument = Instrument(base: trade.base, quote: trade.quote)
        let store = self.store!
        let history = FillHistory(account: account, store: store, instrument: instrument)
        let model = ImportModel(
            title: "Import from \(trade.exchange.capitalized)", pair: "\(trade.base) / \(trade.quote)", quote: trade.quote,
            fetch: { try await history.refresh(keys) },
            existing: { (try? store.externalIDs(tradeID: trade.id)) ?? [] },
            commit: { sticker.importTrades($0) },
            saved: { try await history.saved() },
            recalculate: { sticker.reimportTrades($0) }
        )
        let host = NSHostingController(rootView: ImportView(model: model, onClose: { [weak self] in
            self?.importWindows[trade.id]?.close()
            self?.importWindows[trade.id] = nil
        }))
        host.sizingOptions = [] // the user sets the height, the content follows
        let window = DialogWindow(content: host)
        window.styleMask.insert(.resizable) // a borderless window is resized by its edges
        window.setContentSize(NSSize(width: 720, height: 440))
        window.contentMinSize = NSSize(width: 720, height: 340)
        window.contentMaxSize = NSSize(width: 720, height: 2000)
        window.title = "Import from \(trade.exchange.capitalized)"
        importWindows[trade.id] = window
        window.makeKeyAndOrderFront(nil)
        activateAfterShowing()
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

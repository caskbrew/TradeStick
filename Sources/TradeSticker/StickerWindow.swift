import AppKit
import Persistence
import Presentation
import SwiftUI
import Widgets

/// Handles ⌘+ ⌘− ⌘0 on the key window itself, so zoom works from the sticker, the form and the list alike,
/// whatever the keyboard layout. Keys are matched by key code (main row and keypad).
class ZoomPanel: NSPanel {
    var onZoom: ((CGFloat) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .capsLock])
        guard mods == .command || mods == [.command, .shift], let onZoom else { return super.performKeyEquivalent(with: event) }
        switch event.keyCode {
        case 24, 69: onZoom(0.1) // = / +, keypad +
        case 27, 78: onZoom(-0.1) // −, keypad −
        case 29, 82: onZoom(0) // 0, keypad 0
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

/// Borderless note-like panel (M0 report): normal level, one Space, activating, no title bar.
final class StickerPanel: ZoomPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: StickerView.width, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        level = .normal
        // Lives on one desktop, but ordering it front (menu item) pulls it to the desktop you are on.
        collectionBehavior = [.moveToActiveSpace]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }
}

/// The add/edit form lives in its own transparent panel next to the sticker, so the sticker itself never widens.
final class FormPanel: ZoomPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: StickerView.formDrawerWidth, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        level = .normal
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }
}

/// One sticker: panel + model. Owns window geometry: fits the content height, keeps the top edge fixed,
/// pulls the window up when it would leave the screen, and remembers the position (FR-WIN-6, FR-TX-8).
@MainActor
final class StickerWindow: NSObject, NSWindowDelegate {
    let model: StickerModel
    private let panel = StickerPanel()
    private let formPanel = FormPanel()
    private let listPanel = FormPanel()
    private let listHost = NSHostingView(rootView: AnyView(EmptyView()))
    private var listHeight: CGFloat = 0
    private var listPending = false
    private let formHost = NSHostingView(rootView: AnyView(EmptyView()))
    private var formHeight: CGFloat = 0
    private let store: TradeStore
    private let host: NSHostingView<AnyView>
    private var content = CGSize.zero
    /// Clips the card and pins it to the top while the window frame animates.
    private let container = NSView()
    private var settleTask: Task<Void, Never>?
    /// Where the user put the top-left corner. Growing/shrinking returns to this, not to a shifted frame.
    private var anchor: NSPoint
    private var isFitting = false
    private var saveTask: Task<Void, Never>?
    var onHide: (() -> Void)?
    var onDelete: (() -> Void)?

    init(model: StickerModel, store: TradeStore, index: Int) {
        self.model = model
        self.store = store
        self.anchor = Self.initialAnchor(for: model.trade.position, index: index)
        host = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()
        let actions = StickerActions(hide: { [weak self] in self?.hide() }, delete: { [weak self] in self?.onDelete?() })
        // Fills the window and pins the card to the top, so a card that is still growing is never centred.
        host.rootView = AnyView(StickerView(model: model, actions: actions))
        host.sizingOptions = [] // the window is sized by us, never by SwiftUI
        model.onContentSize = { [weak self] size in
            self?.content = size
            self?.contentLaidOut()
        }
        model.onFormWillOpen = { [weak self] in self?.prepareForm() }
        model.confirm = { plan in Self.confirm(plan, base: model.trade.base, quote: model.trade.quote) }
        model.onFormClosed = { [weak self] in self?.dismissForm() }
        model.onFormHeight = { [weak self] height in self?.formHeightChanged(height) }
        model.onListWillOpen = { [weak self] in self?.prepareList() }
        model.onListClosed = { [weak self] in self?.dismissList() }
        model.onListHeight = { [weak self] height in self?.listHeightChanged(height) }
        listHost.rootView = AnyView(ListWindowView(model: model))
        listHost.sizingOptions = []
        listPanel.contentView = listHost
        for p in [panel, formPanel, listPanel] as [ZoomPanel] { p.onZoom = { [weak model] delta in model?.zoom(by: delta) } }
        listPanel.setContentSize(NSSize(width: StickerView.listWidth * model.scale, height: 300))
        formHost.rootView = AnyView(FormWindowView(model: model))
        formHost.sizingOptions = []
        formPanel.contentView = formHost
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        panel.delegate = self
        contentLaidOut()
    }

    func show(activate: Bool) {
        contentLaidOut()
        settle()
        if model.trade.isExpanded && listPanel.parent == nil {
            if content.height > 0 { prepareList() } else { listPending = true } // the sticker has no final frame yet
        }
        if activate {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    func hide() {
        model.cancelForm()
        formPanel.orderOut(nil)
        panel.orderOut(nil)
        Task {
            await model.setVisible(false)
            onHide?()
        }
    }

    func close() {
        listPanel.orderOut(nil)
        formPanel.orderOut(nil)
        panel.orderOut(nil)
        panel.contentView = nil
        host.removeFromSuperview()
        Task { await model.setVisible(false) }
    }

    var isVisible: Bool { panel.isVisible }

    /// "Are you sure?" with what will be sold or bought and for how much (the transaction is only recorded here).
    private static func confirm(_ plan: StickerModel.ClosePlan, base: String, quote: String) -> Bool {
        let verb = plan.side == .sell ? "Sell" : "Buy back"
        let quantity = "\(NumberFormat.quantity(plan.quantity)) \(base)"
        let amount = "\(NumberFormat.amount(plan.amount)) \(quote)"
        let alert = NSAlert()
        alert.messageText = plan.recoversInvestment ? "\(verb) \(quantity) to recover the investment?" : "\(verb) all \(quantity) at market?"
        alert.informativeText = "\(plan.side == .sell ? "You receive" : "You pay") ≈ \(amount) at \(NumberFormat.price(plan.rate)) per \(base).\n"
            + (plan.remaining > 0 ? "You keep \(NumberFormat.quantity(plan.remaining)) \(base)." : "The trade will be closed.")
            + "\nThis records the transaction in TradeSticker only; no order is sent to the exchange."
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Renders the window's current content to a PNG (developer aid; needs no screen-recording permission).
    func capture(to url: URL) {
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    func captureForm(to url: URL) {
        guard let view = formPanel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    func captureList(to url: URL) {
        guard let view = listPanel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    var listFrame: NSRect { listPanel.frame }
    var frame: NSRect { panel.frame }
    var formFrame: NSRect { formPanel.frame }
    /// Card height as SwiftUI currently lays it out (animated while a section opens or closes).
    var currentCardHeight: CGFloat { content.height }


    // MARK: Geometry

    // Resizing model: the window frame itself is never animated. A transparent window may be taller than the
    // card; SwiftUI animates the card inside it. Growing happens first (reserve), trimming after the content
    // has settled. Animating the frame made the glass flicker and left nothing to animate when closing.

    /// The list opens in its own panel under the sticker, or over it when the screen has no room below.
    private func prepareList() {
        listPanel.setContentSize(NSSize(width: StickerView.listWidth * model.scale, height: listHeight > 0 ? listHeight : 300))
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        model.listOnTop = panel.frame.minY - listPanel.frame.height < (screen?.visibleFrame.minY ?? -.infinity)
        placeListPanel()
        if listPanel.parent == nil { panel.addChildWindow(listPanel, ordered: .above) }
        listPanel.orderFront(nil)
    }

    private func dismissList() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260)) // let the drawer slide away first
            guard let self, !self.model.trade.isExpanded else { return }
            self.panel.removeChildWindow(self.listPanel)
            self.listPanel.orderOut(nil)
        }
    }

    private func listHeightChanged(_ height: CGFloat) {
        guard height > 0 else { return }
        listHeight = height
        guard listPanel.isVisible, abs(listPanel.frame.height - height) > 0.5 || abs(listPanel.frame.width - StickerView.listWidth * model.scale) > 0.5 else { return }
        listPanel.setContentSize(NSSize(width: StickerView.listWidth * model.scale, height: height))
        placeListPanel()
    }

    /// Left-aligned with the sticker, touching its bottom edge (or its top edge when it opens upward).
    private func placeListPanel() {
        let main = panel.frame, size = listPanel.frame.size
        listPanel.setFrameOrigin(NSPoint(x: main.minX, y: model.listOnTop ? main.maxY : main.minY - size.height))
        listPanel.invalidateShadow()
    }

    /// The form opens in its own panel to the left of the sticker, or to the right when the left side has no room.
    private func prepareForm() {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        model.formOnLeft = anchor.x - StickerView.formDrawerWidth * model.scale >= (screen?.visibleFrame.minX ?? 0) // left by default
        formPanel.setContentSize(NSSize(width: StickerView.formDrawerWidth * model.scale, height: formHeight > 0 ? formHeight : 300))
        placeFormPanel()
        if formPanel.parent == nil { panel.addChildWindow(formPanel, ordered: .above) }
        formPanel.orderFront(nil)
        NSApp.activate()
        formPanel.makeKey()
    }

    private func dismissForm() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(260)) // let the drawer slide out first
            guard let self, self.model.form == nil else { return }
            self.panel.removeChildWindow(self.formPanel)
            self.formPanel.orderOut(nil)
            self.panel.makeKey()
        }
    }

    private func formHeightChanged(_ height: CGFloat) {
        guard height > 0 else { return }
        formHeight = height
        guard formPanel.isVisible, abs(formPanel.frame.height - height) > 0.5 || abs(formPanel.frame.width - StickerView.formDrawerWidth * model.scale) > 0.5 else { return }
        formPanel.setContentSize(NSSize(width: StickerView.formDrawerWidth * model.scale, height: height))
        placeFormPanel()
    }

    /// Top-aligned with the sticker, touching its left or right edge.
    private func placeFormPanel() {
        let main = panel.frame, size = formPanel.frame.size
        let x = model.formOnLeft ? main.minX - size.width : main.maxX
        formPanel.setFrameOrigin(NSPoint(x: x, y: main.maxY - size.height))
        formPanel.invalidateShadow()
    }

    /// The content reported a new size: grow the window if it outgrew it, and schedule trimming once things stop moving.
    private func contentLaidOut() {
        guard content.height > 0 else { return }
        if content.height > panel.frame.height + 0.5 || content.width > panel.frame.width + 0.5 { setWindowHeight(content.height) }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    /// Cuts the window to the card's height.
    private func settle() {
        if content.height > 0, abs(content.height - panel.frame.height) > 0.5 || abs(content.width - panel.frame.width) > 0.5 { setWindowHeight(content.height) }
    }

    private func setWindowHeight(_ height: CGFloat) {
        var frame = NSRect(x: anchor.x, y: anchor.y - height, width: content.width > 0 ? content.width : StickerView.width, height: height)
        if let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame {
            if frame.minY < visible.minY { frame.origin.y = visible.minY } // shift up, never off-screen
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - height }
        }
        isFitting = true
        defer { isFitting = false }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        if formPanel.isVisible { placeFormPanel() }
        if listPanel.isVisible { placeListPanel() }
        if listPending { listPending = false; prepareList() }
    }

    private static func initialAnchor(for stored: WindowPosition?, index: Int) -> NSPoint {
        if let stored {
            let point = NSPoint(x: stored.x, y: stored.topY)
            // A disconnected monitor must not strand the window off-screen.
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) { return point }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let step = CGFloat(index % 8) * 28
        return NSPoint(x: visible.maxX - StickerView.width - 24 - step, y: visible.maxY - 24 - step)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isFitting else { return }
        anchor = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        saveTask?.cancel()
        saveTask = Task { [id = model.trade.id, store, anchor] in
            try? await Task.sleep(for: .milliseconds(400)) // debounce: dragging fires many moves
            guard !Task.isCancelled else { return }
            try? store.setPosition(id: id, WindowPosition(x: anchor.x, topY: anchor.y))
        }
    }
}

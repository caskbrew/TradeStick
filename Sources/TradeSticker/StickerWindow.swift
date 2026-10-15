import AppKit
import Persistence
import SwiftUI
import Widgets

/// Borderless note-like panel (M0 report): normal level, one Space, activating, no title bar.
final class StickerPanel: NSPanel {
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

/// One sticker: panel + model. Owns window geometry: fits the content height, keeps the top edge fixed,
/// pulls the window up when it would leave the screen, and remembers the position (FR-WIN-6, FR-TX-8).
@MainActor
final class StickerWindow: NSObject, NSWindowDelegate {
    let model: StickerModel
    private let panel = StickerPanel()
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
        model.onWillGrow = { [weak self] extra in self?.reserve(extra) }
        model.onFormWillOpen = { [weak self] in self?.prepareForm() }
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
        if activate {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    func hide() {
        panel.orderOut(nil)
        Task {
            await model.setVisible(false)
            onHide?()
        }
    }

    func close() {
        panel.orderOut(nil)
        panel.contentView = nil
        host.removeFromSuperview()
        Task { await model.setVisible(false) }
    }

    var isVisible: Bool { panel.isVisible }

    /// Renders the window's current content to a PNG (developer aid; needs no screen-recording permission).
    func capture(to url: URL) {
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    var frame: NSRect { panel.frame }
    /// Card height as SwiftUI currently lays it out (animated while a section opens or closes).
    var currentCardHeight: CGFloat { content.height }

    // MARK: Geometry

    // Resizing model: the window frame itself is never animated. A transparent window may be taller than the
    // card; SwiftUI animates the card inside it. Growing happens first (reserve), trimming after the content
    // has settled. Animating the frame made the glass flicker and left nothing to animate when closing.

    /// Called just before a change that makes the card taller: make room first.
    private func reserve(_ extra: CGFloat) {
        setWindowSize(CGSize(width: panel.frame.width, height: panel.frame.height + extra))
    }

    /// The form slides out to the right of the card, or to the left when the right side has no room. The window
    /// widens first (it is transparent); the card stays exactly where it is on screen.
    private func prepareForm() {
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let right = anchor.x + StickerView.width + StickerView.formDrawerWidth
        model.formOnLeft = right > (screen?.visibleFrame.maxX ?? .infinity)
        setWindowSize(CGSize(width: StickerView.width + StickerView.formDrawerWidth, height: panel.frame.height))
    }

    /// The content reported a new size: grow the window if it outgrew it, and schedule trimming once things stop moving.
    private func contentLaidOut() {
        guard content.height > 0 else { return }
        let size = panel.frame.size
        if content.height > size.height + 0.5 || content.width > size.width + 0.5 {
            setWindowSize(CGSize(width: max(size.width, content.width), height: max(size.height, content.height)))
        }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    /// Cuts the window to the content's size.
    private func settle() {
        guard content.height > 0 else { return }
        let size = panel.frame.size
        if abs(content.height - size.height) > 0.5 || abs(content.width - size.width) > 0.5 { setWindowSize(content) }
    }

    /// `anchor` is the card's top-left corner; with the form on the left the window extends to the left of it.
    private func setWindowSize(_ size: CGSize) {
        let x = model.formOnLeft ? anchor.x + StickerView.width - size.width : anchor.x
        var frame = NSRect(x: x, y: anchor.y - size.height, width: size.width, height: size.height)
        if let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame {
            if frame.minY < visible.minY { frame.origin.y = visible.minY } // shift up, never off-screen
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - size.height }
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - size.width }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
        }
        isFitting = true
        defer { isFitting = false }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
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
        anchor = NSPoint(x: model.formOnLeft ? panel.frame.maxX - StickerView.width : panel.frame.minX, y: panel.frame.maxY)
        saveTask?.cancel()
        saveTask = Task { [id = model.trade.id, store, anchor] in
            try? await Task.sleep(for: .milliseconds(400)) // debounce: dragging fires many moves
            guard !Task.isCancelled else { return }
            try? store.setPosition(id: id, WindowPosition(x: anchor.x, topY: anchor.y))
        }
    }
}

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
        collectionBehavior = []
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
    private let host: NSHostingController<StickerView>
    private var observation: NSKeyValueObservation?
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
        var actions = StickerActions(hide: {}, delete: {})
        host = NSHostingController(rootView: StickerView(model: model, actions: actions))
        super.init()
        actions = StickerActions(hide: { [weak self] in self?.hide() }, delete: { [weak self] in self?.onDelete?() })
        host.rootView = StickerView(model: model, actions: actions)
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        panel.delegate = self
        observation = host.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.fit(animated: true) }
        }
        fit(animated: false)
    }

    func show(activate: Bool) {
        fit(animated: false)
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
        panel.contentViewController = nil
        Task { await model.setVisible(false) }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Geometry

    private func fit(animated: Bool) {
        let height = host.preferredContentSize.height
        guard height > 0 else { return }
        var frame = NSRect(x: anchor.x, y: anchor.y - height, width: StickerView.width, height: height)
        if let visible = (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame {
            if frame.minY < visible.minY { frame.origin.y = visible.minY } // shift up, never off-screen
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - height }
        }
        isFitting = true
        defer { isFitting = false }
        let animate = animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(frame, display: true, animate: animate)
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

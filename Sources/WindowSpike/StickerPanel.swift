import AppKit
import Observation

/// Mirrors panel state for SwiftUI (NSPanel properties are not observable).
@MainActor @Observable
final class PanelFlags {
    var pinned = true
    var stationary = false
    var expanded = false
}

/// Borderless floating panel. `canBecomeKey` lets text fields receive typing
/// even though the panel is non-activating (the app stays in the background).
final class StickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    let flags = PanelFlags()

    static let collapsedHeight: CGFloat = 140
    static let expandedHeight: CGFloat = 340

    convenience init(index: Int) {
        let offset = CGFloat(index) * 30
        self.init(
            contentRect: NSRect(x: 200 + offset, y: 500 - offset, width: 340, height: Self.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        setFrameAutosaveName("spike-sticker-\(index)")
    }

    var isPinned: Bool {
        get { level == .floating }
        set { level = newValue ? .floating : .normal; flags.pinned = newValue }
    }

    var isStationary: Bool {
        get { collectionBehavior.contains(.stationary) }
        set {
            if newValue { collectionBehavior.insert(.stationary) } else { collectionBehavior.remove(.stationary) }
            flags.stationary = newValue
        }
    }

    var isExpanded: Bool { frame.height > Self.collapsedHeight + 1 }

    /// Grows downward: the top edge stays put (AppKit's origin is bottom-left).
    func setExpanded(_ expanded: Bool) {
        let newHeight = expanded ? Self.expandedHeight : Self.collapsedHeight
        var f = frame
        f.origin.y += f.height - newHeight
        f.size.height = newHeight
        flags.expanded = expanded
        setFrame(f, display: true, animate: true)
    }
}

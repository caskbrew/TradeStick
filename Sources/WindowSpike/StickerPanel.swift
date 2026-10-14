import AppKit
import Observation

/// Mirrors panel state for SwiftUI (NSPanel properties are not observable).
@MainActor @Observable
final class PanelFlags {
    var expanded = false
}

/// Borderless note-like window; `canBecomeKey` lets text fields receive typing.
final class StickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    let flags = PanelFlags()

    static let collapsedHeight: CGFloat = 240
    static let expandedHeight: CGFloat = 440

    convenience init(index: Int) {
        let offset = CGFloat(index) * 30
        self.init(
            contentRect: NSRect(x: 200 + offset, y: 500 - offset, width: 340, height: Self.collapsedHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Like Notes/Stickies: normal level, lives only on the Space it was created on.
        level = .normal
        collectionBehavior = []
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        setFrameAutosaveName("spike-sticker-\(index)")
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

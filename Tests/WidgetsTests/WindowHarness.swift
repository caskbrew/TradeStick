import AppKit
import SwiftUI

/// A real NSWindow, placed off screen, hosting a SwiftUI view: lets tests type, press keys, click and take true screenshots
/// (native controls included, which `ImageRenderer` cannot draw).
@MainActor final class TestWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    private static var open: [TestWindow] = []

    convenience init<V: View>(_ view: V) {
        Self.open.forEach { $0.close() } // one test window at a time: the earlier ones must not keep the focus
        Self.open.removeAll()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        self.init(contentViewController: NSHostingController(rootView: view))
        styleMask = [.borderless]
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false
        Self.open.append(self)
        setFrameOrigin(NSPoint(x: -20_000, y: -20_000)) // never visible on the user's screen
        makeKeyAndOrderFront(nil)
        settle()
    }

    /// Lets SwiftUI lay out and the run loop deliver pending work.
    func settle(_ seconds: Double = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        contentView?.layoutSubtreeIfNeeded()
    }

    var size: CGSize { frame.size }

    func allViews(of root: NSView? = nil) -> [NSView] {
        let root = root ?? contentView!
        return [root] + root.subviews.flatMap { allViews(of: $0) }
    }

    /// The text field with this placeholder, or the first one.
    func textField(placeholder: String? = nil) -> NSTextField? {
        let fields = allViews().compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        return placeholder.flatMap { p in fields.first { $0.placeholderString == p } } ?? fields.first
    }

    /// Types text into the field like a user: focus, then the field editor receives the characters.
    func type(_ text: String, into field: NSTextField) {
        makeFirstResponder(field)
        settle(0.05)
        for ch in text {
            (fieldEditor(true, for: field) as? NSTextView)?.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
            settle(0.03)
        }
    }

    enum Key: UInt16 { case returnKey = 36, escape = 53, down = 125, up = 126 }

    func press(_ key: Key) {
        let chars: String = switch key {
        case .returnKey: "\r"
        case .escape: "\u{1b}"
        case .down: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case .up: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: key.rawValue) { sendEvent(event) }
        }
        settle()
    }

    /// A click at a point of the content view (top-left origin, like SwiftUI).
    func click(x: CGFloat, y: CGFloat) {
        let point = NSPoint(x: x, y: contentView!.bounds.height - y)
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor { _ = makeFirstResponder(nil); settle(0.05) } // a click elsewhere ends editing first
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { sendEvent(event) }
        }
        settle()
    }

    /// Saves a screenshot when SNAPSHOT_DIR is set (the "screen gallery").
    func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], let view = contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }
}

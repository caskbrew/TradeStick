import AppKit
import SwiftUI

@MainActor
final class SpikeController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panels: [StickerPanel] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar agent, no Dock icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "TS"
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            ("New Sticker", #selector(newSticker)),
            ("Print State", #selector(printState)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func newSticker() {
        let panel = StickerPanel(index: panels.count)
        let hosting = NSHostingView(rootView: SpikeView(panel: panel, flags: panel.flags))
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 18
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    @objc private func printState() {
        for (i, p) in panels.enumerated() {
            print("sticker \(i): pinned=\(p.isPinned) stationary=\(p.isStationary) expanded=\(p.isExpanded) frame=\(p.frame) screen=\(p.screen?.localizedName ?? "none")")
        }
    }
}

let app = NSApplication.shared
let controller = SpikeController()
app.delegate = controller
app.run()

import AppKit
import Domain
import MarketData
import Persistence
import SwiftUI
import Testing
@testable import Widgets

/// Developer tool, not a regression test: `SNAPSHOT_DIR=/tmp/snaps swift test --filter SnapshotTests`
/// renders the sticker states to PNG so the layout can be reviewed without a screen.
@MainActor @Suite(.timeLimit(.minutes(1))) struct SnapshotTests {
    nonisolated static let dir = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]

    func render(_ model: StickerModel, name: String) throws {
        let view = ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.30), Color(red: 0.55, green: 0.30, blue: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            StickerView(model: model, actions: StickerActions(hide: {}, delete: {})).padding(24)
        }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            Issue.record("render failed"); return
        }
        try png.write(to: URL(fileURLWithPath: Self.dir!).appendingPathComponent("\(name).png"))
    }

    func make(direction: Direction = .buyFirst) throws -> (StickerModel, FakeExchange, TradeStore) {
        let store = try TradeStore.inMemory()
        let fake = FakeExchange(id: "binance")
        let hub = MarketDataHub(adapters: [fake])
        let trade = try store.createTrade(exchange: "binance", base: "GRAM", quote: "USDT", direction: direction)
        let model = StickerModel(trade: trade, store: store, hub: hub, throttle: .milliseconds(1))
        return (model, fake, store)
    }

    func exampleA(_ store: TradeStore, _ id: UUID) throws {
        let t0 = Date().addingTimeInterval(-3600)
        for (i, tx) in [(Side.buy, "1000", "50"), (.buy, "500", "30"), (.sell, "600", "40")].enumerated() {
            try store.addTransaction(tradeID: id, side: tx.0, quantity: dec(tx.1), amount: dec(tx.2), occurredAt: t0.addingTimeInterval(Double(i) * 600))
        }
    }

    @Test(.enabled(if: SnapshotTests.dir != nil))
    func renderStates() async throws {
        try FileManager.default.createDirectory(atPath: Self.dir!, withIntermediateDirectories: true)

        // 1. Empty, no price yet.
        let (empty, _, _) = try make()
        try render(empty, name: "1-empty")

        // 2. Open with a live price (example A: +9.50).
        let (live, fake, store) = try make()
        try exampleA(store, live.trade.id)
        live.reload()
        await live.refreshSubscription()
        await waitUntil { fake.connectCount == 1 }
        fake.emit(PriceTick(price: dec("0.055"), open24h: dec("0.0532"), eventTime: Date()))
        await waitUntil { live.currentPrice != nil }
        try await Task.sleep(for: .milliseconds(50))
        try render(live, name: "2-open-live")

        // 3. Form open with Rate typed.
        live.openForm(side: .sell)
        live.edit(.quantity, "300")
        live.edit(.rate, "0.06")
        try render(live, name: "3-form")

        // 4. Expanded list.
        live.cancelForm()
        live.setExpanded(true)
        try render(live, name: "4-list")

        // 4b. Compact view.
        live.setCompact(true)
        try render(live, name: "4b-compact")
        live.setCompact(false)

        // 5. Sell-first, loss.
        let (loss, fake2, store2) = try make(direction: .sellFirst)
        try store2.addTransaction(tradeID: loss.trade.id, side: .sell, quantity: 2000, amount: 110, occurredAt: Date().addingTimeInterval(-600))
        loss.reload()
        await loss.refreshSubscription()
        await waitUntil { fake2.connectCount == 1 }
        fake2.emit(PriceTick(price: dec("0.058"), open24h: dec("0.0587"), eventTime: Date()))
        await waitUntil { loss.currentPrice != nil }
        try await Task.sleep(for: .milliseconds(50))
        try render(loss, name: "5-sellfirst-loss")
    }
}

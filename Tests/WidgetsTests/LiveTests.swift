import Domain
import Foundation
import MarketData
import Persistence
import Testing
@testable import Widgets

/// Checks against the real exchanges and the dev data: `LIVE=1 swift test --filter LiveTests`.
/// Read-only. Never prints a key or a secret, only counts and statuses.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVE"] != nil), .timeLimit(.minutes(3)), .serialized) struct LiveTests {
    static let exchanges: [(any ExchangeAdapter, Instrument)] = [
        (BinanceAdapter(), Instrument(base: "BTC", quote: "USDT")),
        (PoloniexAdapter(), Instrument(base: "BTC", quote: "USDT")),
        (BybitAdapter(), Instrument(base: "BTC", quote: "USDT")),
    ]

    @Test func publicPairListPriceAndSocketWorkOnEveryExchange() async throws {
        for (adapter, btc) in Self.exchanges {
            print("LIVE \(adapter.id): start"); let t0 = Date()
            let pairs = try await adapter.instruments()
            print("LIVE \(adapter.id): pairs \(pairs.count) in \(Date().timeIntervalSince(t0))s")
            #expect(pairs.count > 100 && pairs.contains(btc), "\(adapter.id): \(pairs.count) pairs")
            #expect(try await adapter.supports(btc), "\(adapter.id) supports BTC/USDT")
            #expect(try await adapter.supports(Instrument(base: "NOPEXYZ", quote: "USDT")) == false, "\(adapter.id) rejects an unknown pair")
            print("LIVE \(adapter.id): supports ok \(Date().timeIntervalSince(t0))s")
            let snapshot = try await adapter.snapshot(for: btc)
            print("LIVE \(adapter.id): snapshot ok \(Date().timeIntervalSince(t0))s")
            #expect(snapshot.price > 1000, "\(adapter.id) price \(snapshot.price)")
            #expect(snapshot.open24h != nil)

            let tick = try await withThrowingTaskGroup(of: PriceTick?.self) { group in
                group.addTask {
                    var connected = false
                    for try await event in adapter.connect(to: btc) {
                        switch event {
                        case .connected: connected = true
                        case .tick(let t): return connected ? t : nil
                        }
                    }
                    return nil
                }
                group.addTask { try await Task.sleep(for: .seconds(30)); return nil }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            let first = try #require(tick, "\(adapter.id): no socket tick in 30 s")
            // The socket price and the REST price are for the same market, a minute apart at most.
            #expect(abs(NSDecimalNumber(decimal: first.price / snapshot.price - 1).doubleValue) < 0.02)
            print("LIVE \(adapter.id): \(pairs.count) pairs, BTC/USDT price ok, socket tick ok")
        }
    }

    static func devDatabaseCopy() throws -> String? {
        let source = try TradeStore.defaultDatabaseURL(folder: "TradeStickies-Dev")
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: "tradestick-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.copyItem(at: file, to: dir.appending(path: "tradestickies.sqlite" + suffix)) }
        }
        return dir.appending(path: "tradestickies.sqlite").path
    }

    /// The dev database (a copy) opens with the current migrations, keeps its data and stays valid when opened again.
    @Test func theDevDatabaseMigratesWithoutLosingData() async throws {
        guard let path = try Self.devDatabaseCopy() else { print("LIVE: no dev database, skipped"); return }
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let first = try TradeStore(path: path)
        let trades = try first.trades()
        let counts = try trades.map { try first.transactions(tradeID: $0.id).count }
        #expect(!trades.isEmpty)
        let second = try TradeStore(path: path)
        #expect(try second.trades().map(\.id) == trades.map(\.id))
        #expect(try trades.map { try second.transactions(tradeID: $0.id).count } == counts)
        print("LIVE dev database: \(trades.count) trades, \(counts.reduce(0, +)) transactions, migrated and reopened")
    }

    /// Binance with the key saved in the dev app: the key works and the history of every Binance trade loads, groups
    /// and is recognised as already imported where it was imported.
    @Test func binanceKeyWorksAndHistoryLoadsForTheDevTrades() async throws {
        let store = KeychainCredentialStore(service: "com.caskbrew.tradestickies.dev")
        guard let keys = (try? store.load(exchange: "binance")) ?? nil else { print("LIVE: no Binance key in the dev Keychain, skipped"); return }
        let api = BinanceAccountAPI()
        let check = try await api.check(keys)
        print("LIVE Binance key works; read-only: \(check.readOnly.map(String.init) ?? "unknown"), warnings: \(check.warnings.count)")

        guard let path = try Self.devDatabaseCopy() else { return }
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let db = try TradeStore(path: path)
        var checkedPairs = 0
        for trade in try db.trades() where trade.exchange == "binance" {
            let fills = try await api.trades(keys, Instrument(base: trade.base, quote: trade.quote))
            let grouped = ImportedTrade.groupedByOrder(fills)
            let known = try db.externalIDs(tradeID: trade.id)
            let already = fills.filter { known.contains($0.externalID) }.count
            #expect(grouped.count <= fills.count)
            #expect(Set(fills.map(\.externalID)).count == fills.count, "fill ids are unique")
            #expect(fills.map(\.occurredAt) == fills.map(\.occurredAt).sorted(), "oldest first")
            print("LIVE \(trade.base)/\(trade.quote): \(fills.count) fills, \(grouped.count) orders, \(already) already imported")
            checkedPairs += 1
        }
        print("LIVE Binance history checked for \(checkedPairs) dev trades")
    }
}

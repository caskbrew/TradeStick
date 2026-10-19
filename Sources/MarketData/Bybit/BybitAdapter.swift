import Domain
import Foundation
import os

/// Bybit spot via the public market-data endpoints (no API key).
public final class BybitAdapter: ExchangeAdapter, Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

    public let id = "bybit"
    private let restBase: URL
    private let socketURL: URL
    private let session: URLSession
    private let fetch: Fetch

    public init(
        restBase: URL = URL(string: "https://api.bybit.com")!,
        socketURL: URL = URL(string: "wss://stream.bybit.com/v5/public/spot")!,
        session: URLSession = .shared,
        fetch: Fetch? = nil
    ) {
        self.restBase = restBase
        self.socketURL = socketURL
        self.session = session
        self.fetch = fetch ?? { url in
            let (data, response) = try await session.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func url(_ path: String, _ query: String) -> URL { URL(string: restBase.appending(path: path).absoluteString + "?" + query)! }

    public func supports(_ instrument: Instrument) async throws -> Bool {
        let (data, status) = try await fetch(url("v5/market/instruments-info", "category=spot&symbol=\(BybitParsing.symbol(instrument))"))
        guard status == 200 else { throw URLError(.badServerResponse) }
        do {
            return try BybitParsing.instruments(data).list.contains { $0.instrument == instrument && $0.status == "Trading" }
        } catch let error as BybitAPIError where error.code == 10001 { // "params error": no such symbol
            return false
        }
    }

    public func instruments() async throws -> [Instrument] {
        var pages: [Data] = []
        var cursor: String?
        repeat {
            let (data, status) = try await fetch(url("v5/market/instruments-info", "category=spot&limit=1000" + (cursor.map { "&cursor=\($0)" } ?? "")))
            guard status == 200 else { throw URLError(.badServerResponse) }
            pages.append(data)
            cursor = try BybitParsing.instruments(data).next
        } while cursor != nil && pages.count < 10
        return try BybitParsing.tradableInstruments(pages)
    }

    public func snapshot(for instrument: Instrument) async throws -> PriceTick {
        let (data, status) = try await fetch(url("v5/market/tickers", "category=spot&symbol=\(BybitParsing.symbol(instrument))"))
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try BybitParsing.ticker(data, now: Date())
    }

    public func connect(to instrument: Instrument) -> AsyncThrowingStream<FeedEvent, any Error> {
        let symbol = BybitParsing.symbol(instrument)
        let session = self.session, url = socketURL
        return AsyncThrowingStream { continuation in
            let task = session.webSocketTask(with: url)
            let lastMessage = OSAllocatedUnfairLock(initialState: Date())
            let reader = Task {
                do {
                    task.resume()
                    try await task.send(.string(#"{"op":"subscribe","args":["tickers.\#(symbol)"]}"#))
                    // Bybit asks for a ping every 20 s; a silent socket (sleep, Wi-Fi change) never errors on its own, so end the
                    // stream when nothing arrives for a minute and let the hub reconnect.
                    let keepalive = Task {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(20))
                            try await task.send(.string(#"{"op":"ping"}"#))
                            if Date().timeIntervalSince(lastMessage.withLock { $0 }) > 60 { throw URLError(.timedOut) }
                        }
                    }
                    defer { keepalive.cancel() }
                    let watcher = Task {
                        do { try await keepalive.value } catch is CancellationError { return } catch { continuation.finish(throwing: error) }
                    }
                    defer { watcher.cancel() }
                    var announced = false
                    while true {
                        let data: Data
                        switch try await task.receive() {
                        case .string(let s): data = Data(s.utf8)
                        case .data(let d): data = d
                        @unknown default: continue
                        }
                        lastMessage.withLock { $0 = Date() }
                        let message = try BybitParsing.message(data, symbol: symbol)
                        if let error = message.error { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: error]) }
                        if !announced { announced = true; continuation.yield(.connected) }
                        if let tick = message.ticker { continuation.yield(.tick(tick)) }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}

import Domain
import Foundation
import os

/// Poloniex spot via the public market-data endpoints (no API key).
public final class PoloniexAdapter: ExchangeAdapter, Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

    public let id = "poloniex"
    private let restBase: URL
    private let socketURL: URL
    private let session: URLSession
    private let fetch: Fetch

    public init(
        restBase: URL = URL(string: "https://api.poloniex.com")!,
        socketURL: URL = URL(string: "wss://ws.poloniex.com/ws/public")!,
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

    public func supports(_ instrument: Instrument) async throws -> Bool {
        let (data, status) = try await fetch(restBase.appending(path: "markets/\(PoloniexParsing.symbol(instrument))"))
        if status == 400 || status == 404 { return false }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try PoloniexParsing.markets(data).contains { $0.instrument == instrument && $0.state == "NORMAL" }
    }

    public func instruments() async throws -> [Instrument] {
        let (data, status) = try await fetch(restBase.appending(path: "markets"))
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try PoloniexParsing.tradableInstruments(data)
    }

    public func snapshot(for instrument: Instrument) async throws -> PriceTick {
        let (data, status) = try await fetch(restBase.appending(path: "markets/\(PoloniexParsing.symbol(instrument))/ticker24h"))
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try PoloniexParsing.ticker24h(data, now: Date())
    }

    public func connect(to instrument: Instrument) -> AsyncThrowingStream<FeedEvent, any Error> {
        let symbol = PoloniexParsing.symbol(instrument)
        let session = self.session, url = socketURL
        return AsyncThrowingStream { continuation in
            let task = session.webSocketTask(with: url)
            let lastMessage = OSAllocatedUnfairLock(initialState: Date())
            let reader = Task {
                do {
                    task.resume()
                    try await task.send(.string(#"{"event":"subscribe","channel":["ticker"],"symbols":["\#(symbol)"]}"#))
                    // The server wants a ping every 30 s and answers with a pong; a silent socket (sleep, Wi-Fi change)
                    // never errors on its own, so end the stream when nothing arrives for a minute and let the hub reconnect.
                    let keepalive = Task {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(20))
                            try await task.send(.string(#"{"event":"ping"}"#))
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
                        let message = try PoloniexParsing.message(data, symbol: symbol)
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

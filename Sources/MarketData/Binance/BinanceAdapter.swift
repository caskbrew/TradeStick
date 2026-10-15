import Domain
import Foundation

/// Binance spot via the public market-data endpoints (no API key).
public final class BinanceAdapter: ExchangeAdapter, Sendable {
    public typealias Fetch = @Sendable (URL) async throws -> (data: Data, status: Int)

    public let id = "binance"
    private let restBase: URL
    private let streamBase: String
    private let session: URLSession
    private let fetch: Fetch

    public init(
        restBase: URL = URL(string: "https://data-api.binance.vision")!,
        streamBase: String = "wss://data-stream.binance.vision",
        session: URLSession = .shared,
        fetch: Fetch? = nil
    ) {
        self.restBase = restBase
        self.streamBase = streamBase
        self.session = session
        self.fetch = fetch ?? { url in
            let (data, response) = try await session.data(from: url)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func supports(_ instrument: Instrument) async throws -> Bool {
        let symbol = BinanceParsing.symbol(instrument)
        let (data, status) = try await fetch(restBase.appending(path: "api/v3/exchangeInfo").appending(queryItems: [.init(name: "symbol", value: symbol)]))
        if status == 400 { return false } // -1121 Invalid symbol
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try BinanceParsing.isTradableSpot(exchangeInfo: data, symbol: symbol)
    }

    public func snapshot(for instrument: Instrument) async throws -> PriceTick {
        let url = restBase.appending(path: "api/v3/ticker/24hr").appending(queryItems: [.init(name: "symbol", value: BinanceParsing.symbol(instrument))])
        let (data, status) = try await fetch(url)
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try BinanceParsing.ticker24h(data, now: Date())
    }

    public func connect(to instrument: Instrument) -> AsyncThrowingStream<FeedEvent, any Error> {
        let stream = BinanceParsing.symbol(instrument).lowercased() + "@miniTicker"
        guard let url = URL(string: "\(streamBase)/ws/\(stream)") else {
            return AsyncThrowingStream { $0.finish(throwing: URLError(.badURL)) }
        }
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = session.webSocketTask(with: url)
            let reader = Task {
                do {
                    task.resume()
                    // A successful ping means the socket is open.
                    try await Self.ping(task, timeout: .seconds(10))
                    continuation.yield(.connected)
                    // A socket that died silently (sleep, Wi-Fi change) never errors on its own: keep pinging, and
                    // end the stream when a ping goes unanswered so the hub reconnects.
                    let keepalive = Task {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(15))
                            try await Self.ping(task, timeout: .seconds(10))
                        }
                    }
                    defer { keepalive.cancel() }
                    let watcher = Task {
                        do { try await keepalive.value } catch is CancellationError { return } catch { continuation.finish(throwing: error) }
                    }
                    defer { watcher.cancel() }
                    while true {
                        let data: Data
                        switch try await task.receive() {
                        case .string(let s): data = Data(s.utf8)
                        case .data(let d): data = d
                        @unknown default: continue
                        }
                        if let tick = try BinanceParsing.miniTicker(data) { continuation.yield(.tick(tick)) }
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

    /// A ping answered within `timeout`, else a `URLError.timedOut`.
    private static func ping(_ task: URLSessionWebSocketTask, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    task.sendPing { error in
                        if let error { c.resume(throwing: error) } else { c.resume() }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                task.cancel(with: .goingAway, reason: nil) // fails the pending ping, so the group can finish
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}

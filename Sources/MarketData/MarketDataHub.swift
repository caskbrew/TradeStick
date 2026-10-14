import Domain
import Foundation

public struct PriceSubscription: Sendable {
    public let id: UUID
    public let key: MarketDataHub.Key
    /// Replays the latest state immediately, then yields every change. Only the newest value is buffered.
    public let states: AsyncStream<PriceState>
}

/// Exponential reconnect delays: 1, 2, 4, … capped (spec section 9).
public struct Backoff: Sendable {
    public var initial: Duration = .seconds(1)
    public var maximum: Duration = .seconds(30)

    public init() {}

    public func delay(attempt: Int) -> Duration {
        var d = initial
        for _ in 0..<max(attempt, 0) {
            d = d * 2
            if d >= maximum { return maximum }
        }
        return d
    }
}

/// One shared feed per (exchange, pair), reference-counted (FR-PRICE-2). The feed starts with the first
/// subscriber and is cancelled when the last one leaves.
public actor MarketDataHub {
    public struct Key: Hashable, Sendable {
        public let exchange: String
        public let instrument: Instrument

        public init(exchange: String, instrument: Instrument) {
            self.exchange = exchange
            self.instrument = instrument
        }
    }

    public enum HubError: Error, Equatable, Sendable {
        case unknownExchange(String)
    }

    private final class Feed {
        var state = PriceState()
        var lastEventTime: Date?
        var subscribers: [UUID: AsyncStream<PriceState>.Continuation] = [:]
        var tasks: [Task<Void, Never>] = []
    }

    private let adapters: [String: any ExchangeAdapter]
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let backoff: Backoff
    /// After this many failed attempts in a row the state shows `disconnected`; retries continue.
    private let disconnectedAfter = 3
    private var feeds: [Key: Feed] = [:]

    public init(
        adapters: [any ExchangeAdapter],
        backoff: Backoff = Backoff(),
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0) })
        self.backoff = backoff
        self.clock = clock
        self.sleep = sleep
    }

    public var activeFeedCount: Int { feeds.count }

    /// Latest state of a running feed, nil if nobody is subscribed to it.
    public func currentState(for key: Key) -> PriceState? { feeds[key]?.state }

    public func subscribe(_ key: Key) throws -> PriceSubscription {
        guard adapters[key.exchange] != nil else { throw HubError.unknownExchange(key.exchange) }
        let feed = feeds[key] ?? startFeed(key)
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: PriceState.self, bufferingPolicy: .bufferingNewest(1))
        feed.subscribers[id] = continuation
        continuation.yield(feed.state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id, key) }
        }
        return PriceSubscription(id: id, key: key, states: stream)
    }

    public func unsubscribe(_ subscription: PriceSubscription) {
        remove(subscription.id, subscription.key)
    }

    // MARK: Feed lifecycle

    private func startFeed(_ key: Key) -> Feed {
        let feed = Feed()
        feeds[key] = feed
        feed.tasks = [
            Task { await self.fetchSnapshot(key, feed) },
            Task { await self.run(key, feed) },
        ]
        return feed
    }

    private func remove(_ id: UUID, _ key: Key) {
        guard let feed = feeds[key], let continuation = feed.subscribers.removeValue(forKey: id) else { return }
        continuation.finish()
        if feed.subscribers.isEmpty {
            feed.tasks.forEach { $0.cancel() }
            feeds[key] = nil
        }
    }

    private func fetchSnapshot(_ key: Key, _ feed: Feed) async {
        guard let adapter = adapters[key.exchange],
              let tick = try? await adapter.snapshot(for: key.instrument),
              !Task.isCancelled, feed.state.tick == nil else { return }
        // A snapshot only fills the gap before the first streamed price; it never overrides one.
        feed.state.tick = tick
        feed.state.receivedAt = clock()
        broadcast(feed)
    }

    private func run(_ key: Key, _ feed: Feed) async {
        guard let adapter = adapters[key.exchange] else { return }
        var failures = 0
        while !Task.isCancelled {
            setConnection(feed, failures == 0 && feed.state.receivedAt == nil ? .connecting : .reconnecting)
            do {
                for try await event in adapter.connect(to: key.instrument) {
                    switch event {
                    case .connected:
                        failures = 0
                        setConnection(feed, .connected)
                    case .tick(let tick):
                        apply(tick, feed)
                    }
                }
            } catch {
                // fall through to reconnect
            }
            if Task.isCancelled { return }
            setConnection(feed, failures + 1 >= disconnectedAfter ? .disconnected : .reconnecting)
            try? await sleep(backoff.delay(attempt: failures))
            failures += 1
        }
    }

    private func apply(_ tick: PriceTick, _ feed: Feed) {
        // Drop updates older than the newest one already accepted (FR-PRICE-8).
        if let last = feed.lastEventTime, tick.eventTime < last { return }
        feed.lastEventTime = tick.eventTime
        feed.state.tick = tick
        feed.state.receivedAt = clock()
        broadcast(feed)
    }

    private func setConnection(_ feed: Feed, _ state: ConnectionState) {
        guard feed.state.connection != state else { return }
        feed.state.connection = state
        broadcast(feed)
    }

    private func broadcast(_ feed: Feed) {
        for continuation in feed.subscribers.values { continuation.yield(feed.state) }
    }
}

import Domain
import Foundation

public struct PriceTick: Equatable, Sendable {
    /// Last traded price (FR-PRICE-9).
    public var price: Decimal
    /// Price 24 h ago, if the exchange provides it (FR-PRICE-10).
    public var open24h: Decimal?
    /// Exchange event time; used to drop out-of-order updates (FR-PRICE-8).
    public var eventTime: Date

    public init(price: Decimal, open24h: Decimal? = nil, eventTime: Date) {
        self.price = price
        self.open24h = open24h
        self.eventTime = eventTime
    }
}

public enum ConnectionState: Equatable, Sendable {
    case connecting, connected, reconnecting, disconnected
}

public enum Freshness: Equatable, Sendable {
    case fresh, stale, unknown
}

/// Events of one connection attempt, as produced by an adapter.
public enum FeedEvent: Equatable, Sendable {
    case connected
    case tick(PriceTick)
}

/// What the UI sees for one (exchange, pair). Connection and freshness are independent (FR-PRICE-3).
public struct PriceState: Equatable, Sendable {
    public var tick: PriceTick?
    /// Local time the latest accepted price arrived.
    public var receivedAt: Date?
    public var connection: ConnectionState

    public init(tick: PriceTick? = nil, receivedAt: Date? = nil, connection: ConnectionState = .connecting) {
        self.tick = tick
        self.receivedAt = receivedAt
        self.connection = connection
    }

    /// Age of the last update for this pair, not of the connection (FR-PRICE-4). Default threshold is 120 s.
    public func freshness(at now: Date, staleAfter: TimeInterval = 120) -> Freshness {
        guard let receivedAt else { return .unknown }
        return now.timeIntervalSince(receivedAt) > staleAfter ? .stale : .fresh
    }

    /// `(last - open24h) / open24h` as a fraction; nil if unavailable (FR-PRICE-10).
    public var change24h: Decimal? {
        guard let tick, let open = tick.open24h, open > 0 else { return nil }
        return (tick.price - open) / open
    }
}

/// Everything a new exchange has to implement (FR-EX-3). Domain, Persistence and UI never see an adapter's details.
public protocol ExchangeAdapter: Sendable {
    /// Opaque identifier stored with a trade, e.g. "binance".
    var id: String { get }
    /// Is the pair listed and tradable on this exchange (FR-NEW-2)?
    func supports(_ instrument: Instrument) async throws -> Bool
    /// One-off price, used for a fast first value (FR-PRICE-5).
    func snapshot(for instrument: Instrument) async throws -> PriceTick
    /// One connection attempt. Yields `.connected` once open, then ticks; ends or throws when the connection drops.
    /// Reconnecting is the hub's job, not the adapter's.
    func connect(to instrument: Instrument) -> AsyncThrowingStream<FeedEvent, any Error>
}

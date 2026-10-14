import Domain
import Foundation

/// In-memory exchange for tests and previews. Proves a new exchange needs only an adapter (FR-EX-5).
public final class FakeExchange: ExchangeAdapter, @unchecked Sendable {
    public struct Dropped: Error {}

    public let id: String
    private let lock = NSLock()
    private var continuations: [AsyncThrowingStream<FeedEvent, any Error>.Continuation] = []
    private var _connectCount = 0
    private var _snapshot: PriceTick?
    private var _listed: Set<Instrument>

    public init(id: String, listed: Set<Instrument> = [], snapshot: PriceTick? = nil) {
        self.id = id
        _listed = listed
        _snapshot = snapshot
    }

    /// How many connection attempts were made so far.
    public var connectCount: Int { lock.withLock { _connectCount } }

    public func supports(_ instrument: Instrument) async throws -> Bool {
        lock.withLock { _listed.contains(instrument) }
    }

    public func snapshot(for instrument: Instrument) async throws -> PriceTick {
        guard let tick = lock.withLock({ _snapshot }) else { throw Dropped() }
        return tick
    }

    public func connect(to instrument: Instrument) -> AsyncThrowingStream<FeedEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: FeedEvent.self, throwing: (any Error).self)
        lock.withLock {
            _connectCount += 1
            continuations.append(continuation)
        }
        continuation.yield(.connected)
        return stream
    }

    /// Sends a tick on the current connection.
    public func emit(_ tick: PriceTick) {
        lock.withLock { continuations.last }?.yield(.tick(tick))
    }

    /// Breaks the current connection, as a network failure would.
    public func drop() {
        lock.withLock { continuations.popLast() }?.finish(throwing: Dropped())
    }
}

import Domain
import Foundation
import Testing
@testable import MarketData

let gram = Instrument(base: "gram", quote: "usdt")
func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
func tick(_ price: String, open: String? = nil, t: Double) -> PriceTick {
    PriceTick(price: dec(price), open24h: open.map(dec), eventTime: Date(timeIntervalSince1970: t))
}

/// Polls until the condition holds; the suites have a time limit, so a bug fails instead of hanging.
func waitUntil(_ condition: @Sendable () async -> Bool) async {
    while await !condition() { try? await Task.sleep(for: .milliseconds(2)) }
}

func next(_ sub: PriceSubscription, where predicate: (PriceState) -> Bool) async -> PriceState? {
    for await state in sub.states where predicate(state) { return state }
    return nil
}

actor SleepRecorder {
    private(set) var delays: [Duration] = []
    func record(_ d: Duration) { delays.append(d) }
}

/// Always fails before connecting, like an unreachable network.
struct DownExchange: ExchangeAdapter {
    let id = "down"
    func supports(_ instrument: Instrument) async throws -> Bool { false }
    func instruments() async throws -> [Instrument] { [] }
    func snapshot(for instrument: Instrument) async throws -> PriceTick { throw FakeExchange.Dropped() }
    func connect(to instrument: Instrument) -> AsyncThrowingStream<FeedEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: FakeExchange.Dropped()) }
    }
}

@Suite(.timeLimit(.minutes(1))) struct HubTests {
    let key = MarketDataHub.Key(exchange: "fake", instrument: gram)

    func makeHub(_ adapters: [any ExchangeAdapter], recorder: SleepRecorder = SleepRecorder()) -> MarketDataHub {
        MarketDataHub(
            adapters: adapters,
            clock: { Date(timeIntervalSince1970: 1_000) },
            sleep: { d in await recorder.record(d); try await Task.sleep(for: .milliseconds(1)) }
        )
    }

    @Test func reconnectAllReplacesAnOpenSocketAtOnce() async throws {
        let fake = FakeExchange(id: "fake")
        let hub = makeHub([fake])
        let sub = try await hub.subscribe(key)
        await waitUntil { fake.connectCount == 1 }
        _ = await next(sub) { $0.connection == .connected }
        await hub.reconnectAll() // e.g. after the Mac woke up: the old socket is dead but silent
        await waitUntil { fake.connectCount == 2 }
        fake.emit(tick("1.36", t: 10))
        let state = await next(sub) { $0.tick != nil && $0.connection == .connected }
        #expect(state?.tick?.price == dec("1.36"))
        await hub.unsubscribe(sub)
    }

    @Test func twentySubscribersShareOneFeed() async throws {
        let fake = FakeExchange(id: "fake")
        let hub = makeHub([fake])
        var subs: [PriceSubscription] = []
        for _ in 0..<20 { subs.append(try await hub.subscribe(key)) }
        await waitUntil { fake.connectCount >= 1 }
        #expect(fake.connectCount == 1)
        #expect(await hub.activeFeedCount == 1)

        fake.emit(tick("0.055", t: 1))
        for sub in subs {
            let state = await next(sub) { $0.tick != nil }
            #expect(state?.tick?.price == dec("0.055"))
        }
    }

    @Test func feedStopsWhenTheLastSubscriberLeaves() async throws {
        let fake = FakeExchange(id: "fake")
        let hub = makeHub([fake])
        let a = try await hub.subscribe(key), b = try await hub.subscribe(key)
        await hub.unsubscribe(a)
        #expect(await hub.activeFeedCount == 1)
        await hub.unsubscribe(b)
        #expect(await hub.activeFeedCount == 0)
    }

    @Test func newSubscriberGetsTheLatestStateImmediately() async throws {
        let fake = FakeExchange(id: "fake")
        let hub = makeHub([fake])
        let first = try await hub.subscribe(key)
        await waitUntil { fake.connectCount == 1 }
        fake.emit(tick("0.055", open: "0.05", t: 1))
        _ = await next(first) { $0.tick != nil }

        let late = try await hub.subscribe(key)
        let state = await next(late) { _ in true }
        #expect(state?.tick?.price == dec("0.055"))
        #expect(state?.change24h == dec("0.1"))
        #expect(fake.connectCount == 1)
    }

    @Test func outOfOrderTicksAreDropped() async throws {
        let fake = FakeExchange(id: "fake")
        let hub = makeHub([fake])
        let sub = try await hub.subscribe(key)
        await waitUntil { fake.connectCount == 1 }
        fake.emit(tick("0.060", t: 10))
        _ = await next(sub) { $0.tick?.price == dec("0.060") }

        fake.emit(tick("0.050", t: 5)) // older event: must be ignored
        for _ in 0..<50 { // give the hub time to (wrongly) apply it
            try await Task.sleep(for: .milliseconds(2))
            #expect(await hub.currentState(for: key)?.tick?.price == dec("0.060"))
        }

        fake.emit(tick("0.070", t: 11))
        #expect(await next(sub) { $0.tick?.price == dec("0.070") } != nil)
    }

    @Test func snapshotFillsTheGapButNeverOverridesAStreamedPrice() async throws {
        let fake = FakeExchange(id: "fake", snapshot: tick("0.0500", t: 0))
        let hub = makeHub([fake])
        let sub = try await hub.subscribe(key)
        let first = await next(sub) { $0.tick != nil }
        #expect(first?.tick?.price == dec("0.0500")) // fast first value before any stream tick

        await waitUntil { fake.connectCount == 1 }
        fake.emit(tick("0.0600", t: 1))
        let streamed = await next(sub) { $0.tick?.price == dec("0.0600") }
        #expect(streamed != nil)
    }

    @Test func reconnectsWithBackoffAfterAConnectionDrop() async throws {
        let fake = FakeExchange(id: "fake")
        let recorder = SleepRecorder()
        let hub = makeHub([fake], recorder: recorder)
        let sub = try await hub.subscribe(key)
        await waitUntil { fake.connectCount == 1 }
        _ = await next(sub) { $0.connection == .connected }

        fake.drop()
        await waitUntil { fake.connectCount == 2 }
        let state = await next(sub) { $0.connection == .connected }
        #expect(state != nil)
        #expect(await recorder.delays == [.seconds(1)])
    }

    @Test func showsDisconnectedAfterRepeatedFailuresAndKeepsRetrying() async throws {
        let recorder = SleepRecorder()
        let hub = makeHub([DownExchange()], recorder: recorder)
        let sub = try await hub.subscribe(.init(exchange: "down", instrument: gram))
        let state = await next(sub) { $0.connection == .disconnected }
        #expect(state?.tick == nil)
        await waitUntil { await recorder.delays.count >= 4 }
        #expect(Array(await recorder.delays.prefix(4)) == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    @Test func unknownExchangeIsRejected() async {
        let hub = makeHub([])
        await #expect(throws: MarketDataHub.HubError.unknownExchange("fake")) { try await hub.subscribe(key) }
    }

    // FR-EX-5 / AC-13: a second exchange needs only another adapter instance.
    @Test func twoExchangesRunSideBySideWithoutAnyOtherChange() async throws {
        let a = FakeExchange(id: "a"), b = FakeExchange(id: "b")
        let hub = makeHub([a, b])
        let subA = try await hub.subscribe(.init(exchange: "a", instrument: gram))
        let subB = try await hub.subscribe(.init(exchange: "b", instrument: gram))
        await waitUntil { a.connectCount == 1 && b.connectCount == 1 }
        a.emit(tick("0.055", t: 1))
        b.emit(tick("0.056", t: 1))
        #expect(await next(subA) { $0.tick != nil }?.tick?.price == dec("0.055"))
        #expect(await next(subB) { $0.tick != nil }?.tick?.price == dec("0.056"))
        #expect(await hub.activeFeedCount == 2)
    }
}

@Suite struct PriceStateTests {
    @Test func freshnessDependsOnAgeOfTheLastUpdate() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(PriceState().freshness(at: now) == .unknown)
        #expect(PriceState(receivedAt: now.addingTimeInterval(-119)).freshness(at: now) == .fresh)
        #expect(PriceState(receivedAt: now.addingTimeInterval(-121)).freshness(at: now) == .stale)
    }

    @Test func change24hIsHiddenWithoutAUsableOpenPrice() {
        #expect(PriceState(tick: tick("0.055", t: 1)).change24h == nil)
        #expect(PriceState(tick: tick("0.055", open: "0", t: 1)).change24h == nil)
        #expect(PriceState(tick: tick("0.055", open: "0.05", t: 1)).change24h == dec("0.1"))
    }

    @Test func backoffDoublesAndIsCapped() {
        let b = Backoff()
        #expect((0..<7).map { b.delay(attempt: $0) } == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    }
}

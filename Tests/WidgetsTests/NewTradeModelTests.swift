import Domain
import MarketData
import Testing
@testable import Widgets

struct BrokenExchange: ExchangeAdapter {
    let id = "broken"
    func supports(_ instrument: Instrument) async throws -> Bool { throw FakeExchange.Dropped() }
    func snapshot(for instrument: Instrument) async throws -> PriceTick { throw FakeExchange.Dropped() }
    func connect(to instrument: Instrument) -> AsyncThrowingStream<FeedEvent, any Error> { AsyncThrowingStream { $0.finish() } }
}

@MainActor @Suite struct NewTradeModelTests {
    let gram = Instrument(base: "GRAM", quote: "USDT")

    func model(_ adapters: [any ExchangeAdapter]? = nil) -> NewTradeModel {
        NewTradeModel(adapters: adapters ?? [FakeExchange(id: "fake", listed: [gram])])
    }

    @Test func listedPairInAnyNotationIsAccepted() async {
        for text in ["GRAM/USDT", "gram-usdt", "GRAMUSDT"] {
            let m = model()
            m.pairText = text
            m.direction = .sellFirst
            #expect(await m.validate() == NewTradeRequest(exchange: "fake", instrument: gram, direction: .sellFirst), "\(text)")
            #expect(m.error == nil)
        }
    }

    @Test func unlistedPairIsRejectedWithAReadableMessage() async {
        let m = model()
        m.pairText = "FOO/USDT"
        #expect(await m.validate() == nil)
        #expect(m.error == "FOO/USDT is not available for spot trading on Fake")
    }

    @Test func garbageAsksForAPair() async {
        let m = model()
        m.pairText = "???"
        #expect(await m.validate() == nil)
        #expect(m.error == "Enter a pair like GRAM/USDT")
    }

    @Test func networkFailureIsNotReportedAsAMissingPair() async {
        let m = model([BrokenExchange()])
        m.pairText = "GRAM/USDT"
        #expect(await m.validate() == nil)
        #expect(m.error?.hasPrefix("Could not check the pair") == true)
    }

    @Test func validationClearsThePreviousError() async {
        let m = model()
        m.pairText = "???"
        _ = await m.validate()
        m.pairText = "GRAM/USDT"
        #expect(await m.validate() != nil)
        #expect(m.error == nil)
    }
}

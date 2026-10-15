import Foundation
import Persistence
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

@MainActor @Suite struct APIKeysModelTests {
    func model(_ store: InMemoryCredentialStore, ok: Bool = true) -> APIKeysModel {
        APIKeysModel(store: store, check: { _ in
            if ok { return APIKeyCheck(warnings: ["Trading is enabled for this key"]) }
            throw BinanceAPIError(status: 401, code: -2015, message: "Invalid API-key")
        })
    }

    @Test func aWorkingKeyIsSavedAndTheSecretFieldIsCleared() async {
        let store = InMemoryCredentialStore()
        let m = model(store)
        m.keyText = " KEY "; m.secretText = "SEC\n"
        await m.save()
        #expect(store.load(exchange: "binance") == APICredentials(key: "KEY", secret: "SEC"))
        #expect(m.secretText == "" && m.hasSavedKey)
        #expect(m.status == .ok("Saved", warnings: ["Trading is enabled for this key"]))
    }

    @Test func aRejectedKeyIsNotSaved() async {
        let store = InMemoryCredentialStore()
        let m = model(store, ok: false)
        m.keyText = "K"; m.secretText = "S"
        await m.save()
        #expect(store.load(exchange: "binance") == nil)
        #expect(m.status == .failed("Not saved: Invalid API-key (-2015)"))
    }

    @Test func savedSecretIsReusedWhileTheKeyIsUnchanged() async throws {
        let store = InMemoryCredentialStore()
        try store.save(APICredentials(key: "K", secret: "S"), exchange: "binance")
        let m = model(store)
        #expect(m.keyText == "K" && m.hasSavedKey && m.canSubmit) // empty secret field: keep the saved one
        m.keyText = "OTHER"
        #expect(!m.canSubmit) // a different key needs its own secret
    }

    @Test func removeForgetsTheKey() async throws {
        let store = InMemoryCredentialStore()
        try store.save(APICredentials(key: "K", secret: "S"), exchange: "binance")
        let m = model(store)
        m.remove()
        #expect(store.load(exchange: "binance") == nil && !m.hasSavedKey && m.keyText == "")
    }
}

@MainActor @Suite struct ImportModelTests {
    nonisolated func fill(_ id: String, _ side: Side = .buy) -> ImportedTrade {
        ImportedTrade(externalID: id, side: side, quantity: 1, amount: 1, occurredAt: Date(timeIntervalSince1970: Double(Int(id)!)))
    }

    func model(known: Set<String> = [], commit: @escaping ([ImportedTrade]) -> String? = { _ in nil }) -> ImportModel {
        ImportModel(title: "t", fetch: { [fill("1"), fill("2", .sell), fill("3")] }, existing: { known }, commit: commit)
    }

    @Test func listsNewestFirstAndMarksWhatIsAlreadyAdded() async {
        let m = model(known: ["2"])
        await m.load()
        #expect(m.rows.map(\.id) == ["3", "2", "1"])
        #expect(m.rows.map(\.alreadyAdded) == [false, true, false])
        m.toggle("2") // an added row cannot be picked
        #expect(m.selection.isEmpty)
        m.selectAll()
        #expect(m.selection == ["1", "3"])
    }

    @Test func addPassesOnlyTheSelectedTrades() async {
        nonisolated(unsafe) var received: [String] = []
        let m = model { received = $0.map(\.externalID); return nil }
        await m.load()
        m.toggle("1"); m.toggle("3")
        #expect(m.add() && m.added == 2)
        #expect(received == ["3", "1"]) // as listed, newest first: the store orders by time
    }

    @Test func aRejectedAddKeepsTheWindowOpenWithTheMessage() async {
        let m = model { _ in "Not enough open quantity" }
        await m.load()
        m.selectAll()
        #expect(!m.add())
        #expect(m.error == "Not enough open quantity" && m.added == nil && m.canAdd)
    }

    @Test func aFailedLoadIsShown() async {
        let m = ImportModel(title: "t", fetch: { throw BinanceAPIError(status: 401, code: -2015, message: "Invalid API-key") }, existing: { [] }, commit: { _ in nil })
        await m.load()
        #expect(m.state == .failed("Invalid API-key (-2015)"))
    }
}

import Foundation
import Persistence
import Domain
import MarketData
import Testing
@testable import Widgets

struct BrokenExchange: ExchangeAdapter {
    let id = "broken"
    func supports(_ instrument: Instrument) async throws -> Bool { throw FakeExchange.Dropped() }
    func instruments() async throws -> [Instrument] { throw FakeExchange.Dropped() }
    func snapshot(for instrument: Instrument) async throws -> PriceTick { throw FakeExchange.Dropped() }
    func connect(to instrument: Instrument) -> AsyncThrowingStream<FeedEvent, any Error> { AsyncThrowingStream { $0.finish() } }
}

@MainActor @Suite struct NewTradeModelTests {
    let gram = Instrument(base: "GRAM", quote: "USDT")

    func model(_ adapters: [any ExchangeAdapter]? = nil) -> NewTradeModel {
        NewTradeModel(adapters: adapters ?? [FakeExchange(id: "fake", listed: [gram])], defaults: UserDefaults(suiteName: UUID().uuidString)!)
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
        APIKeysModel(store: store, defaults: UserDefaults(suiteName: UUID().uuidString)!, check: { _ in
            if ok { return APIKeyCheck(warnings: ["Trading is enabled for this key"], readOnly: false) }
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
        #expect(m.status == .ok("Saved") && m.connected && m.readOnly == false && m.lastChecked != nil)
        #expect(m.warnings == ["Trading is enabled for this key"])
    }

    @Test func aRejectedKeyIsNotSaved() async {
        let store = InMemoryCredentialStore()
        let m = model(store, ok: false)
        m.keyText = "K"; m.secretText = "S"
        await m.save()
        #expect(store.load(exchange: "binance") == nil)
        #expect(m.status == .failed("Not saved: Invalid API-key (-2015)") && !m.connected)
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

@MainActor @Suite struct ImportGroupingTests {
    nonisolated func fill(_ id: String, order: String?, _ side: Side = .buy, qty: Decimal = 1, amt: Decimal = 2, t: Double) -> ImportedTrade {
        ImportedTrade(externalID: id, side: side, quantity: qty, amount: amt, occurredAt: Date(timeIntervalSince1970: t), orderID: order, fees: ["BNB": 1])
    }

    func model(known: Set<String> = []) -> ImportModel {
        ImportModel(title: "t", fetch: { [fill] in
            [fill("1", "10", .buy, 2, 4, 100), fill("2", "10", .buy, 3, 7, 101), fill("3", "11", .sell, 1, 3, 200)]
        }, existing: { known }, commit: { _ in nil })
    }

    @Test func fillsOfOneOrderBecomeOneRowWithAveragePrice() async throws {
        let m = model()
        await m.load()
        #expect(m.rows.map(\.id) == ["o11", "o10"])
        let order = try #require(m.rows.last?.trade)
        #expect(order.quantity == 5 && order.amount == 11 && order.fillIDs == ["1", "2"] && order.occurredAt == Date(timeIntervalSince1970: 101))
        #expect(order.rate == dec("2.2") && order.feeText == "2 BNB")
        m.setGrouped(false)
        #expect(m.rows.map(\.id) == ["3", "2", "1"])
    }

    @Test func anOrderImportedAsFillsIsAddedAndHalfImportedIsLocked() async {
        let all = model(known: ["1", "2"]); await all.load()
        #expect(all.rows.map(\.alreadyAdded) == [false, true])
        let half = model(known: ["1"]); await half.load()
        #expect(half.rows.map(\.partlyAdded) == [false, true] && half.rows.last?.selectable == false)
        half.selectAll()
        #expect(half.selection == ["o11"])
    }

    @Test func aGroupedOrderImportedBeforeShowsItsFillsAsAdded() async {
        let m = model(known: ["o10"]); await m.load()
        m.setGrouped(false)
        #expect(m.rows.map(\.alreadyAdded) == [false, true, true])
    }
}

@MainActor @Suite struct ImportTableTests {
    nonisolated func fill(_ id: String, amt: Decimal) -> ImportedTrade {
        ImportedTrade(externalID: id, side: .buy, quantity: 1, amount: amt, occurredAt: Date(timeIntervalSince1970: Double(Int(id)!)))
    }

    func model() -> ImportModel {
        ImportModel(title: "t", pair: "GRAM / USDT", quote: "USDT", fetch: { [fill] in [fill("1", 10), fill("2", 20), fill("3", 30)] },
                    existing: { ["2"] }, commit: { _ in nil })
    }

    @Test func filterAndSortChangeWhatIsShown() async {
        let m = model(); await m.load()
        #expect(m.visibleRows.map(\.id) == ["3", "2", "1"])
        m.newestFirst = false
        #expect(m.visibleRows.map(\.id) == ["1", "2", "3"])
        m.filter = .newOnly
        #expect(m.visibleRows.map(\.id) == ["1", "3"])
    }

    @Test func selectedAmountAndSelectAllToggle() async {
        let m = model(); await m.load()
        #expect(!m.allSelected)
        m.toggleAll()
        #expect(m.selection == ["1", "3"] && m.allSelected && m.selectedAmount == 40)
        m.toggleAll()
        #expect(m.selection.isEmpty && m.selectedAmount == 0)
        #expect(m.fixedQuote)
    }
}

@MainActor @Suite struct PairSuggestionTests {
    let pairs: Set<Instrument> = [
        Instrument(base: "GRAM", quote: "USDT"), Instrument(base: "BTC", quote: "USDT"), Instrument(base: "ETH", quote: "BTC"),
        Instrument(base: "GRAM", quote: "BTC"), Instrument(base: "TRAM", quote: "USDT"),
    ]

    func loaded() async -> NewTradeModel {
        let m = NewTradeModel(adapters: [FakeExchange(id: "fake", listed: pairs)], defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await m.loadInstruments()
        return m
    }

    @Test func emptyInputListsUsdtPairs() async {
        let m = await loaded()
        #expect(m.suggestions.map(\.base) == ["BTC", "GRAM", "TRAM"])
    }

    @Test func typedTextFiltersWithAnyCaseAndSeparatorPrefixFirst() async {
        let m = await loaded()
        m.pairText = "gram"
        #expect(m.suggestions.map(\.description).count == 2 && m.suggestions.allSatisfy { $0.base == "GRAM" })
        m.pairText = "ram/us"
        #expect(m.suggestions.map(\.base) == ["GRAM", "TRAM"]) // contains, in list order
        m.pairText = "tram"
        #expect(m.suggestions == [Instrument(base: "TRAM", quote: "USDT")])
        m.pairText = "gram/"
        #expect(!m.suggestions.isEmpty && m.suggestions.allSatisfy { $0.base == "GRAM" })
        m.pairText = "zzz"
        #expect(m.suggestions.isEmpty)
    }

    @Test func pickingFillsTheFieldAndTheListSurvivesAFailedLoad() async {
        let m = await loaded()
        m.pick(Instrument(base: "GRAM", quote: "USDT"))
        #expect(m.pairText == "GRAM/USDT")
        let broken = NewTradeModel(adapters: [BrokenExchange()], defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await broken.loadInstruments()
        #expect(broken.instruments.isEmpty && broken.suggestions.isEmpty)
    }

    @Test func lastLoadedPairsAreShownAtOnceNextTime() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = NewTradeModel(adapters: [FakeExchange(id: "fake", listed: [Instrument(base: "GRAM", quote: "USDT")])], defaults: defaults)
        #expect(first.instruments.isEmpty)
        await first.loadInstruments()
        let second = NewTradeModel(adapters: [BrokenExchange()], defaults: defaults) // new window, nothing loaded yet
        #expect(second.instruments.isEmpty) // another exchange id: nothing cached
        let again = NewTradeModel(adapters: [FakeExchange(id: "fake", listed: [])], defaults: defaults)
        #expect(again.instruments == [Instrument(base: "GRAM", quote: "USDT")])
        await again.loadInstruments() // an empty or failed refresh keeps the old list
        #expect(again.instruments == [Instrument(base: "GRAM", quote: "USDT")])
    }
}

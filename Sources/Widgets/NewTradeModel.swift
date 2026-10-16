import Foundation
import Domain
import MarketData
import Observation
import Presentation

public struct NewTradeRequest: Equatable, Sendable {
    public let exchange: String
    public let instrument: Instrument
    public let direction: Direction
}

/// Logic of the "New Trade" dialog (FR-NEW-1…3): the pair is checked against the chosen exchange.
@MainActor @Observable
public final class NewTradeModel {
    public var exchange: String
    public var pairText = ""
    public var direction: Direction = .buyFirst
    public private(set) var isChecking = false
    public private(set) var error: String?
    /// Pairs of the chosen exchange, for the drop-down.
    public private(set) var instruments: [Instrument] = []
    public private(set) var instrumentsLoading = false

    public let exchanges: [String]
    @ObservationIgnored private let adapters: [String: any ExchangeAdapter]
    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter defaults: where the last loaded pair list of each exchange is kept, to show it at once next time.
    public init(adapters: [any ExchangeAdapter], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0) })
        self.exchanges = adapters.map(\.id)
        self.exchange = adapters.first?.id ?? ""
        self.instruments = Self.cached(exchange, in: defaults)
    }

    private static func cached(_ exchange: String, in defaults: UserDefaults) -> [Instrument] {
        (defaults.stringArray(forKey: "instruments.\(exchange)") ?? []).compactMap { text in
            let parts = text.split(separator: "/").map(String.init)
            return parts.count == 2 ? Instrument(base: parts[0], quote: parts[1]) : nil
        }
    }

    public func loadInstruments() async {
        guard let adapter = adapters[exchange] else { return }
        let id = adapter.id
        instruments = Self.cached(id, in: defaults) // shown while the fresh list loads
        instrumentsLoading = true
        defer { instrumentsLoading = false }
        guard let loaded = try? await adapter.instruments(), !loaded.isEmpty else { return } // keep the old list on a failure
        defaults.set(loaded.map(\.description), forKey: "instruments.\(id)")
        if id == exchange { instruments = loaded } // the exchange may have been switched meanwhile
    }

    /// Pairs matching what is typed (any case and separator; `gram`, `gram/us`, `GRAMUSDT`), best first, at most 100:
    /// exact base, then names starting with the text, then the rest; USDT pairs first within each group.
    /// Nothing typed: USDT pairs, alphabetical.
    public var suggestions: [Instrument] {
        let query = String(pairText.uppercased().filter { $0.isLetter || $0.isNumber })
        guard !query.isEmpty else { return Array(instruments.filter { $0.quote == "USDT" }.prefix(100)) }
        func rank(_ i: Instrument) -> Int? {
            let name = i.base + i.quote
            guard name.contains(query) else { return nil }
            let group = i.base == query ? 0 : name.hasPrefix(query) ? 1 : 2
            return group * 2 + (i.quote == "USDT" ? 0 : 1)
        }
        let ranked = instruments.compactMap { i in rank(i).map { (i, $0) } }
        return Array(ranked.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0).prefix(100))
    }

    public func pick(_ instrument: Instrument) { pairText = "\(instrument.base)/\(instrument.quote)"; error = nil }

    /// Returns the request when the pair exists and is tradable on the exchange; otherwise sets `error`.
    public func validate() async -> NewTradeRequest? {
        error = nil
        guard let adapter = adapters[exchange] else { error = "Choose an exchange"; return nil }
        let candidates = InstrumentParser.candidates(pairText)
        guard !candidates.isEmpty else {
            error = "Enter a pair like GRAM/USDT"
            return nil
        }
        isChecking = true
        defer { isChecking = false }
        do {
            for instrument in candidates where try await adapter.supports(instrument) {
                return NewTradeRequest(exchange: exchange, instrument: instrument, direction: direction)
            }
        } catch {
            self.error = "Could not check the pair on \(exchange.capitalized). Check your connection and try again."
            return nil
        }
        error = "\(candidates[0]) is not available for spot trading on \(exchange.capitalized)"
        return nil
    }
}

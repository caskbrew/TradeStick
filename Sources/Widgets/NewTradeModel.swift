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

    public init(adapters: [any ExchangeAdapter]) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0) })
        self.exchanges = adapters.map(\.id)
        self.exchange = adapters.first?.id ?? ""
    }

    public func loadInstruments() async {
        guard let adapter = adapters[exchange] else { return }
        instrumentsLoading = true
        defer { instrumentsLoading = false }
        let loaded = (try? await adapter.instruments()) ?? []
        if adapter.id == exchange { instruments = loaded } // the exchange may have been switched meanwhile
    }

    /// Pairs matching what is typed (any case and separator; `gram`, `gram/us`, `GRAMUSDT`), best first, at most 100.
    /// Nothing typed: USDT pairs, alphabetical.
    public var suggestions: [Instrument] {
        let query = String(pairText.uppercased().filter { $0.isLetter || $0.isNumber })
        guard !query.isEmpty else { return Array(instruments.filter { $0.quote == "USDT" }.prefix(100)) }
        let hits = instruments.filter { ($0.base + $0.quote).contains(query) }
        let starts = hits.filter { ($0.base + $0.quote).hasPrefix(query) }
        return Array((starts + hits.filter { !($0.base + $0.quote).hasPrefix(query) }).prefix(100))
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

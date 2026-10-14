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

    public let exchanges: [String]
    @ObservationIgnored private let adapters: [String: any ExchangeAdapter]

    public init(adapters: [any ExchangeAdapter]) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.id, $0) })
        self.exchanges = adapters.map(\.id)
        self.exchange = adapters.first?.id ?? ""
    }

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

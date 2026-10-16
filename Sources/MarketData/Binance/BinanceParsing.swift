import Domain
import Foundation

/// Pure parsers for Binance payloads, tested on recorded samples.
enum BinanceParsing {
    struct ParseError: Error, Equatable { let reason: String }

    private static func decimal(_ s: String) throws -> Decimal {
        guard let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { throw ParseError(reason: "decimal \(s)") }
        return d
    }

    /// `<base><quote>`, e.g. GRAMUSDT.
    static func symbol(_ instrument: Instrument) -> String { instrument.base + instrument.quote }

    /// `@miniTicker` message: `c` last price, `o` 24 h open, `E` event time in ms.
    static func miniTicker(_ data: Data) throws -> PriceTick? {
        struct Message: Decodable {
            let eventTimeMs: Int64?
            let close: String?
            let open: String?
            enum CodingKeys: String, CodingKey { case eventTimeMs = "E", close = "c", open = "o" }
        }
        let m = try JSONDecoder().decode(Message.self, from: data)
        guard let close = m.close, let ms = m.eventTimeMs else { return nil } // not a ticker message
        return PriceTick(
            price: try decimal(close),
            open24h: try m.open.map(decimal),
            eventTime: Date(timeIntervalSince1970: Double(ms) / 1000)
        )
    }

    /// `GET /api/v3/ticker/24hr?symbol=…`. The REST body has no event time, so the caller passes the local one.
    static func ticker24h(_ data: Data, now: Date) throws -> PriceTick {
        struct Message: Decodable { let lastPrice: String; let openPrice: String? }
        let m = try JSONDecoder().decode(Message.self, from: data)
        return PriceTick(price: try decimal(m.lastPrice), open24h: try m.openPrice.map(decimal), eventTime: now)
    }

    /// `GET /api/v3/exchangeInfo`: all pairs that are trading and spot-allowed.
    static func tradableSpotInstruments(exchangeInfo data: Data) throws -> [Instrument] {
        struct Info: Decodable {
            struct Symbol: Decodable { let status: String; let isSpotTradingAllowed: Bool; let baseAsset: String; let quoteAsset: String }
            let symbols: [Symbol]
        }
        return try JSONDecoder().decode(Info.self, from: data).symbols
            .filter { $0.status == "TRADING" && $0.isSpotTradingAllowed }
            .map { Instrument(base: $0.baseAsset, quote: $0.quoteAsset) }
            .sorted { ($0.base, $0.quote) < ($1.base, $1.quote) }
    }

    /// `GET /api/v3/exchangeInfo?symbol=…`: listed, trading and spot-allowed.
    static func isTradableSpot(exchangeInfo data: Data, symbol: String) throws -> Bool {
        struct Info: Decodable {
            struct Symbol: Decodable { let symbol: String; let status: String; let isSpotTradingAllowed: Bool }
            let symbols: [Symbol]
        }
        let info = try JSONDecoder().decode(Info.self, from: data)
        return info.symbols.contains { $0.symbol == symbol && $0.status == "TRADING" && $0.isSpotTradingAllowed }
    }
}

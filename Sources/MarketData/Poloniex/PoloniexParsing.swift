import Domain
import Foundation

/// Poloniex spot (api-docs.poloniex.com/spot): symbols look like `BTC_USDT`.
enum PoloniexParsing {
    static func symbol(_ instrument: Instrument) -> String { "\(instrument.base)_\(instrument.quote)" }

    private static func decimal(_ value: Any?) -> Decimal? {
        switch value {
        case let s as String: return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
        case let n as NSNumber: return Decimal(string: n.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        default: return nil
        }
    }

    private static func millis(_ value: Any?) -> Date? {
        let ms: Double?
        switch value {
        case let s as String: ms = Double(s)
        case let n as NSNumber: ms = n.doubleValue
        default: ms = nil
        }
        return ms.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// `GET /markets` or `GET /markets/{symbol}`: an array (or one object) of markets.
    static func markets(_ data: Data) throws -> [(instrument: Instrument, state: String)] {
        let json = try JSONSerialization.jsonObject(with: data)
        let rows = (json as? [[String: Any]]) ?? (json as? [String: Any]).map { [$0] } ?? []
        return rows.compactMap { row in
            guard let base = row["baseCurrencyName"] as? String, let quote = row["quoteCurrencyName"] as? String,
                  let state = row["state"] as? String else { return nil }
            return (Instrument(base: base, quote: quote), state)
        }
    }

    static func tradableInstruments(_ data: Data) throws -> [Instrument] {
        try markets(data).filter { $0.state == "NORMAL" }.map(\.instrument).sorted { ($0.base, $0.quote) < ($1.base, $1.quote) }
    }

    /// `GET /markets/{symbol}/ticker24h`.
    static func ticker24h(_ data: Data, now: Date) throws -> PriceTick {
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any], let close = decimal(row["close"]) else {
            throw URLError(.cannotParseResponse)
        }
        return PriceTick(price: close, open24h: decimal(row["open"]), eventTime: millis(row["ts"]) ?? now)
    }

    /// One message of the public socket. `ticker` is the update for `symbol`, if the message carries one.
    struct Message {
        var ticker: PriceTick?
        var error: String?
    }

    static func message(_ data: Data, symbol: String) throws -> Message {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Message() }
        if json["event"] as? String == "error" { return Message(error: json["message"] as? String ?? "Poloniex error") }
        guard json["channel"] as? String == "ticker", let rows = json["data"] as? [[String: Any]] else { return Message() }
        for row in rows where row["symbol"] as? String == symbol {
            if let close = decimal(row["close"]) {
                return Message(ticker: PriceTick(price: close, open24h: decimal(row["open"]), eventTime: millis(row["ts"]) ?? Date()))
            }
        }
        return Message()
    }
}

import Domain
import Foundation

/// Bybit v5 spot (bybit-exchange.github.io/docs/v5): symbols look like `BTCUSDT`; REST answers wrap the data in
/// `{"retCode":0,"retMsg":"OK","result":{…},"time":ms}` and report most errors with HTTP 200 and a non-zero `retCode`.
enum BybitParsing {
    static func symbol(_ instrument: Instrument) -> String { instrument.base + instrument.quote }

    static func decimal(_ value: Any?) -> Decimal? {
        switch value {
        case let s as String: return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
        case let n as NSNumber: return Decimal(string: n.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        default: return nil
        }
    }

    static func millis(_ value: Any?) -> Date? {
        let ms: Double?
        switch value {
        case let s as String: ms = Double(s)
        case let n as NSNumber: ms = n.doubleValue
        default: ms = nil
        }
        return ms.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// The `result` object of a REST answer; throws `BybitAPIError` when `retCode` is not 0.
    static func result(_ data: Data, status: Int = 200) throws -> (result: [String: Any], time: Date?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let code = (json["retCode"] as? NSNumber)?.intValue
        guard code == 0 else { throw BybitAPIError(status: status, code: code, message: json["retMsg"] as? String ?? "HTTP \(status)") }
        return (json["result"] as? [String: Any] ?? [:], millis(json["time"]))
    }

    /// `GET /v5/market/instruments-info?category=spot`: the pairs and their status (`Trading`).
    static func instruments(_ data: Data) throws -> (list: [(instrument: Instrument, status: String)], next: String?) {
        let r = try result(data).result
        let rows = r["list"] as? [[String: Any]] ?? []
        let list = rows.compactMap { row -> (Instrument, String)? in
            guard let base = row["baseCoin"] as? String, let quote = row["quoteCoin"] as? String, let status = row["status"] as? String else { return nil }
            return (Instrument(base: base, quote: quote), status)
        }
        return (list, (r["nextPageCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    static func tradableInstruments(_ pages: [Data]) throws -> [Instrument] {
        try pages.flatMap { try instruments($0).list }.filter { $0.status == "Trading" }.map(\.instrument)
            .sorted { ($0.base, $0.quote) < ($1.base, $1.quote) }
    }

    /// `GET /v5/market/tickers?category=spot&symbol=…`.
    static func ticker(_ data: Data, now: Date) throws -> PriceTick {
        let (r, time) = try result(data)
        guard let row = (r["list"] as? [[String: Any]])?.first, let last = decimal(row["lastPrice"]) else { throw URLError(.cannotParseResponse) }
        return PriceTick(price: last, open24h: decimal(row["prevPrice24h"]), eventTime: time ?? now)
    }

    /// One message of the public socket. `ticker` is the update for `symbol`, if the message carries one.
    struct Message {
        var ticker: PriceTick?
        var error: String?
    }

    static func message(_ data: Data, symbol: String) throws -> Message {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Message() }
        if json["success"] as? Bool == false { return Message(error: json["ret_msg"] as? String ?? "Bybit error") }
        guard json["topic"] as? String == "tickers.\(symbol)", let row = json["data"] as? [String: Any], let last = decimal(row["lastPrice"]) else { return Message() }
        return Message(ticker: PriceTick(price: last, open24h: decimal(row["prevPrice24h"]), eventTime: millis(json["ts"]) ?? Date()))
    }
}

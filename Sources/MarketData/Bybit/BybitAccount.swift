import CryptoKit
import Domain
import Foundation

public struct BybitAPIError: Error, Equatable, CustomStringConvertible, Sendable {
    public let status: Int
    public let code: Int?
    public let message: String
    public init(status: Int, code: Int?, message: String) { self.status = status; self.code = code; self.message = message }
    public var description: String { code.map { "\(message) (\($0))" } ?? message }
}

public enum BybitSigner {
    /// HMAC-SHA256, lowercase hex, of `timestamp + apiKey + recvWindow + queryString`: the `X-BAPI-SIGN` header of a GET.
    public static func sign(timestamp: String, key: String, recvWindow: String, query: String, secret: String) -> String {
        let payload = timestamp + key + recvWindow + query
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

/// Signed, read-only requests that need the user's Bybit API key.
public struct BybitAccountAPI: ExchangeAccount {
    public typealias Send = @Sendable (URLRequest) async throws -> (data: Data, status: Int)

    public var id: String { "bybit" }
    /// `/v5/execution/list` answers for a window of at most 7 days; Bybit keeps about two years.
    static let windowMS = 7 * 86_400_000
    static let windows = 104
    static let batch = 8

    private let restBase: URL
    private let send: Send
    private let now: @Sendable () -> Date

    public init(
        restBase: URL = URL(string: "https://api.bybit.com")!,
        now: @escaping @Sendable () -> Date = { Date() },
        send: Send? = nil
    ) {
        self.restBase = restBase
        self.now = now
        self.send = send ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// A signed GET; the query is signed exactly as sent. Returns the `result` object.
    func signedGET(_ path: String, _ credentials: APICredentials, query: String = "") async throws -> [String: Any] {
        let timestamp = String(Int(now().timeIntervalSince1970 * 1000)), recvWindow = "10000"
        guard let url = URL(string: restBase.appending(path: path).absoluteString + (query.isEmpty ? "" : "?" + query)) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(credentials.key, forHTTPHeaderField: "X-BAPI-API-KEY")
        request.setValue(timestamp, forHTTPHeaderField: "X-BAPI-TIMESTAMP")
        request.setValue(recvWindow, forHTTPHeaderField: "X-BAPI-RECV-WINDOW")
        request.setValue(BybitSigner.sign(timestamp: timestamp, key: credentials.key, recvWindow: recvWindow, query: query, secret: credentials.secret), forHTTPHeaderField: "X-BAPI-SIGN")
        let (data, status) = try await send(request)
        guard status == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw BybitAPIError(status: status, code: (json?["retCode"] as? NSNumber)?.intValue, message: json?["retMsg"] as? String ?? "HTTP \(status)")
        }
        return try BybitParsing.result(data, status: status).result
    }

    /// Proves the key and secret work and reports permissions beyond reading (`GET /v5/user/query-api`).
    public func check(_ credentials: APICredentials) async throws -> APIKeyCheck {
        let info = try await signedGET("v5/user/query-api", credentials)
        let permissions = info["permissions"] as? [String: Any] ?? [:]
        var warnings: [String] = []
        if (permissions["Wallet"] as? [String])?.contains("Withdraw") == true { warnings.append("Withdrawals are enabled for this key") }
        if (permissions["Spot"] as? [String])?.contains("SpotTrade") == true || (info["readOnly"] as? NSNumber)?.intValue == 0 { warnings.append("Trading is enabled for this key") }
        let readOnly = warnings.isEmpty
        if !readOnly { warnings.append("TradeStick only reads trade history: create a read-only key") }
        return APIKeyCheck(warnings: warnings, readOnly: readOnly)
    }

    public func trades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade] {
        try await rows(credentials, instrument).map(Self.trade(from:)).sorted { ($0.occurredAt, $0.externalID) < ($1.occurredAt, $1.externalID) }
    }

    public func rawFills(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [RawFill] {
        try await rows(credentials, instrument).map { row in
            guard let id = row["execId"] as? String else { throw URLError(.cannotParseResponse) }
            return RawFill(id: id, json: try rawJSON(row))
        }
    }

    public func parse(_ raw: RawFill) throws -> ImportedTrade { try Self.trade(from: try jsonObject(raw.json)) }

    /// The spot executions of a pair: seven-day windows walked back from now (a batch of them at once), each paged by cursor.
    func rows(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [[String: Any]] {
        let symbol = BybitParsing.symbol(instrument)
        let end = Int(now().timeIntervalSince1970 * 1000)
        var byID: [String: [String: Any]] = [:]
        for first in stride(from: 0, to: Self.windows, by: Self.batch) {
            let pages = try await withThrowingTaskGroup(of: [String].self) { group in // rows travel as JSON text: Sendable
                for w in first..<min(first + Self.batch, Self.windows) {
                    group.addTask { try await window(credentials, symbol, from: end - (w + 1) * Self.windowMS, to: end - w * Self.windowMS) }
                }
                return try await group.reduce(into: []) { $0 += $1 }
            }
            for text in pages { let row = try jsonObject(text); if let id = row["execId"] as? String { byID[id] = row } } // a fill on a window's edge is seen twice
        }
        return Array(byID.values)
    }

    private func window(_ credentials: APICredentials, _ symbol: String, from: Int, to: Int) async throws -> [String] {
        var out: [String] = []
        var cursor = ""
        for _ in 0..<20 {
            let result = try await signedGET("v5/execution/list", credentials, query:
                "category=spot&endTime=\(to)&limit=100&startTime=\(from)&symbol=\(symbol)" + (cursor.isEmpty ? "" : "&cursor=\(cursor)"))
            out += try (result["list"] as? [[String: Any]] ?? []).filter { ($0["execType"] as? String ?? "Trade") == "Trade" }.map(rawJSON)
            cursor = (result["nextPageCursor"] as? String) ?? ""
            if cursor.isEmpty { break }
        }
        return out
    }

    /// Open price of the 1h candle containing `date` (public `GET /v5/market/kline`); nil if there is no such pair or no answer.
    public func feeRate(asset: String, quote: String, at date: Date) async -> Decimal? {
        let ms = Int(date.timeIntervalSince1970 * 1000), start = ms - ms % 3_600_000
        guard let url = URL(string: restBase.appending(path: "v5/market/kline").absoluteString + "?category=spot&symbol=\(asset + quote)&interval=60&start=\(start)&end=\(start + 3_599_999)&limit=1"),
              let (data, status) = try? await send(URLRequest(url: url, timeoutInterval: 15)), status == 200,
              let result = try? BybitParsing.result(data).result, let candle = (result["list"] as? [[Any]])?.first, candle.count > 1
        else { return nil }
        return BybitParsing.decimal(candle[1])
    }

    static func trade(from row: [String: Any]) throws -> ImportedTrade {
        func decimal(_ key: String) throws -> Decimal {
            guard let d = BybitParsing.decimal(row[key]) else { throw URLError(.cannotParseResponse) }
            return d
        }
        guard let id = row["execId"] as? String, let time = BybitParsing.millis(row["execTime"]),
              let side = (row["side"] as? String)?.lowercased(), side == "buy" || side == "sell" else { throw URLError(.cannotParseResponse) }
        var fees: [String: Decimal] = [:]
        // a negative fee is a maker rebate: not counted (a rebate would lower the cost, which the app does not model)
        if let amount = BybitParsing.decimal(row["execFee"]), amount > 0, let currency = row["feeCurrency"] as? String, !currency.isEmpty { fees[currency] = amount }
        return ImportedTrade(
            externalID: id, side: side == "buy" ? .buy : .sell, quantity: try decimal("execQty"), amount: try decimal("execValue"),
            occurredAt: time, orderID: (row["orderId"] as? String).flatMap { $0.isEmpty ? nil : $0 }, fees: fees
        )
    }
}

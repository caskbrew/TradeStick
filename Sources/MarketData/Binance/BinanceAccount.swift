import CryptoKit
import Domain
import Foundation

/// What a key check found. `warnings` lists permissions the app does not need; the key should be read-only.
public struct APIKeyCheck: Equatable, Sendable {
    public var warnings: [String]
    /// True when the key can neither trade nor withdraw; nil when that could not be determined.
    public var readOnly: Bool?
    public init(warnings: [String] = [], readOnly: Bool? = nil) { self.warnings = warnings; self.readOnly = readOnly }
}

public struct BinanceAPIError: Error, Equatable, CustomStringConvertible, Sendable {
    public let status: Int
    public let code: Int?
    public let message: String
    public init(status: Int, code: Int?, message: String) { self.status = status; self.code = code; self.message = message }
    public var description: String { code.map { "\(message) (\($0))" } ?? message }
}

public enum BinanceSigner {
    /// HMAC-SHA256 of the query string, lowercase hex: the `signature` parameter of a signed request.
    public static func sign(_ query: String, secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(query.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

/// Signed, read-only requests that need the user's API key.
public struct BinanceAccountAPI: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (data: Data, status: Int)

    private let restBase: URL
    private let send: Send
    private let now: @Sendable () -> Date

    public init(
        restBase: URL = URL(string: "https://api.binance.com")!,
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

    /// A signed GET. Query items are signed exactly as sent.
    func signedGET(_ path: String, _ credentials: APICredentials, items: [URLQueryItem] = []) async throws -> Data {
        let timestamp = String(Int(now().timeIntervalSince1970 * 1000))
        var query = (items + [.init(name: "recvWindow", value: "10000"), .init(name: "timestamp", value: timestamp)])
            .map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        query += "&signature=" + BinanceSigner.sign(query, secret: credentials.secret)
        guard let url = URL(string: restBase.appending(path: path).absoluteString + "?" + query) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(credentials.key, forHTTPHeaderField: "X-MBX-APIKEY")
        let (data, status) = try await send(request)
        guard status == 200 else { throw Self.error(data, status) }
        return data
    }

    /// Proves the key and secret work (read access to the account) and reports permissions beyond reading.
    public func check(_ credentials: APICredentials) async throws -> APIKeyCheck {
        _ = try await signedGET("api/v3/account", credentials, items: [.init(name: "omitZeroBalances", value: "true")])
        // The permission details are a bonus: a failure here must not fail the check.
        guard let data = try? await signedGET("sapi/v1/account/apiRestrictions", credentials),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return APIKeyCheck() }
        var warnings: [String] = []
        if json["enableWithdrawals"] as? Bool == true { warnings.append("Withdrawals are enabled for this key") }
        if json["enableSpotAndMarginTrading"] as? Bool == true { warnings.append("Trading is enabled for this key") }
        let readOnly = warnings.isEmpty
        if !readOnly { warnings.append("TradeStickies only reads trade history: create a read-only key") }
        return APIKeyCheck(warnings: warnings, readOnly: readOnly)
    }

    /// The user's fills for a pair, oldest first (`GET /api/v3/myTrades`, 1000 per page, up to 20 pages).
    public func myTrades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade] {
        let symbol = BinanceParsing.symbol(instrument)
        var all: [ImportedTrade] = []
        var fromID = 0
        for _ in 0..<20 {
            let data = try await signedGET("api/v3/myTrades", credentials, items: [
                .init(name: "symbol", value: symbol), .init(name: "fromId", value: String(fromID)), .init(name: "limit", value: "1000"),
            ])
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            let page = try rows.map(Self.trade(from:))
            all += page
            guard rows.count == 1000, let last = rows.last?["id"] as? Int else { break }
            fromID = last + 1
        }
        return all.sorted { ($0.occurredAt, $0.externalID) < ($1.occurredAt, $1.externalID) }
    }

    /// Open price of the 1h candle containing `date` (public `GET /api/v3/klines`); nil if there is no such pair or no answer.
    public func hourlyOpen(symbol: String, at date: Date) async -> Decimal? {
        let ms = Int(date.timeIntervalSince1970 * 1000)
        guard let url = URL(string: restBase.appending(path: "api/v3/klines").absoluteString + "?symbol=\(symbol)&interval=1h&startTime=\(ms - ms % 3_600_000)&limit=1"),
              let (data, status) = try? await send(URLRequest(url: url, timeoutInterval: 15)), status == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]], let open = rows.first?.dropFirst().first as? String
        else { return nil }
        return Decimal(string: open, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func trade(from row: [String: Any]) throws -> ImportedTrade {
        func decimal(_ key: String) throws -> Decimal {
            guard let text = row[key] as? String, let d = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { throw URLError(.cannotParseResponse) }
            return d
        }
        guard let id = row["id"] as? Int, let ms = row["time"] as? Double ?? (row["time"] as? Int).map(Double.init), let buyer = row["isBuyer"] as? Bool else {
            throw URLError(.cannotParseResponse)
        }
        var fees: [String: Decimal] = [:]
        if let c = row["commission"] as? String, let amount = Decimal(string: c, locale: Locale(identifier: "en_US_POSIX")), amount > 0,
           let asset = row["commissionAsset"] as? String { fees[asset] = amount }
        return ImportedTrade(
            externalID: String(id), side: buyer ? .buy : .sell, quantity: try decimal("qty"), amount: try decimal("quoteQty"),
            occurredAt: Date(timeIntervalSince1970: ms / 1000), orderID: (row["orderId"] as? Int).map(String.init), fees: fees
        )
    }

    static func error(_ data: Data, _ status: Int) -> BinanceAPIError {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return BinanceAPIError(status: status, code: json?["code"] as? Int, message: json?["msg"] as? String ?? "HTTP \(status)")
    }
}

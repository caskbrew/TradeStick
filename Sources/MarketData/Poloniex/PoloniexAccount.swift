import CryptoKit
import Domain
import Foundation

public struct PoloniexAPIError: Error, Equatable, CustomStringConvertible, Sendable {
    public let status: Int
    public let code: Int?
    public let message: String
    public var description: String { code.map { "\(message) (\($0))" } ?? message }
}

public enum PoloniexSigner {
    /// Base64 of the HMAC-SHA256 of `METHOD\n/path\nsorted&params` (parameters include `signTimestamp`): the `signature` header.
    public static func sign(method: String, path: String, params: [(String, String)], secret: String) -> String {
        let query = params.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let payload = "\(method)\n\(path)\n\(query)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return Data(mac).base64EncodedString()
    }
}

/// Signed, read-only requests that need the user's Poloniex API key.
public struct PoloniexAccountAPI: ExchangeAccount {
    public typealias Send = @Sendable (URLRequest) async throws -> (data: Data, status: Int)

    public var id: String { "poloniex" }
    /// Poloniex serves trade history for the last 180 days only.
    static let historyDays = 179

    private let restBase: URL
    private let send: Send
    private let now: @Sendable () -> Date

    public init(
        restBase: URL = URL(string: "https://api.poloniex.com")!,
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

    func signedGET(_ path: String, _ credentials: APICredentials, items: [(String, String)] = []) async throws -> Data {
        let timestamp = String(Int(now().timeIntervalSince1970 * 1000))
        let signature = PoloniexSigner.sign(method: "GET", path: "/" + path, params: items + [("signTimestamp", timestamp)], secret: credentials.secret)
        var components = URLComponents(url: restBase.appending(path: path), resolvingAgainstBaseURL: false)
        if !items.isEmpty { components?.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(credentials.key, forHTTPHeaderField: "key")
        request.setValue(signature, forHTTPHeaderField: "signature")
        request.setValue(timestamp, forHTTPHeaderField: "signTimestamp")
        request.setValue("hmacSHA256", forHTTPHeaderField: "signatureMethod")
        request.setValue("2", forHTTPHeaderField: "signatureVersion")
        let (data, status) = try await send(request)
        guard status == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw PoloniexAPIError(status: status, code: json?["code"] as? Int, message: json?["message"] as? String ?? "HTTP \(status)")
        }
        return data
    }

    /// Proves the key and secret work. Poloniex does not report a key's permissions, so `readOnly` stays unknown.
    public func check(_ credentials: APICredentials) async throws -> APIKeyCheck {
        _ = try await signedGET("accounts", credentials)
        return APIKeyCheck()
    }

    /// The user's fills for a pair, oldest first (`GET /trades`, 1000 per page, walking back from now, up to 20 pages).
    public func trades(_ credentials: APICredentials, _ instrument: Instrument) async throws -> [ImportedTrade] {
        let symbol = PoloniexParsing.symbol(instrument)
        let start = Int(now().timeIntervalSince1970 * 1000) - Self.historyDays * 86_400_000
        var end = Int(now().timeIntervalSince1970 * 1000)
        var byID: [String: ImportedTrade] = [:]
        for _ in 0..<20 {
            let data = try await signedGET("trades", credentials, items: [
                ("endTime", String(end)), ("limit", "1000"), ("startTime", String(start)), ("symbols", symbol),
            ])
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            for row in rows { let t = try Self.trade(from: row); byID[t.externalID] = t }
            let oldest = rows.compactMap { ($0["createTime"] as? NSNumber)?.intValue }.min()
            guard rows.count >= 1000, let oldest, oldest < end else { break }
            end = oldest // the next page: everything up to the oldest fill seen (known fills are deduplicated by id)
        }
        return byID.values.sorted { ($0.occurredAt, $0.externalID) < ($1.occurredAt, $1.externalID) }
    }

    static func trade(from row: [String: Any]) throws -> ImportedTrade {
        func decimal(_ key: String) throws -> Decimal {
            guard let text = row[key] as? String, let d = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { throw URLError(.cannotParseResponse) }
            return d
        }
        guard let id = row["id"] as? String, let ms = (row["createTime"] as? NSNumber)?.doubleValue,
              let side = (row["side"] as? String)?.uppercased(), side == "BUY" || side == "SELL" else { throw URLError(.cannotParseResponse) }
        var fees: [String: Decimal] = [:]
        if let c = row["feeAmount"] as? String, let amount = Decimal(string: c, locale: Locale(identifier: "en_US_POSIX")), amount > 0,
           let currency = row["feeCurrency"] as? String { fees[currency] = amount }
        return ImportedTrade(
            externalID: id, side: side == "BUY" ? .buy : .sell, quantity: try decimal("quantity"), amount: try decimal("amount"),
            occurredAt: Date(timeIntervalSince1970: ms / 1000), orderID: row["orderId"] as? String, fees: fees
        )
    }
}

import CryptoKit
import Domain
import Foundation

/// What a key check found. `warnings` lists permissions the app does not need; the key should be read-only.
public struct APIKeyCheck: Equatable, Sendable {
    public var warnings: [String]
    public init(warnings: [String] = []) { self.warnings = warnings }
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
        if !warnings.isEmpty { warnings.append("TradeStickies only reads trade history: create a read-only key") }
        return APIKeyCheck(warnings: warnings)
    }

    static func error(_ data: Data, _ status: Int) -> BinanceAPIError {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return BinanceAPIError(status: status, code: json?["code"] as? Int, message: json?["msg"] as? String ?? "HTTP \(status)")
    }
}

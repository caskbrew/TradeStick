import Domain
import MarketData
import Observation
import Persistence

/// Logic of the "Exchange API Keys" window. The secret is never shown again once saved.
@MainActor @Observable
public final class APIKeysModel {
    public enum Status: Equatable {
        case idle
        case working(String)
        case ok(String, warnings: [String])
        case failed(String)
    }

    public let exchange = "binance"
    public var keyText: String
    public var secretText = ""
    public private(set) var status: Status = .idle
    public private(set) var hasSavedKey: Bool

    @ObservationIgnored private let store: any CredentialStore
    @ObservationIgnored private let check: @Sendable (APICredentials) async throws -> APIKeyCheck

    public init(store: any CredentialStore, check: @escaping @Sendable (APICredentials) async throws -> APIKeyCheck) {
        self.store = store
        self.check = check
        let saved = store.load(exchange: "binance")
        keyText = saved?.key ?? ""
        hasSavedKey = saved != nil
    }

    /// Typed values; an empty secret field means "keep the saved secret" when the key is unchanged.
    private var credentials: APICredentials? {
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secretText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if !secret.isEmpty { return APICredentials(key: key, secret: secret) }
        if let saved = store.load(exchange: exchange), saved.key == key { return saved }
        return nil
    }

    public var canSubmit: Bool { credentials != nil }

    public func test() async {
        guard let credentials else { status = .failed("Enter the API key and the secret"); return }
        status = .working("Checking…")
        do {
            let result = try await check(credentials)
            status = .ok("Key works", warnings: result.warnings)
        } catch {
            status = .failed("\(error)")
        }
    }

    /// Saves only a key that passes the check, so a typo is caught here and not during an import.
    public func save() async {
        guard let credentials else { status = .failed("Enter the API key and the secret"); return }
        status = .working("Checking…")
        do {
            let result = try await check(credentials)
            try store.save(credentials, exchange: exchange)
            hasSavedKey = true
            secretText = ""
            status = .ok("Saved", warnings: result.warnings)
        } catch {
            status = .failed("Not saved: \(error)")
        }
    }

    public func remove() {
        do {
            try store.remove(exchange: exchange)
            hasSavedKey = false
            keyText = ""; secretText = ""
            status = .ok("Removed", warnings: [])
        } catch {
            status = .failed("\(error)")
        }
    }
}

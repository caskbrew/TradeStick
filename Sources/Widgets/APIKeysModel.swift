import Domain
import Foundation
import MarketData
import Observation
import Persistence

/// Logic of the "API Keys" window. The secret is never shown again once saved.
@MainActor @Observable
public final class APIKeysModel {
    public enum Status: Equatable {
        case idle
        case working(String)
        case ok(String)
        case failed(String)
    }

    public let exchange: String
    public var keyText: String
    public var secretText = ""
    public private(set) var status: Status = .idle
    public private(set) var hasSavedKey: Bool
    /// The last check passed.
    public private(set) var connected: Bool
    public private(set) var lastChecked: Date?
    /// Nil until a check could tell.
    public private(set) var readOnly: Bool?
    public private(set) var warnings: [String] = []

    @ObservationIgnored private let store: any CredentialStore
    @ObservationIgnored private let check: @Sendable (APICredentials) async throws -> APIKeyCheck
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: () -> Date

    private var checkedKey: String { "apiKeyChecked.\(exchange)" }
    private var readOnlyKey: String { "apiKeyReadOnly.\(exchange)" }

    public init(
        exchange: String = "binance",
        store: any CredentialStore,
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = { Date() },
        check: @escaping @Sendable (APICredentials) async throws -> APIKeyCheck
    ) {
        self.exchange = exchange
        self.store = store
        self.check = check
        self.defaults = defaults
        self.clock = clock
        var loadError: String?
        let saved: APICredentials?
        do { saved = try store.load(exchange: exchange) } catch { saved = nil; loadError = "\(error)" }
        if loadError != nil { status = .failed("Keychain refused access to the saved key. Enter it again and press Save.") }
        keyText = saved?.key ?? ""
        hasSavedKey = saved != nil
        let when = saved == nil ? nil : defaults.object(forKey: "apiKeyChecked.\(exchange)") as? Date
        lastChecked = when
        connected = when != nil
        readOnly = when == nil ? nil : defaults.object(forKey: "apiKeyReadOnly.\(exchange)") as? Bool
    }

    /// Typed values; an empty secret field means "keep the saved secret" when the key is unchanged.
    private var credentials: APICredentials? {
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secretText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if !secret.isEmpty { return APICredentials(key: key, secret: secret) }
        if let saved = (try? store.load(exchange: exchange)) ?? nil, saved.key == key { return saved }
        return nil
    }

    public var canSubmit: Bool { credentials != nil }

    private func record(_ result: APIKeyCheck, saved: Bool) {
        connected = true
        lastChecked = clock()
        readOnly = result.readOnly
        warnings = result.warnings
        if saved {
            defaults.set(lastChecked, forKey: checkedKey)
            if let readOnly { defaults.set(readOnly, forKey: readOnlyKey) } else { defaults.removeObject(forKey: readOnlyKey) }
        }
    }

    public func test() async {
        guard let credentials else { status = .failed("Enter the API key and the secret"); return }
        status = .working("Checking…")
        do {
            let result = try await check(credentials)
            record(result, saved: ((try? store.load(exchange: exchange)) ?? nil) == credentials)
            status = .ok("Key works")
        } catch {
            connected = false
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
            record(result, saved: true)
            status = .ok("Saved")
        } catch {
            connected = false
            status = .failed("Not saved: \(error)")
        }
    }

    public func remove() {
        do {
            try store.remove(exchange: exchange)
            hasSavedKey = false
            connected = false; lastChecked = nil; readOnly = nil; warnings = []
            defaults.removeObject(forKey: checkedKey); defaults.removeObject(forKey: readOnlyKey)
            keyText = ""; secretText = ""
            status = .ok("Removed")
        } catch {
            status = .failed("\(error)")
        }
    }
}

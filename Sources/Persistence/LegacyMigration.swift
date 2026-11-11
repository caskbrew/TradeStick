import Domain
import Foundation

/// One-time move from the pre-rename names ("TradeStickies") to "TradeStick". Never deletes anything it copied.
public enum LegacyMigration {
    /// Moves `<base>/<old>` to `<base>/<new>` and renames the database files inside. No-op unless only the old folder exists.
    @discardableResult
    public static func moveDataFolder(in base: URL, from old: String, to new: String) throws -> Bool {
        let fm = FileManager.default
        let src = base.appendingPathComponent(old, isDirectory: true), dst = base.appendingPathComponent(new, isDirectory: true)
        guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { return false }
        // Rename the database files inside the old folder first (the WAL with them), then move the folder: a failure in between
        // leaves the old folder whole, and the next launch simply tries again.
        for suffix in ["", "-wal", "-shm"] {
            let from = src.appendingPathComponent("tradestickies.sqlite" + suffix), to = src.appendingPathComponent("tradestick.sqlite" + suffix)
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) { try fm.moveItem(at: from, to: to) }
        }
        try fm.moveItem(at: src, to: dst)
        return true
    }

    /// Moves the keys stored under the old Keychain service to the new one. An old item is removed only after the
    /// new one reads back identical, so a failed or refused copy never loses a key.
    /// Returns the exchanges whose old key could not be moved because the Keychain refused (the user pressed Deny).
    @discardableResult
    public static func moveKeys(from old: CredentialStore, to new: CredentialStore, exchanges: [String]) -> [String] {
        var refused: [String] = []
        for exchange in exchanges {
            let found: APICredentials?
            do { found = try old.load(exchange: exchange) } catch {
                if ((try? new.load(exchange: exchange)) ?? nil) == nil { refused.append(exchange) } // nothing to fall back on
                continue
            }
            guard let keys = found else { continue }
            let hadKey = ((try? new.load(exchange: exchange)) ?? nil) != nil // a newer key of the user's own wins and stays
            if !hadKey { try? new.save(keys, exchange: exchange) }
            if let stored = (try? new.load(exchange: exchange)) ?? nil, stored == keys { try? old.remove(exchange: exchange) } else if !hadKey { refused.append(exchange) }
        }
        return refused
    }

    /// UserDefaults are stored per bundle id: after the id changed, bring the old values over (never overwriting a value already set).
    /// Only the app's own keys; `prefixes` match by start of the key.
    public static func copyDefaults(fromDomain old: String, prefixes: [String] = ["pinned.", "compact.", "stickerScale", "instruments.", "apiKeyChecked.", "apiKeyReadOnly."], to defaults: UserDefaults = .standard) {
        guard let values = defaults.persistentDomain(forName: old) else { return }
        for (key, value) in values where prefixes.contains(where: key.hasPrefix) && defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
    }
}

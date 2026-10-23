import Foundation

/// One-time move from the pre-rename names ("TradeStickies") to "TradeStick". Never deletes anything it copied.
public enum LegacyMigration {
    /// Moves `<base>/<old>` to `<base>/<new>` and renames the database files inside. No-op unless only the old folder exists.
    @discardableResult
    public static func moveDataFolder(in base: URL, from old: String, to new: String) throws -> Bool {
        let fm = FileManager.default
        let src = base.appendingPathComponent(old, isDirectory: true), dst = base.appendingPathComponent(new, isDirectory: true)
        guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { return false }
        try fm.moveItem(at: src, to: dst)
        for suffix in ["", "-wal", "-shm"] {
            let from = dst.appendingPathComponent("tradestickies.sqlite" + suffix), to = dst.appendingPathComponent("tradestick.sqlite" + suffix)
            if fm.fileExists(atPath: from.path) { try fm.moveItem(at: from, to: to) }
        }
        return true
    }

    /// Moves the keys stored under the old Keychain service to the new one. An old item is removed only after the
    /// new one reads back identical, so a failed or refused copy never loses a key.
    public static func moveKeys(from old: CredentialStore, to new: CredentialStore, exchanges: [String]) {
        for exchange in exchanges {
            guard let keys = (try? old.load(exchange: exchange)) ?? nil else { continue }
            if ((try? new.load(exchange: exchange)) ?? nil) == nil { try? new.save(keys, exchange: exchange) }
            if let stored = (try? new.load(exchange: exchange)) ?? nil, stored == keys { try? old.remove(exchange: exchange) }
        }
    }

    /// UserDefaults are stored per bundle id: after the id changed, bring the old values over (never overwriting a value already set).
    public static func copyDefaults(fromDomain old: String, to defaults: UserDefaults = .standard) {
        guard let values = defaults.persistentDomain(forName: old) else { return }
        for (key, value) in values where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
    }
}

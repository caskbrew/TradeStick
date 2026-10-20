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

    /// Copies the keys stored under the old Keychain service to the new one (the old items stay, so a rollback still works).
    public static func copyKeys(from old: CredentialStore, to new: CredentialStore, exchanges: [String]) {
        for exchange in exchanges {
            guard (try? new.load(exchange: exchange)) ?? nil == nil, let keys = (try? old.load(exchange: exchange)) ?? nil else { continue }
            try? new.save(keys, exchange: exchange)
        }
    }
}

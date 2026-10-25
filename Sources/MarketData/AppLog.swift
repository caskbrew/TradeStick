import Foundation
import os

/// A plain text log for connection problems, so a bad evening can be explained afterwards. Never grows past
/// `2 * limit`: when `app.log` reaches `limit` it becomes `app.log.1` (replacing the older one) and a new file starts.
/// Does nothing until `start(directory:)` is called, so tests and previews leave no files.
public enum AppLog {
    private struct State { var file: URL?; var limit = 8 * 1024 * 1024 }
    /// 2026-10-26T00:06:16+02:00: local time with its offset, so logs from other Macs line up.
    private static let stamp = Date.ISO8601FormatStyle(timeZone: .current).timeZoneSeparator(.colon)
    private static let state = OSAllocatedUnfairLock(initialState: State())

    public static func start(directory: URL, limit: Int = 8 * 1024 * 1024) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        state.withLock { $0 = State(file: directory.appending(path: "app.log"), limit: limit) }
    }

    public static func stop() { state.withLock { $0.file = nil } }

    public static func write(_ message: String) {
        state.withLock { s in
            guard let file = s.file else { return }
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size >= s.limit {
                let old = file.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            let line = Data("\(Date().formatted(stamp)) \(message)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: file)
            }
        }
    }

    /// "URLError -1001 (The request timed out.)" rather than the whole NSError dump.
    public static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code) (\(e.localizedDescription))"
    }
}

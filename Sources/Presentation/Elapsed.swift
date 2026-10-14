import Foundation

/// Compact elapsed-time text: "<1m", "42m", "5h", "5h 12m", "3d 4h".
public enum Elapsed {
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        switch minutes {
        case 0: return "<1m"
        case 1..<60: return "\(minutes)m"
        case 60..<1440: return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
        default: return minutes % 1440 < 60 ? "\(minutes / 1440)d" : "\(minutes / 1440)d \(minutes % 1440 / 60)h"
        }
    }

    public static func ago(from date: Date, to now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : duration(now.timeIntervalSince(date)) + " ago"
    }
}

import Domain
import Observation

/// Logic of the "Import from trade history" window: load fills, pick some, add them.
@MainActor @Observable
public final class ImportModel {
    public enum State: Equatable {
        case loading
        case failed(String)
        case loaded
    }

    public struct Row: Identifiable, Equatable {
        public let trade: ImportedTrade
        public let alreadyAdded: Bool
        public var id: String { trade.externalID }
    }

    public let title: String
    public private(set) var state: State = .loading
    public private(set) var rows: [Row] = []
    public private(set) var selection: Set<String> = []
    public private(set) var error: String?
    public private(set) var added: Int?

    @ObservationIgnored private let fetch: @Sendable () async throws -> [ImportedTrade]
    @ObservationIgnored private let existing: () -> Set<String>
    @ObservationIgnored private let commit: ([ImportedTrade]) -> String?

    /// - Parameters:
    ///   - existing: exchange trade ids this trade already has.
    ///   - commit: adds the trades; returns nil on success or a message.
    public init(
        title: String,
        fetch: @escaping @Sendable () async throws -> [ImportedTrade],
        existing: @escaping () -> Set<String>,
        commit: @escaping ([ImportedTrade]) -> String?
    ) {
        self.title = title
        self.fetch = fetch
        self.existing = existing
        self.commit = commit
    }

    public func load() async {
        state = .loading
        error = nil
        do {
            let known = existing()
            // Newest first: recent fills are the ones people import.
            rows = try await fetch().reversed().map { Row(trade: $0, alreadyAdded: known.contains($0.externalID)) }
            selection = []
            state = .loaded
        } catch {
            state = .failed("\(error)")
        }
    }

    public var selectableCount: Int { rows.filter { !$0.alreadyAdded }.count }
    public var canAdd: Bool { !selection.isEmpty }

    public func toggle(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }), !row.alreadyAdded else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    public func selectAll() { selection = Set(rows.filter { !$0.alreadyAdded }.map(\.id)) }
    public func selectNone() { selection = [] }

    /// Adds the selected fills. Returns true when done (the window can close).
    public func add() -> Bool {
        let chosen = rows.filter { selection.contains($0.id) }.map(\.trade)
        guard !chosen.isEmpty else { return false }
        if let message = commit(chosen) {
            error = message
            return false
        }
        added = chosen.count
        return true
    }
}

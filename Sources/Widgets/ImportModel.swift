import Domain
import Observation
import Presentation

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
        /// Imported before: as this row, or (grouped) as all of its fills.
        public let alreadyAdded: Bool
        /// Grouped order whose fills were imported only in part: not offered again, to avoid double counting.
        public let partlyAdded: Bool
        public var id: String { trade.externalID }
        public var selectable: Bool { !alreadyAdded && !partlyAdded }
    }

    public let title: String
    /// Show amounts with exactly 2 decimals (USDT and alike).
    public let fixedQuote: Bool
    public private(set) var state: State = .loading
    public private(set) var rows: [Row] = []
    /// One row per order (like the exchange's web history) instead of one per fill.
    public private(set) var grouped = true
    public private(set) var selection: Set<String> = []
    public private(set) var error: String?
    public private(set) var added: Int?

    @ObservationIgnored private let fetch: @Sendable () async throws -> [ImportedTrade]
    @ObservationIgnored private let existing: () -> Set<String>
    @ObservationIgnored private var fills: [ImportedTrade] = []
    @ObservationIgnored private var known: Set<String> = []
    @ObservationIgnored private let commit: ([ImportedTrade]) -> String?

    /// - Parameters:
    ///   - existing: exchange trade ids this trade already has.
    ///   - commit: adds the trades; returns nil on success or a message.
    public init(
        title: String,
        quote: String = "",
        fetch: @escaping @Sendable () async throws -> [ImportedTrade],
        existing: @escaping () -> Set<String>,
        commit: @escaping ([ImportedTrade]) -> String?
    ) {
        self.title = title
        self.fixedQuote = NumberFormat.isTwoDecimalCurrency(quote)
        self.fetch = fetch
        self.existing = existing
        self.commit = commit
    }

    public func load() async {
        state = .loading
        error = nil
        do {
            known = existing()
            fills = try await fetch()
            rebuild()
            state = .loaded
        } catch {
            state = .failed("\(error)")
        }
    }

    public func setGrouped(_ value: Bool) {
        guard value != grouped else { return }
        grouped = value
        rebuild()
    }

    /// Newest first: recent fills are the ones people import.
    private func rebuild() {
        let items = grouped ? ImportedTrade.groupedByOrder(fills) : fills
        rows = items.reversed().map { trade in
            let ids = Set(trade.fillIDs)
            let direct = known.contains(trade.externalID) || (trade.orderID.map { known.contains("o" + $0) } ?? false)
            let fillsKnown = ids.intersection(known)
            let all = direct || (!fillsKnown.isEmpty && fillsKnown == ids)
            return Row(trade: trade, alreadyAdded: all, partlyAdded: !all && !fillsKnown.isEmpty)
        }
        selection = []
    }

    public var selectableCount: Int { rows.filter(\.selectable).count }
    public var canAdd: Bool { !selection.isEmpty }

    public func toggle(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }), row.selectable else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    public func selectAll() { selection = Set(rows.filter(\.selectable).map(\.id)) }
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

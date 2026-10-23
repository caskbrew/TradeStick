import Foundation
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

    public enum Filter: String, CaseIterable, Sendable { case all = "All trades", newOnly = "New only" }

    public let title: String
    /// "GRAM / USDT".
    public let pair: String
    public var filter: Filter = .all
    /// Time column order: newest first by default.
    public var newestFirst = true
    /// Show amounts with exactly 2 decimals (USDT and alike).
    public let fixedQuote: Bool
    public private(set) var state: State = .loading
    public private(set) var rows: [Row] = []
    /// One row per order (like the exchange's web history) instead of one per fill.
    public private(set) var grouped = true
    public private(set) var selection: Set<String> = []
    public private(set) var error: String?
    public private(set) var added: Int?
    public private(set) var hasLoaded = false
    /// The saved trades are shown while the exchange is still asked: a spinner tells the user so.
    public private(set) var refreshing = false
    /// Set when the exchange could not be reached but saved trades are shown.
    public private(set) var offline: String?
    public private(set) var offlineDetail = ""
    /// How many imported transactions the last recalculation changed.
    public private(set) var recalculated: Int?

    @ObservationIgnored private let fetch: @Sendable () async throws -> [ImportedTrade]
    @ObservationIgnored private let existing: () -> Set<String>
    @ObservationIgnored private var fills: [ImportedTrade] = []
    @ObservationIgnored private var known: Set<String> = []
    @ObservationIgnored private let commit: ([ImportedTrade]) -> String?
    @ObservationIgnored private let saved: (() async throws -> [ImportedTrade])?
    @ObservationIgnored private let recalculate: (([ImportedTrade]) -> (changed: Int, error: String?))?

    /// - Parameters:
    ///   - existing: exchange trade ids this trade already has.
    ///   - commit: adds the trades; returns nil on success or a message.
    public init(
        title: String,
        pair: String = "",
        quote: String = "",
        fetch: @escaping @Sendable () async throws -> [ImportedTrade],
        existing: @escaping () -> Set<String>,
        commit: @escaping ([ImportedTrade]) -> String?,
        saved: (() async throws -> [ImportedTrade])? = nil,
        recalculate: (([ImportedTrade]) -> (changed: Int, error: String?))? = nil
    ) {
        self.saved = saved
        self.recalculate = recalculate
        self.title = title
        self.pair = pair
        self.fixedQuote = NumberFormat.isTwoDecimalCurrency(quote)
        self.fetch = fetch
        self.existing = existing
        self.commit = commit
    }

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Starts loading once. The load is the model's own task, not the view's: a view that is re-created or briefly
    /// removed (which cancels its `.task`) must not turn the pending request into an error.
    public func startLoading() {
        guard loadTask == nil, !hasLoaded else { return }
        loadTask = Task { await load(); loadTask = nil }
    }

    public func retry() {
        loadTask = nil
        startLoading()
    }

    public func load() async {
        state = .loading
        error = nil
        offline = nil
        known = existing()
        if let saved, let local = try? await saved(), !local.isEmpty { // what was kept from earlier, shown at once
            fills = local
            rebuild()
            state = .loaded
            refreshing = true
        }
        defer { refreshing = false }
        do {
            fills = try await fetch()
            rebuild()
            state = .loaded
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            if state == .loaded { offline = "No connection to the exchange · showing saved trades"; offlineDetail = "\(error)" } else { state = .failed("\(error)") }
        }
    }

    public var canRecalculate: Bool { recalculate != nil && state == .loaded }

    /// Recalculates the imported transactions from the saved fills (fee rules may have changed); hand-edited ones stay.
    public func recalculateImported() {
        guard let recalculate else { return }
        let result = recalculate(ImportedTrade.groupedByOrder(fills) + fills)
        if let message = result.error { error = message } else { error = nil; recalculated = result.changed }
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
        selection.formIntersection(rows.filter(\.selectable).map(\.id)) // a refresh keeps what the user already ticked
    }

    /// Rows as shown: filtered, then in the chosen time order.
    public var visibleRows: [Row] {
        let shown = filter == .newOnly ? rows.filter(\.selectable) : rows
        return newestFirst ? shown : shown.reversed()
    }

    public var selectableCount: Int { visibleRows.filter(\.selectable).count }
    /// Sum of the selected rows' amounts including fees, in the quote currency.
    public var selectedAmount: Decimal { rows.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.trade.netAmount } } // with fees, as it will be added
    public var allSelected: Bool { selectableCount > 0 && visibleRows.filter(\.selectable).allSatisfy { selection.contains($0.id) } }

    public func toggleAll() { if allSelected { selection.subtract(visibleRows.map(\.id)) } else { selectAll() } }
    public var canAdd: Bool { !selection.isEmpty }

    public func toggle(_ id: String) {
        guard let row = rows.first(where: { $0.id == id }), row.selectable else { return }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    public func selectAll() { selection.formUnion(visibleRows.filter(\.selectable).map(\.id)) }

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

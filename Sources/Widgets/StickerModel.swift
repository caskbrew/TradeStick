import Domain
import Foundation
import MarketData
import Observation
import Persistence
import Presentation

/// State and actions of one sticker. Pure logic: no AppKit, testable with a fake exchange and an in-memory store.
@MainActor @Observable
public final class StickerModel {
    public private(set) var trade: StoredTrade
    public private(set) var transactions: [Transaction] = []
    public private(set) var summary: TradeSummary
    public private(set) var price = PriceState()
    public private(set) var formError: String?
    public private(set) var listError: String?
    public private(set) var loadError: String?
    public var form: TransactionDraft?

    /// Height of one transaction row; shared with the view so the window can reserve room before a list opens.
    public static let listRowHeight: CGFloat = 30
    static let formExtraHeight: CGFloat = 200
    /// Called synchronously before a change that makes the card taller, with a generous upper bound of the extra
    /// height. The window grows first (it is transparent) and the card then animates inside it.
    @ObservationIgnored public var onWillGrow: ((CGFloat) -> Void)?

    @ObservationIgnored private let store: TradeStore
    @ObservationIgnored private let hub: MarketDataHub
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let throttle: Duration
    @ObservationIgnored private var subscription: PriceSubscription?
    @ObservationIgnored private var priceTask: Task<Void, Never>?

    /// `throttle` limits how often the UI is updated, not how fast data is received (FR-PRICE-7).
    public init(
        trade: StoredTrade, store: TradeStore, hub: MarketDataHub,
        throttle: Duration = .milliseconds(250), clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.trade = trade
        self.store = store
        self.hub = hub
        self.throttle = throttle
        self.clock = clock
        self.summary = .empty(trade.direction)
        reload()
    }

    // MARK: Derived values

    public var currentPrice: Decimal? { price.tick?.price }
    public var pnl: PnL { summary.pnl(at: currentPrice) }
    public var status: TradeStatus { summary.status }
    public var key: MarketDataHub.Key { .init(exchange: trade.exchange, instrument: Instrument(base: trade.base, quote: trade.quote)) }

    /// Subscribed only while the window is visible and the trade is EMPTY or OPEN (spec 8.3).
    public var wantsPrice: Bool { trade.isVisible && summary.status != .closed }

    // MARK: Loading

    public func reload() {
        do {
            transactions = try store.transactions(tradeID: trade.id)
            summary = try TradeCalculator.summarize(direction: trade.direction, transactions: transactions)
            loadError = nil
        } catch {
            loadError = "Could not read this trade: \(error)"
        }
    }

    // MARK: Price subscription

    /// Call after anything that can change `wantsPrice`.
    public func refreshSubscription() async {
        if wantsPrice {
            guard subscription == nil, let sub = try? await hub.subscribe(key) else { return }
            subscription = sub
            let throttle = self.throttle
            priceTask = Task { [weak self] in
                for await state in sub.states {
                    guard let self else { return }
                    self.price = state
                    try? await Task.sleep(for: throttle) // newest value wins while we wait
                }
            }
        } else if let sub = subscription {
            subscription = nil
            priceTask?.cancel()
            priceTask = nil
            await hub.unsubscribe(sub)
        }
    }

    // MARK: Window state

    public func setVisible(_ visible: Bool) async {
        try? store.setVisible(id: trade.id, visible)
        trade.isVisible = visible
        await refreshSubscription()
    }

    public func setExpanded(_ expanded: Bool) {
        if expanded && !trade.isExpanded {
            onWillGrow?(CGFloat(min(transactions.count, 8)) * Self.listRowHeight + 40)
        }
        try? store.setExpanded(id: trade.id, expanded)
        trade.isExpanded = expanded
    }

    // MARK: Form

    /// Opens an empty form for a side (`Buy more`, `Sell part`, …). Orders are never sent (FR-TX-1a).
    public func openForm(side: Side) {
        if form == nil { onWillGrow?(Self.formExtraHeight) }
        form = TransactionDraft(side: side, occurredAt: clock())
        formError = nil
    }

    /// `Close`: the closing side, the whole open quantity, the current price when known.
    public func openCloseForm() {
        guard summary.openQuantity > 0 else { return }
        if form == nil { onWillGrow?(Self.formExtraHeight) }
        let side = trade.direction.closingSide
        if let rate = currentPrice {
            form = TransactionDraft(side: side, occurredAt: clock(), quantity: summary.openQuantity, rate: rate)
        } else {
            var draft = TransactionDraft(side: side, occurredAt: clock())
            draft.edit(.quantity, "\(summary.openQuantity)")
            form = draft
        }
        formError = nil
    }

    public func cancelForm() {
        form = nil
        formError = nil
    }

    public func edit(_ field: TransactionDraft.Field, _ text: String) {
        form?.edit(field, text)
        formError = nil
    }

    public var formProblems: [TransactionDraft.Problem] { form?.problems(now: clock()) ?? [] }
    public var canSave: Bool { form?.savable(now: clock()) != nil }

    public func submit() async {
        guard let form, let value = form.savable(now: clock()) else { return }
        do {
            try store.addTransaction(
                tradeID: trade.id, side: form.side, quantity: value.quantity, amount: value.amount, occurredAt: form.occurredAt
            )
            self.form = nil
            formError = nil
            reload()
            await refreshSubscription()
        } catch StoreError.ledger(let error) {
            formError = Self.message(for: error, transactions: transactions)
        } catch {
            formError = "Could not save: \(error)"
        }
    }

    public func deleteTransaction(id: UUID) async {
        do {
            try store.deleteTransaction(tradeID: trade.id, id: id)
            listError = nil
            reload()
            await refreshSubscription()
        } catch StoreError.ledger(let error) {
            listError = Self.message(for: error, transactions: transactions)
        } catch {
            listError = "Could not delete: \(error)"
        }
    }

    // MARK: Messages

    /// Names the transaction that breaks the rule (FR-TX-4).
    static func message(for error: LedgerError, transactions: [Transaction]) -> String {
        switch error {
        case .nonPositiveValue:
            return "Quantity and amount must be greater than 0"
        case .closingExceedsOpen(let id, let available):
            let when = transactions.first { $0.id == id }.map { " at " + Self.time($0.occurredAt) } ?? ""
            return "Not enough open quantity\(when): only \(NumberFormat.quantity(available)) available"
        }
    }

    private static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}

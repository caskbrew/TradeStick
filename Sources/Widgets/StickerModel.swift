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
    /// Set while the form edits an existing transaction instead of adding one.
    public private(set) var editingID: UUID?

    /// Height of one transaction row; shared with the view so the window can reserve room before a list opens.
    public static let listRowHeight: CGFloat = 30
    /// Called synchronously before a change that makes the card taller, with a generous upper bound of the extra
    /// height. The window grows first (it is transparent) and the card then animates inside it.
    @ObservationIgnored public var onWillGrow: ((CGFloat) -> Void)?
    /// The card reports its laid-out height here; the window follows it.
    @ObservationIgnored public var onContentSize: ((CGSize) -> Void)?
    /// The add/edit form slides out beside the card, normally to the right. The window sets this to true
    /// (before the form opens) when there is no room on the right.
    public var formOnLeft = false
    /// Called before the form opens so the window can pick a side and make room.
    @ObservationIgnored public var onFormWillOpen: (() -> Void)?
    /// Called when the form was dismissed (cancelled or saved); the window hides its panel after the slide-out.
    @ObservationIgnored public var onFormClosed: (() -> Void)?
    /// The form reports its laid-out height so its window can fit it.
    @ObservationIgnored public var onFormHeight: ((CGFloat) -> Void)?

    @ObservationIgnored private let icons: CoinIcons?
    /// PNG of the base coin's logo once it is known; the header shows a monogram until then.
    public private(set) var iconData: Data?

    public func loadIcon() async {
        if iconData == nil { iconData = await icons?.data(for: trade.base) }
    }

    @ObservationIgnored private let store: TradeStore
    @ObservationIgnored private let hub: MarketDataHub
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let throttle: Duration
    @ObservationIgnored private var subscription: PriceSubscription?
    @ObservationIgnored private var priceTask: Task<Void, Never>?

    /// `throttle` limits how often the UI is updated, not how fast data is received (FR-PRICE-7).
    public init(
        trade: StoredTrade, store: TradeStore, hub: MarketDataHub,
        throttle: Duration = .milliseconds(250), clock: @escaping @Sendable () -> Date = { Date() }, icons: CoinIcons? = nil
    ) {
        self.icons = icons
        self.trade = trade
        self.store = store
        self.hub = hub
        self.throttle = throttle
        self.clock = clock
        self.summary = .empty(trade.direction)
        reload()
    }

    func contentSizeChanged(_ size: CGSize) { onContentSize?(size) }

    // MARK: Derived values

    public var currentPrice: Decimal? { price.tick?.price }
    public var pnl: PnL { summary.pnl(at: currentPrice) }
    public var status: TradeStatus { summary.status }

    /// What one transaction is worth against the current price: a buy gains when the price is above its cost, a sell
    /// when it is below. Over all transactions these add up to the trade's total PnL. nil without a price.
    public func pnl(of tx: Transaction) -> Decimal? {
        guard let price = currentPrice else { return nil }
        let value = tx.quantity * price
        return tx.side == .buy ? value - tx.amount : tx.amount - value
    }

    /// First transaction to the last one when closed, to `now` while open; nil without transactions.
    public func duration(at now: Date) -> TimeInterval? {
        guard let first = transactions.map(\.occurredAt).min(), let last = transactions.map(\.occurredAt).max() else { return nil }
        return (status == .closed ? last : max(now, first)).timeIntervalSince(first)
    }
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
            onWillGrow?(CGFloat(min(transactions.count, 8)) * Self.listRowHeight + 64)
        }
        try? store.setExpanded(id: trade.id, expanded)
        trade.isExpanded = expanded
    }

    // MARK: Form

    /// Opens an empty form for a side (`Buy more`, `Sell part`, …). Orders are never sent (FR-TX-1a).
    public func openForm(side: Side) {
        if form == nil { onFormWillOpen?() }
        form = TransactionDraft(side: side, occurredAt: clock())
        editingID = nil
        formError = nil
    }

    /// Add transaction (menu / ⌘N): an empty form for the opening side. Ignored while a form is already open.
    public func addTransaction() {
        guard form == nil else { return }
        openForm(side: trade.direction.openingSide)
    }

    public func toggleList() {
        guard status != .empty else { return }
        setExpanded(!trade.isExpanded)
    }

    /// Close → sell (or buy back) everything at the current price; needs a price.
    public func closeAll() {
        guard currentPrice != nil, summary.openQuantity > 0 else { return }
        openCloseForm()
    }

    /// `Close` → all: the closing side, the whole open quantity, the current price when known.
    public func openCloseForm() { openClosingForm(quantity: summary.openQuantity) }

    /// Quantity to sell at the current price so that the USDT still out of pocket (bought minus already sold)
    /// comes back, leaving the rest as profit. nil when that is not possible: sell-first trade, no price,
    /// nothing left to recover, or the price is too low to recover it with what is held.
    public var recoverQuantity: Decimal? {
        guard trade.direction == .buyFirst, let price = currentPrice, price > 0 else { return nil }
        let outOfPocket = summary.boughtAmount - summary.soldAmount
        guard outOfPocket > 0 else { return nil }
        var exact = outOfPocket / price, rounded = Decimal()
        NSDecimalRound(&rounded, &exact, 8, .up) // never recover a hair less than the investment
        return rounded < summary.openQuantity ? rounded : nil
    }

    /// `Close` → recover the investment: sells `recoverQuantity` at the current price.
    public func openRecoverForm() {
        guard let quantity = recoverQuantity else { return }
        openClosingForm(quantity: quantity)
    }

    private func openClosingForm(quantity: Decimal) {
        guard summary.openQuantity > 0 else { return }
        if form == nil { onFormWillOpen?() }
        editingID = nil
        let side = trade.direction.closingSide
        if let rate = currentPrice {
            form = TransactionDraft(side: side, occurredAt: clock(), quantity: quantity, rate: rate)
        } else {
            var draft = TransactionDraft(side: side, occurredAt: clock())
            draft.edit(.quantity, "\(quantity)")
            form = draft
        }
        formError = nil
    }

    /// Edits an existing transaction in the same form (FR-TX-6).
    public func openEditForm(id: UUID) {
        guard let tx = transactions.first(where: { $0.id == id }) else { return }
        if form == nil { onFormWillOpen?() }
        form = TransactionDraft(side: tx.side, occurredAt: tx.occurredAt, quantity: tx.quantity, amount: tx.amount)
        editingID = id
        formError = nil
    }

    public func cancelForm() {
        editingID = nil
        form = nil
        onFormClosed?()
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
            if let editingID {
                try store.updateTransaction(
                    tradeID: trade.id, id: editingID, side: form.side, quantity: value.quantity, amount: value.amount, occurredAt: form.occurredAt
                )
            } else {
                try store.addTransaction(
                    tradeID: trade.id, side: form.side, quantity: value.quantity, amount: value.amount, occurredAt: form.occurredAt
                )
            }
            self.form = nil
            editingID = nil
            onFormClosed?()
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

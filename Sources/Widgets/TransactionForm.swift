import Domain
import Presentation
import SwiftUI

/// Form embedded in the card (FR-UI-15): Enter saves, Esc cancels, Tab moves between fields (FR-UI-6).
struct TransactionForm: View {
    let model: StickerModel
    @FocusState private var focus: TransactionDraft.Field?
    @Environment(\.isMeasuring) private var measuring

    var body: some View {
        let form = model.form
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: Binding(get: { form?.side ?? .buy }, set: { model.form?.side = $0 })) {
                    Text("Buy").tag(Side.buy)
                    Text("Sell").tag(Side.sell)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                Spacer()
                DatePicker("", selection: Binding(get: { form?.occurredAt ?? .now }, set: { model.form?.occurredAt = $0 }))
                    .labelsHidden().datePickerStyle(.compact)
            }
            HStack(spacing: 8) {
                field("Quantity", .quantity, text: form?.quantityText ?? "", auto: false)
                field("Amount", .amount, text: form?.amountText ?? "", auto: form?.isAuto(.amount) ?? false)
                field("Rate", .rate, text: form?.rateText ?? "", auto: form?.isAuto(.rate) ?? false)
            }
            if let message = model.formError ?? model.formProblems.first?.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.negative) // errors may be red (FR-UI-8)
            }
            HStack(spacing: 8) {
                Button("Cancel") { model.cancelForm() }
                    .buttonStyle(PillStyle(fill: Theme.field)).keyboardShortcut(measuring ? nil : KeyboardShortcut.cancelAction)
                Button(model.editingID == nil ? "Save" : "Save changes") { Task { await model.submit() } }
                    .buttonStyle(PillStyle(fill: Theme.accent)).keyboardShortcut(measuring ? nil : KeyboardShortcut.defaultAction).disabled(!model.canSave)
            }
        }
        .onAppear { if !measuring { focus = .quantity } }
    }

    private func field(_ title: String, _ id: TransactionDraft.Field, text: String, auto: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                if auto { Text("auto").font(.system(size: 11)).foregroundStyle(Theme.secondaryText.opacity(0.7)) }
            }
            TextField("0", text: Binding(get: { text }, set: { model.edit(id, $0) }))
                .textFieldStyle(.plain).monospacedDigit().font(.system(size: 13))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
                .opacity(auto ? 0.6 : 1)
                .focused($focus, equals: id)
        }
    }
}

/// Transactions, newest first; up to 8 rows visible, then scrolling (FR-TX-5, FR-TX-7).
struct TransactionList: View {
    let model: StickerModel
    @State private var confirming: UUID?

    private static let rowHeight = StickerModel.listRowHeight

    var body: some View {
        let rows = model.transactions.sorted { ($0.occurredAt, $0.sequence) > ($1.occurredAt, $1.sequence) }
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.listError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.negative)
            }
            header
            if rows.count > 8 {
                ScrollView { rowsStack(rows) }.frame(height: 8 * Self.rowHeight)
            } else {
                rowsStack(rows)
            }
        }
    }

    private func rowsStack(_ rows: [Domain.Transaction]) -> some View {
        VStack(spacing: 0) { ForEach(rows) { tx in row(tx) } }
    }

    private static let sideWidth: CGFloat = 40, amountWidth: CGFloat = 52, rateWidth: CGFloat = 62, agoWidth: CGFloat = 62, pnlWidth: CGFloat = 58, iconWidth: CGFloat = 14

    private var header: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: Self.iconWidth, height: 1)
            Text("When").frame(width: Self.agoWidth, alignment: .leading)
            Text("Side").frame(width: Self.sideWidth, alignment: .leading)
            Text("Qty").frame(maxWidth: .infinity, alignment: .trailing)
            Text("\(model.trade.quote)").frame(width: Self.amountWidth, alignment: .trailing)
            Text("Rate").frame(width: Self.rateWidth, alignment: .trailing)
            Text("PnL").frame(width: Self.pnlWidth, alignment: .trailing)
            Color.clear.frame(width: Self.iconWidth, height: 1)
        }
        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText.opacity(0.7)).lineLimit(1)
    }

    /// Profit or loss of one transaction against the current price; "—" while the price is unknown.
    private func pnl(_ value: Decimal?) -> some View {
        Text(value.map(NumberFormat.signedQuote) ?? "—")
            .foregroundStyle(Theme.pnl(value.map(NumberFormat.displayedQuote)))
            .minimumScaleFactor(0.6).frame(width: Self.pnlWidth, alignment: .trailing)
    }

    private func row(_ tx: Domain.Transaction) -> some View {
        HStack(spacing: 6) {
            if confirming == tx.id {
                Text("Delete this transaction?").font(.system(size: 12))
                Spacer()
                Button("Cancel") { confirming = nil }.buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
                Button("Delete") {
                    confirming = nil
                    Task { await model.deleteTransaction(id: tx.id) }
                }
                .buttonStyle(.plain).foregroundStyle(Theme.negative)
            } else {
                Button { model.openEditForm(id: tx.id) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText).frame(width: Self.iconWidth)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(Elapsed.ago(from: tx.occurredAt, to: ctx.date))
                        .help(tx.occurredAt.formatted(date: .abbreviated, time: .shortened))
                }
                .foregroundStyle(Theme.secondaryText).frame(width: Self.agoWidth, alignment: .leading).minimumScaleFactor(0.7)
                Text(tx.side == .buy ? "BUY" : "SELL") // user's choice: buy green, sell red (word stays, colour is not the only cue)
                    .font(.system(size: 10, weight: .semibold)).fixedSize()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill((tx.side == .buy ? Theme.positive : Theme.negative).opacity(0.18)))
                    .foregroundStyle(tx.side == .buy ? Theme.positive : Theme.negative)
                    .frame(width: Self.sideWidth, alignment: .leading)
                Text(NumberFormat.quantity(tx.quantity)).frame(maxWidth: .infinity, alignment: .trailing)
                    .minimumScaleFactor(0.6)
                Text(NumberFormat.amount(tx.amount)).frame(width: Self.amountWidth, alignment: .trailing)
                Text(tx.rate.map(NumberFormat.price) ?? "—").foregroundStyle(Theme.secondaryText).minimumScaleFactor(0.6).frame(width: Self.rateWidth, alignment: .trailing)
                pnl(model.pnl(of: tx))
                Button { confirming = tx.id } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.negative.opacity(0.8))
            }
        }
        .font(.system(size: 12)).monospacedDigit().lineLimit(1)
        .frame(height: Self.rowHeight)
    }
}

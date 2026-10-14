import Domain
import Presentation
import SwiftUI

/// Form embedded in the card (FR-UI-15): Enter saves, Esc cancels, Tab moves between fields (FR-UI-6).
struct TransactionForm: View {
    let model: StickerModel
    @FocusState private var focus: TransactionDraft.Field?

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
                field("Amount \(model.trade.quote)", .amount, text: form?.amountText ?? "", auto: form?.isAuto(.amount) ?? false)
                field("Rate", .rate, text: form?.rateText ?? "", auto: form?.isAuto(.rate) ?? false)
            }
            if let message = model.formError ?? model.formProblems.first?.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.negative) // errors may be red (FR-UI-8)
            }
            HStack(spacing: 8) {
                Button("Cancel") { model.cancelForm() }
                    .buttonStyle(PillStyle(fill: Theme.field)).keyboardShortcut(.cancelAction)
                Button("Save") { Task { await model.submit() } }
                    .buttonStyle(PillStyle(fill: Theme.accent)).keyboardShortcut(.defaultAction).disabled(!model.canSave)
            }
        }
        .onAppear { focus = .quantity }
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

    private static let rowHeight: CGFloat = 30

    var body: some View {
        let rows = model.transactions.sorted { ($0.occurredAt, $0.sequence) > ($1.occurredAt, $1.sequence) }
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Theme.divider)
            if let error = model.listError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.negative)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { tx in row(tx) }
                }
            }
            .frame(height: min(CGFloat(rows.count), 8) * Self.rowHeight)
        }
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
                Text(tx.occurredAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                    .foregroundStyle(Theme.secondaryText).frame(width: 78, alignment: .leading)
                Text(tx.side == .buy ? "BUY" : "SELL") // neutral pills, text not colour (FR-UI-8)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.field))
                Text(NumberFormat.quantity(tx.quantity)).frame(maxWidth: .infinity, alignment: .trailing)
                Text(NumberFormat.quote(tx.amount)).frame(width: 62, alignment: .trailing)
                Text(tx.rate.map(NumberFormat.price) ?? "—").foregroundStyle(Theme.secondaryText).frame(width: 62, alignment: .trailing)
                Button { confirming = tx.id } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.negative.opacity(0.8))
            }
        }
        .font(.system(size: 12)).monospacedDigit()
        .frame(height: Self.rowHeight)
    }
}

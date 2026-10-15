import Domain
import Presentation
import SwiftUI

/// Form embedded in the card (FR-UI-15): Enter saves, Esc cancels, Tab moves between fields (FR-UI-6).
struct TransactionForm: View {
    let model: StickerModel
    @State private var showPicker = false
    @FocusState private var focus: TransactionDraft.Field?

    var body: some View {
        let form = model.form
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.editingID == nil ? "New transaction" : "Edit transaction").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                sideSwitch(form?.side ?? .buy).frame(width: 116)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    field("Quantity (\(model.trade.base))", .quantity, text: form?.quantityText ?? "", auto: false)
                    field("Amount (\(model.trade.quote))", .amount, text: form?.amountText ?? "", auto: form?.isAuto(.amount) ?? false)
                }
                GridRow {
                    field("Rate (\(model.trade.quote))", .rate, text: form?.rateText ?? "", auto: form?.isAuto(.rate) ?? false)
                    timeField(form)
                }
            }
            if let message = model.formError ?? model.formProblems.first?.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.negative) // errors may be red (FR-UI-8)
            }
            HStack(spacing: 8) {
                Button("Cancel") { model.cancelForm() }
                    .buttonStyle(PillStyle(fill: Theme.field, minHeight: 30)).keyboardShortcut(.cancelAction)
                Button(model.editingID == nil ? "Add" : "Save changes") { Task { await model.submit() } }
                    .buttonStyle(PillStyle(fill: (form?.side ?? .buy) == .buy ? Theme.positive : Theme.negative, minHeight: 30)).keyboardShortcut(.defaultAction).disabled(!model.canSave)
            }
        }
        .background { Button("") { model.toggleForm() }.keyboardShortcut("b").opacity(0).frame(width: 0, height: 0).allowsHitTesting(false) }
        .onAppear { focus = .quantity }
    }

    /// Buy / Sell switch; the chosen side is filled with the accent colour.
    private func sideSwitch(_ side: Side) -> some View {
        HStack(spacing: 0) {
            ForEach([Side.buy, Side.sell], id: \.self) { option in
                Button { model.form?.side = option } label: {
                    Text(option == .buy ? "Buy" : "Sell").font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(side == option ? (option == .buy ? Theme.positive : Theme.negative).opacity(0.85) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
    }

    /// "Now" until the user picks a time; the popover has a calendar and a "Now" button to go back.
    private func timeField(_ form: TransactionDraft?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Time").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            Button { showPicker = true } label: {
                HStack {
                    Text(form?.isNow ?? true ? "Now" : (form?.occurredAt ?? .now).formatted(.dateTime.day().month().hour().minute()))
                        .font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Image(systemName: "calendar").foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 8).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                VStack(spacing: 8) {
                    DatePicker("", selection: Binding(
                        get: { model.form?.occurredAt ?? .now },
                        set: { model.form?.occurredAt = $0; model.form?.isNow = false }
                    ), in: ...Date.now).labelsHidden().datePickerStyle(.graphical)
                    Button("Now") { model.form?.isNow = true; showPicker = false }.disabled(model.form?.isNow ?? true)
                }
                .padding(12)
            }
        }
    }

    private func field(_ title: String, _ id: TransactionDraft.Field, text: String, auto: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1).minimumScaleFactor(0.8)
                if auto { Text("auto").font(.system(size: 11)).foregroundStyle(Theme.secondaryText.opacity(0.7)) }
            }
            TextField("0", text: Binding(get: { text }, set: { model.edit(id, $0) }))
                .textFieldStyle(.plain).monospacedDigit().font(.system(size: 13))
                .padding(.horizontal, 8).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                .opacity(auto ? 0.6 : 1)
                .focused($focus, equals: id)
        }
    }
}

/// Transactions, newest first; up to 8 rows visible, then scrolling (FR-TX-5, FR-TX-7).
struct TransactionList: View {
    let model: StickerModel
    @State private var confirming: UUID?
    @State private var hovering: UUID?

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

    private static let sideWidth: CGFloat = 26, amountWidth: CGFloat = 48, rateWidth: CGFloat = 56, agoWidth: CGFloat = 36, pnlWidth: CGFloat = 50, iconWidth: CGFloat = 14

    private var header: some View {
        HStack(spacing: 4) {
            Text("Ago").frame(width: Self.agoWidth, alignment: .leading)
            Text("Side").frame(width: Self.sideWidth, alignment: .leading)
            Text("PnL").frame(width: Self.pnlWidth, alignment: .trailing)
            Text("Qty").frame(maxWidth: .infinity, alignment: .trailing)
            Text("\(model.trade.quote)").frame(width: Self.amountWidth, alignment: .trailing)
            Text("Rate").frame(width: Self.rateWidth, alignment: .trailing)
            Color.clear.frame(width: Self.iconWidth, height: 1)
        }
        .font(.system(size: 10)).foregroundStyle(Theme.secondaryText.opacity(0.7)).lineLimit(1)
    }

    /// Profit or loss of one transaction against the current price; "—" while the price is unknown.
    private func pnl(_ value: Decimal?) -> some View {
        Text(value.map(NumberFormat.signedQuote) ?? "—")
            .foregroundStyle(Theme.pnl(value.map(NumberFormat.displayedQuote)))
            .minimumScaleFactor(0.6).frame(width: Self.pnlWidth, alignment: .trailing)
    }

    private func row(_ tx: Domain.Transaction) -> some View {
        HStack(spacing: 4) {
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
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(Elapsed.age(ctx.date.timeIntervalSince(tx.occurredAt)))
                        .help(tx.occurredAt.formatted(date: .complete, time: .standard) + "\nDouble-click the row to edit")
                }
                .foregroundStyle(Theme.secondaryText).frame(width: Self.agoWidth, alignment: .leading).minimumScaleFactor(0.7)
                Text(tx.side == .buy ? "B" : "S") // buy green, sell red; the letter keeps colour from being the only cue
                    .font(.system(size: 10, weight: .bold)).fixedSize()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill((tx.side == .buy ? Theme.positive : Theme.negative).opacity(0.18)))
                    .foregroundStyle(tx.side == .buy ? Theme.positive : Theme.negative)
                    .frame(width: Self.sideWidth, alignment: .leading)
                pnl(model.pnl(of: tx))
                Text(NumberFormat.quantity(tx.quantity)).frame(maxWidth: .infinity, alignment: .trailing)
                    .minimumScaleFactor(0.6)
                Text(NumberFormat.amount(tx.amount)).frame(width: Self.amountWidth, alignment: .trailing)
                Text(tx.rate.map(NumberFormat.price) ?? "—").foregroundStyle(Theme.secondaryText).minimumScaleFactor(0.6).frame(width: Self.rateWidth, alignment: .trailing)
                Button { confirming = tx.id } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.negative.opacity(0.8)).opacity(hovering == tx.id ? 1 : 0)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hovering == tx.id && confirming == nil ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovering = tx.id } else if hovering == tx.id { hovering = nil } }
        .onTapGesture(count: 2) { model.openEditForm(id: tx.id) }
        .contextMenu {
            Button("Edit…") { model.openEditForm(id: tx.id) }
            Button("Delete…", role: .destructive) { confirming = tx.id }
        }
        .font(.system(size: 10.5)).monospacedDigit().lineLimit(1)
        .frame(height: Self.rowHeight)
    }
}

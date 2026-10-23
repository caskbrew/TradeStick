import Domain
import Presentation
import SwiftUI

/// Form embedded in the card (FR-UI-15): Enter saves, Esc cancels, Tab moves between fields (FR-UI-6).
struct TransactionForm: View {
    let model: StickerModel
    @State private var showPicker = false
    @State private var timeText = ""
    /// The current time shown when the form opens; left untouched, the transaction is stamped when saved.
    @State private var nowText = ""
    /// The text of a transaction being edited, as first shown: left alone, its exact time (with seconds) is kept.
    @State private var shownText = ""
    @State private var shownDate: Date?
    @FocusState private var focus: TransactionDraft.Field?

    var body: some View {
        let form = model.form
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.editingID == nil ? "Add Tx" : "Edit Tx").font(.system(size: 12))
                Spacer(minLength: 8)
                sideSwitch(form?.side ?? .buy).frame(width: 64)
            }
            Grid(horizontalSpacing: 6, verticalSpacing: 4) {
                GridRow {
                    field("qty", unit: model.trade.base.lowercased(), .quantity, text: form?.quantityText ?? "", auto: false)
                    field("amt", unit: model.trade.quote.lowercased(), .amount, text: form?.amountText ?? "", auto: form?.isAuto(.amount) ?? false)
                }
                GridRow {
                    field("rate", unit: "rate", .rate, text: form?.rateText ?? "", auto: form?.isAuto(.rate) ?? false)
                    timeField(form)
                }
            }
            if let message = model.formError ?? model.formProblems.first?.message {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.negative) // errors may be red (FR-UI-8)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button("Cancel") { model.cancelForm() }
                    .buttonStyle(PillStyle(fill: Theme.field, minHeight: 26)).keyboardShortcut(.cancelAction)
                Button(model.editingID == nil ? "Add Tx" : "Save") { Task { await model.submit() } }
                    .buttonStyle(PillStyle(fill: (form?.side ?? .buy) == .buy ? Theme.positive : Theme.negative, minHeight: 26)).keyboardShortcut(.defaultAction).disabled(!model.canSave)
            }
        }
        .background { Button("") { model.toggleForm() }.keyboardShortcut("b").opacity(0).frame(width: 0, height: 0).allowsHitTesting(false) }
        .onAppear {
            nowText = TimeInput.format(.now)
            if let f = model.form {
                shownText = f.isNow ? nowText : TimeInput.format(f.occurredAt)
                shownDate = f.isNow ? nil : f.occurredAt
                timeText = shownText
            }
            focus = .quantity
        }
    }

    /// Buy / Sell switch; the chosen side is filled with the accent colour.
    private func sideSwitch(_ side: Side) -> some View {
        HStack(spacing: 0) {
            ForEach([Side.buy, Side.sell], id: \.self) { option in
                Button { model.form?.side = option } label: {
                    Text(option == .buy ? "B" : "S").font(.system(size: 12))
                        .frame(maxWidth: .infinity, minHeight: 20)
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

    /// Opens with the current time (stamped when saved if left alone). Type `HH:mm:ss` or `dd.MM.yy HH:mm:ss`, or pick in the calendar popover.
    private func timeField(_ form: TransactionDraft?) -> some View {
        HStack(spacing: 4) {
            TextField(TimeInput.format(.now), text: $timeText)
                .textFieldStyle(.plain).monospacedDigit().font(.system(size: 11)) // a TextField does not shrink its text, so the font is small
                .lineLimit(1)
                .foregroundStyle(form?.timeInvalid == true ? Theme.negative : .primary)
                .onChange(of: timeText) { _, text in applyTime(text) }
            Button { showPicker = true } label: {
                Image(systemName: "calendar").foregroundStyle(Theme.secondaryText).frame(width: 18, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                VStack(spacing: 8) {
                    DatePicker("", selection: Binding(
                        get: { model.form?.occurredAt ?? .now },
                        set: { timeText = TimeInput.format($0) }
                    ), in: ...Date.now).labelsHidden().datePickerStyle(.graphical)
                    Button("Now") { nowText = TimeInput.format(.now); shownText = ""; shownDate = nil; timeText = nowText; showPicker = false }.disabled(model.form?.isNow ?? true)
                }
                .padding(12)
            }
        }
        .padding(.leading, 6).padding(.trailing, 2).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
    }

    private func applyTime(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == shownText, model.form?.isNow == false {
            if let shownDate { model.form?.occurredAt = shownDate } // untouched or typed back: the stored time to the second
            model.form?.timeInvalid = false
        } else if trimmed.isEmpty || trimmed == nowText {
            model.form?.isNow = true; model.form?.timeInvalid = false
        } else if let date = TimeInput.parse(trimmed, now: model.form.map { $0.isNow ? Date.now : $0.occurredAt } ?? .now) {
            model.form?.occurredAt = date; model.form?.isNow = false; model.form?.timeInvalid = false
        } else {
            model.form?.timeInvalid = true
        }
    }

    /// Digits and one dot only; a comma counts as a dot.
    private static func numeric(_ text: String) -> String {
        var seenDot = false
        return String(text.compactMap { ch -> Character? in
            if ch.isASCII, ch.isNumber { return ch }
            if (ch == "." || ch == ","), !seenDot { seenDot = true; return "." }
            return nil
        })
    }

    /// The label lives inside the field: a placeholder while empty, the unit (and "auto") on the right.
    private func field(_ title: String, unit: String, _ id: TransactionDraft.Field, text: String, auto: Bool) -> some View {
        HStack(spacing: 4) {
            TextField(title, text: Binding(get: { text }, set: { model.edit(id, Self.numeric($0)) }))
                .textFieldStyle(.plain).monospacedDigit().font(.system(size: 12))
                .focused($focus, equals: id)
            Text(auto ? "auto" : unit).font(.system(size: 10)).foregroundStyle(Theme.secondaryText).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 6).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
        .opacity(auto ? 0.6 : 1)
    }
}

/// Transactions, newest first; up to 8 rows visible, then scrolling (FR-TX-5, FR-TX-7).
struct TransactionList: View {
    let model: StickerModel
    @State private var confirming: UUID?
    @State private var hovering: UUID?

    private static let rowHeight = StickerModel.listRowHeight
    private static let maxRows = 24 // more than that scrolls

    var body: some View {
        let rows = model.transactions.sorted { ($0.occurredAt, $0.sequence) > ($1.occurredAt, $1.sequence) }
        let columns = model.columns
        VStack(alignment: .leading, spacing: 0) {
            header(columns)
            if let error = model.listError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.negative).padding(.horizontal, ListColumns.inset).padding(.top, 4)
            }
            Group {
                if rows.count > Self.maxRows {
                    ScrollView { rowsStack(rows, columns) }.frame(height: CGFloat(Self.maxRows) * Self.rowHeight)
                } else {
                    rowsStack(rows, columns)
                }
            }
            .padding(.horizontal, ListColumns.inset)
            .padding(.bottom, 6.5)
        }
    }

    /// Titles of the columns, on a slightly lighter band that runs edge to edge.
    private func header(_ c: ListColumns) -> some View {
        HStack(spacing: ListColumns.spacing) {
            Text("Rate").frame(width: c.rate, alignment: .center)
            Text(model.trade.quote).frame(width: c.amount, alignment: .center)
            Text(model.trade.base).frame(width: c.qty, alignment: .center)
            Text("Fee").frame(width: c.fee, alignment: .center)
            Color.clear.frame(width: ListColumns.side, height: 1) // the B/S chip needs no title
            Text("PnL").frame(width: c.pnl, alignment: .center)
        }
        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
        .padding(.horizontal, ListColumns.inset)
        .frame(maxWidth: .infinity).frame(height: 18.5)
        .background(Color.white.opacity(0.035))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rowLine).frame(height: 1) }
    }

    private func rowsStack(_ rows: [Domain.Transaction], _ columns: ListColumns) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { tx in
                row(tx, columns)
                if tx.id != rows.last?.id { Rectangle().fill(Theme.rowLine).frame(height: 1) }
            }
        }
    }

    /// Profit or loss of one transaction against the current price; "—" while the price is unknown.
    private func pnl(_ value: Decimal?, _ columns: ListColumns) -> some View {
        Text(value.map { NumberFormat.signedQuote($0, fixed: model.quoteFixed) } ?? "—")
            .foregroundStyle(Theme.pnl(value.map { NumberFormat.displayedQuote($0, fixed: model.quoteFixed) }))
            .minimumScaleFactor(0.3).frame(width: columns.pnl, alignment: .leading)
    }

    private func row(_ tx: Domain.Transaction, _ columns: ListColumns) -> some View {
        // The grey of the numbers leans a little green on a profitable row and red on a losing one.
        let value = model.pnl(of: tx).map { NumberFormat.displayedQuote($0, fixed: model.quoteFixed) }
        let grey = value.map { $0 == 0 ? Theme.secondaryText : Theme.secondaryText.mix(with: Theme.pnl($0), by: 0.16) } ?? Theme.secondaryText
        return HStack(spacing: ListColumns.spacing) {
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
                Text(tx.rate.map(NumberFormat.shownPrice) ?? "—").foregroundStyle(grey).minimumScaleFactor(0.3).frame(width: columns.rate, alignment: .leading)
                Text(NumberFormat.quote(tx.amount, fixed: model.quoteFixed)).foregroundStyle(grey).minimumScaleFactor(0.3).frame(width: columns.amount, alignment: .leading)
                Text(NumberFormat.quantity(tx.quantity)).foregroundStyle(grey).frame(width: columns.qty, alignment: .leading)
                    .minimumScaleFactor(0.3)
                Text(tx.fee.map { NumberFormat.quote($0, fixed: model.quoteFixed) } ?? "—").foregroundStyle(grey).minimumScaleFactor(0.3)
                    .frame(width: columns.fee, alignment: .leading).help("Fee, included in the amount")
                Text(tx.side == .buy ? "B" : "S") // buy green, sell red; the letter keeps colour from being the only cue
                    .font(.system(size: 10)).fixedSize()
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(tx.side == .buy ? Color(red: 0.063, green: 0.286, blue: 0.212) : Color(red: 0.30, green: 0.10, blue: 0.13)))
                    .foregroundStyle(tx.side == .buy ? Color(red: 0.41, green: 0.98, blue: 0.84) : Color(red: 1.0, green: 0.48, blue: 0.52))
                    .frame(width: ListColumns.side, alignment: .leading)
                pnl(model.pnl(of: tx), columns)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hovering == tx.id && confirming == nil ? 0.06 : 0)))
        .overlay(alignment: .trailing) { // over the end of the PnL while hovering, so the row keeps equal margins
            if hovering == tx.id && confirming == nil {
                Button { confirming = tx.id } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Theme.negative)
                    .padding(.horizontal, 6).frame(maxHeight: .infinity).background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                    .offset(x: ListColumns.inset - 1) // out into the margin, against the window edge
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in if inside { hovering = tx.id } else if hovering == tx.id { hovering = nil } }
        .onTapGesture(count: 2) { model.openEditForm(id: tx.id) }
        .contextMenu {
            Button("Edit…") { model.openEditForm(id: tx.id) }
            Button("Delete…", role: .destructive) { confirming = tx.id }
        }
        .font(.system(size: 12.5)).monospacedDigit().lineLimit(1)
        .help(tx.occurredAt.formatted(date: .complete, time: .standard) + "\nDouble-click the row to edit") // the Ago column is gone: the time is in the tooltip
        .frame(height: Self.rowHeight - 1)
    }
}

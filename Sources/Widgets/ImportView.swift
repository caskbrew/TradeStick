import Domain
import Presentation
import SwiftUI

/// "Import from Binance" card: dark glass like the stickers; a table of fills or orders with check boxes.
public struct ImportView: View {
    @Bindable var model: ImportModel
    let onClose: () -> Void

    nonisolated(unsafe) static var plainRows = false
    private static let accent = Color(red: 0.04, green: 0.45, blue: 1.0)

    public init(model: ImportModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.title).font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.state != .loading { Toggle("Group by order", isOn: Binding(get: { model.grouped }, set: { model.setGrouped($0) }))
                    .toggleStyle(.checkbox).tint(Self.accent).font(.system(size: 13))
                    .help("One row per order, like the exchange's web history. Off: one row per fill") }
            }
            HStack {
                Text(model.pair).font(.system(size: 14)).padding(.horizontal, 12).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
                Spacer()
                if model.state != .loading {
                    Picker("", selection: $model.filter) {
                        ForEach(ImportModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            table
            if let error = model.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.negative).font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if model.state != .loading { Text(summary).font(.system(size: 13)).foregroundStyle(model.canAdd ? .white : Theme.secondaryText) }
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                    .buttonStyle(PillStyle(fill: Theme.field, flexible: false, minHeight: 36))
                if model.state != .loading { Button("Import \(model.selection.count)") { if model.add() { onClose() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillStyle(fill: Self.accent, flexible: false, minHeight: 36)).disabled(!model.canAdd) }
            }
        }
        .padding(14)
        .frame(width: 720, height: 440)
        .background(GlassBackground())
        .environment(\.colorScheme, .dark)
        .task { if !model.hasLoaded { await model.load() } }
    }

    private var summary: String {
        guard model.canAdd else { return "Nothing selected" }
        return "\(model.selection.count) selected (\(NumberFormat.quote(model.selectedAmount, fixed: model.fixedQuote)) \(quoteSymbol))"
    }

    private var quoteSymbol: String { model.pair.split(separator: "/").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }

    // MARK: Table

    private static let widths: (check: CGFloat, time: CGFloat, side: CGFloat, qty: CGFloat, amt: CGFloat, rate: CGFloat, fee: CGFloat) =
        (26, 104, 44, 92, 92, 78, 110)

    @ViewBuilder private var table: some View {
        switch model.state {
        case .loading:
            VStack { ProgressView("Loading trade history…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let text):
            VStack(spacing: 10) {
                Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.negative).fixedSize(horizontal: false, vertical: true)
                Button("Retry") { Task { await model.load() } }.buttonStyle(PillStyle(fill: Theme.field, flexible: false, minHeight: 30))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where model.visibleRows.isEmpty:
            Text(model.rows.isEmpty ? "No trades for this pair on the exchange." : "No new trades.")
                .foregroundStyle(Theme.secondaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            VStack(spacing: 0) {
                header
                if Self.plainRows { // snapshots cannot draw a ScrollView
                    VStack(spacing: 0) { ForEach(model.visibleRows) { rowView($0) } }.frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) { ForEach(model.visibleRows) { rowView($0) } }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var header: some View {
        let w = Self.widths
        return HStack(spacing: 8) {
            Button { model.toggleAll() } label: { box(model.allSelected, enabled: model.selectableCount > 0) }.buttonStyle(.plain).frame(width: w.check)
            Button { model.newestFirst.toggle() } label: {
                HStack(spacing: 3) { Text("Time"); Image(systemName: model.newestFirst ? "chevron.down" : "chevron.up").font(.system(size: 8)) }
            }
            .buttonStyle(.plain).frame(width: w.time, alignment: .leading)
            Text("Side").frame(width: w.side, alignment: .leading)
            Text("Qty").frame(width: w.qty, alignment: .trailing)
            Text("Amount").frame(width: w.amt, alignment: .trailing)
            Text("Rate").frame(width: w.rate, alignment: .trailing)
            Text("Fee").frame(width: w.fee, alignment: .trailing)
            Text("Status").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 12).frame(height: 28).background(Color.white.opacity(0.05))
    }

    private func rowView(_ row: ImportModel.Row) -> some View {
        let w = Self.widths
        let t = row.trade
        return HStack(spacing: 8) {
            box(model.selection.contains(row.id), enabled: row.selectable).frame(width: w.check)
            Text(Self.time(t.occurredAt)).frame(width: w.time, alignment: .leading)
            Text(t.side == .buy ? "BUY" : "SELL").foregroundStyle(t.side == .buy ? Theme.positive : Theme.negative).frame(width: w.side, alignment: .leading)
            Text(NumberFormat.quantity(t.quantity)).frame(width: w.qty, alignment: .trailing)
            Text(NumberFormat.quote(t.amount, fixed: model.fixedQuote)).frame(width: w.amt, alignment: .trailing)
            Text(t.rate.map(NumberFormat.price) ?? "").frame(width: w.rate, alignment: .trailing)
            Text(t.feeText ?? "—").lineLimit(1).minimumScaleFactor(0.7).foregroundStyle(Theme.secondaryText).frame(width: w.fee, alignment: .trailing)
            status(row).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 13).monospacedDigit())
        .padding(.horizontal, 12).frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(row.id) }
    }

    @ViewBuilder private func status(_ row: ImportModel.Row) -> some View {
        if row.alreadyAdded { Text("added").foregroundStyle(Theme.secondaryText) }
        else if row.partlyAdded { Text("partly").foregroundStyle(Theme.warning).help("Some fills of this order were imported one by one: turn off Group by order") }
        else { Text("new").foregroundStyle(Theme.positive) }
    }

    private func box(_ on: Bool, enabled: Bool) -> some View {
        Image(systemName: on ? "checkmark.square.fill" : "square")
            .font(.system(size: 17)).foregroundStyle(on ? Self.accent : Color.white.opacity(enabled ? 0.45 : 0.2))
    }

    /// `15.10 10:32`; the year is added for dates outside the current year.
    private static func time(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.day, .month, .year, .hour, .minute], from: date)
        let year = c.year == Calendar.current.component(.year, from: .now) ? "" : String(format: ".%02d", c.year! % 100)
        return String(format: "%02d.%02d%@ %02d:%02d", c.day!, c.month!, year, c.hour!, c.minute!)
    }
}

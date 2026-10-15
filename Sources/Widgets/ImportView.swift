import Domain
import Presentation
import SwiftUI

/// "Import from trade history": pick the exchange fills to add to this trade.
public struct ImportView: View {
    let model: ImportModel
    let onClose: () -> Void

    public init(model: ImportModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.title).font(.headline)
                Spacer()
                Toggle("Group by order", isOn: Binding(get: { model.grouped }, set: { model.setGrouped($0) })).toggleStyle(.checkbox)
                    .help("One row per order, like the exchange's web history. Off: one row per fill")
            }
            content
            if let error = model.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.negative).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Select all") { model.selectAll() }.disabled(model.selectableCount == 0)
                Button("None") { model.selectNone() }.disabled(!model.canAdd)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Button("Add \(model.selection.count) selected") { if model.add() { onClose() } }
                    .keyboardShortcut(.defaultAction).disabled(!model.canAdd)
            }
        }
        .padding(16).frame(width: 640, height: 460)
        .task { await model.load() }
    }

    private func detail(_ trade: ImportedTrade) -> String {
        [trade.fillIDs.count > 1 ? "\(trade.fillIDs.count) fills" : nil, trade.feeText.map { "fee \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            VStack { ProgressView("Loading trade history…") }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let text):
            VStack(spacing: 8) {
                Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.negative).fixedSize(horizontal: false, vertical: true)
                Button("Retry") { Task { await model.load() } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where model.rows.isEmpty:
            Text("No trades for this pair on the exchange.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            HStack(spacing: 10) {
                Text("").frame(width: 20); Text("time").frame(width: 130, alignment: .leading); Text("").frame(width: 36)
                Text("qty").frame(width: 90, alignment: .trailing); Text("amt").frame(width: 80, alignment: .trailing); Text("rate").frame(width: 80, alignment: .trailing)
            }.font(.caption).foregroundStyle(.secondary)
            List(model.rows) { row in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { model.selection.contains(row.id) }, set: { _ in model.toggle(row.id) }))
                        .labelsHidden().disabled(!row.selectable)
                    Text(TimeInput.format(row.trade.occurredAt)).frame(width: 130, alignment: .leading)
                    Text(row.trade.side == .buy ? "BUY" : "SELL").bold()
                        .foregroundStyle(row.trade.side == .buy ? Theme.positive : Theme.negative).frame(width: 36, alignment: .leading)
                    Text(NumberFormat.quantity(row.trade.quantity)).frame(width: 90, alignment: .trailing)
                    Text(NumberFormat.amount(row.trade.amount)).frame(width: 80, alignment: .trailing)
                    Text(row.trade.rate.map(NumberFormat.price) ?? "").frame(width: 80, alignment: .trailing)
                    Text(row.alreadyAdded ? "added" : row.partlyAdded ? "partly added" : detail(row.trade))
                        .foregroundStyle(.secondary).font(.caption).lineLimit(1)
                }
                .font(.system(size: 12).monospacedDigit())
                .opacity(row.selectable ? 1 : 0.5)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(row.id) }
            }
        }
    }
}

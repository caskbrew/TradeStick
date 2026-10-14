import Domain
import SwiftUI

/// New Trade dialog (FR-NEW-1): exchange, pair, direction with a one-line explanation of each.
public struct NewTradeView: View {
    @Bindable var model: NewTradeModel
    let onCreate: (NewTradeRequest) -> Void
    let onCancel: () -> Void
    @FocusState private var pairFocused: Bool

    public init(model: NewTradeModel, onCreate: @escaping (NewTradeRequest) -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Trade").font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Exchange").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $model.exchange) {
                    ForEach(model.exchanges, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Pair").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("GRAM/USDT", text: $model.pairText)
                    .textFieldStyle(.roundedBorder).focused($pairFocused)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Direction").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $model.direction) {
                    Text("Buy-first").tag(Direction.buyFirst)
                    Text("Sell-first").tag(Direction.sellFirst)
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(model.direction == .buyFirst
                     ? "Buy now, sell later. You profit when the price rises."
                     : "Sell now, buy back later. You profit when the price falls.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(model.isChecking ? "Checking…" : "Create") {
                    Task { if let request = await model.validate() { onCreate(request) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isChecking || model.pairText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { pairFocused = true }
    }
}

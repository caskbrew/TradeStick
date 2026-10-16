import Domain
import SwiftUI

/// New Trade dialog (FR-NEW-1): exchange, pair, direction with a one-line explanation of each.
public struct NewTradeView: View {
    @Bindable var model: NewTradeModel
    let onCreate: (NewTradeRequest) -> Void
    let onCancel: () -> Void
    @FocusState private var pairFocused: Bool
    @State private var listOpen = false
    @State private var lastPicked = ""

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
                HStack(spacing: 4) {
                    TextField("GRAM/USDT", text: $model.pairText)
                        .textFieldStyle(.roundedBorder).focused($pairFocused)
                        .onChange(of: model.pairText) { _, text in if pairFocused, text != lastPicked { listOpen = true } }
                    Button { listOpen.toggle(); pairFocused = true } label: {
                        Image(systemName: listOpen ? "chevron.up" : "chevron.down").frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).help("Pairs of \(model.exchange.capitalized)")
                }
                if listOpen { pairList }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Direction").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $model.direction) {
                    Text("Buy").tag(Direction.buyFirst)
                    Text("Sell").tag(Direction.sellFirst)
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
        .task { await model.loadInstruments() }
        .onChange(of: model.exchange) { _, _ in Task { await model.loadInstruments() } }
    }

    /// The exchange's pairs filtered by what is typed.
    @ViewBuilder private var pairList: some View {
        let items = model.suggestions
        Group {
            if model.instrumentsLoading && items.isEmpty {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading pairs…") }.font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
            } else if items.isEmpty {
                Text(model.instruments.isEmpty ? "The pair list is not available: type the pair" : "No such pair").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items, id: \.self) { item in
                            Button {
                                model.pick(item)
                                lastPicked = model.pairText
                                listOpen = false
                            } label: {
                                Text("\(item.base) / \(item.quote)").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: min(CGFloat(items.count) * 26, 170))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
    }
}

import Domain
import Presentation
import SwiftUI

/// New Trade dialog (FR-NEW-1): a dark glass card like the stickers: exchange, pair with a drop-down of the
/// exchange's pairs, direction with a one-line explanation.
public struct NewTradeView: View {
    @Bindable var model: NewTradeModel
    let onCreate: (NewTradeRequest) -> Void
    let onCancel: () -> Void
    @FocusState private var pairFocused: Bool
    @State private var listOpen = false
    @State private var lastPicked = ""

    private static let accent = Color(red: 0.04, green: 0.45, blue: 1.0)

    public init(model: NewTradeModel, onCreate: @escaping (NewTradeRequest) -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Trade").font(.system(size: 24, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                label("Exchange", ok: !model.exchange.isEmpty)
                exchangePicker
            }

            VStack(alignment: .leading, spacing: 6) {
                label("Pair", ok: pairIsKnown)
                pairField
                if listOpen { pairList }
            }

            VStack(alignment: .leading, spacing: 8) {
                label("Direction", ok: nil)
                directionSwitch
                Text(model.direction == .buyFirst
                     ? "Buy now, sell later. You profit when the price rises."
                     : "Sell now, buy back later. You profit when the price falls.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
            }

            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.negative)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    .buttonStyle(PillStyle(fill: Theme.field, flexible: false, minHeight: 38)).frame(minWidth: 110)
                Button(model.isChecking ? "Checking…" : "Create") {
                    Task { if let request = await model.validate() { onCreate(request) } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PillStyle(fill: Self.accent, flexible: false, minHeight: 38)).frame(minWidth: 130)
                .disabled(model.isChecking || model.pairText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(GlassBackground())
        .environment(\.colorScheme, .dark)
        .onAppear { pairFocused = true }
        .task { await model.loadInstruments() }
        .onChange(of: model.exchange) { _, _ in Task { await model.loadInstruments() } }
    }

    /// The typed pair is on the exchange's list (or the list is not available and something is typed).
    private var pairIsKnown: Bool {
        let candidates = InstrumentParser.candidates(model.pairText)
        guard !candidates.isEmpty else { return false }
        return model.instruments.isEmpty || candidates.contains { model.instruments.contains($0) }
    }

    private func label(_ text: String, ok: Bool?) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
            if ok == true { Circle().fill(Theme.positive).frame(width: 6, height: 6) }
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    private var exchangePicker: some View {
        Menu {
            ForEach(model.exchanges, id: \.self) { id in Button(id.capitalized) { model.exchange = id } }
        } label: {
            pill {
                HStack(spacing: 10) {
                    Image(systemName: "diamond.fill").font(.system(size: 18)).foregroundStyle(Color(red: 0.98, green: 0.78, blue: 0.2))
                    Text(model.exchange.capitalized).font(.system(size: 16))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
                }
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }

    private var pairField: some View {
        pill {
            HStack(spacing: 6) {
                TextField("GRAM/USDT", text: $model.pairText)
                    .textFieldStyle(.plain).font(.system(size: 16)).focused($pairFocused)
                    .onChange(of: model.pairText) { _, text in if pairFocused, text != lastPicked { listOpen = true } }
                Button { listOpen.toggle(); pairFocused = true } label: {
                    Image(systemName: listOpen ? "chevron.up" : "chevron.down").font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Pairs of \(model.exchange.capitalized)")
            }
        }
    }

    private var directionSwitch: some View {
        HStack(spacing: 0) {
            ForEach([Direction.buyFirst, Direction.sellFirst], id: \.self) { option in
                Button { model.direction = option } label: {
                    Text(option == .buyFirst ? "BUY" : "SELL").font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(model.direction == option ? Self.accent : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    /// The exchange's pairs filtered by what is typed.
    @ViewBuilder private var pairList: some View {
        let items = model.suggestions
        Group {
            if model.instrumentsLoading && items.isEmpty {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading pairs…") }.font(.system(size: 13)).foregroundStyle(Theme.secondaryText).padding(10)
            } else if items.isEmpty {
                Text(model.instruments.isEmpty ? "The pair list is not available: type the pair" : "No such pair")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondaryText).padding(10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items, id: \.self) { item in
                            Button {
                                model.pick(item)
                                lastPicked = model.pairText
                                listOpen = false
                            } label: {
                                Text("\(item.base)/\(item.quote)").font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: min(CGFloat(items.count) * 30, 180))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

import AppKit
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
    @State private var highlight = 0

    private static let accent = Color(red: 0.04, green: 0.45, blue: 1.0)

    public init(model: NewTradeModel, onCreate: @escaping (NewTradeRequest) -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("New Trade").font(.system(size: 17, weight: .semibold))
                exchangePicker
            }

            pairField
                .overlay(alignment: .topLeading) { if listOpen { pairList.offset(y: 36) } } // floats over the rows below, the window keeps its size
                .zIndex(1)

            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.negative) }

            HStack(spacing: 8) {
                Button(action: onCancel) { Text("Cancel") }.keyboardShortcut(.cancelAction)
                    .buttonStyle(PillStyle(fill: Theme.field, flexible: true, minHeight: 30))
                create("Create BUY", .buyFirst, Theme.positive)
                create("Create SELL", .sellFirst, Theme.negative)
            }
        }
        .padding(16)
        .frame(width: 340)
        .contentShape(Rectangle())
        .onTapGesture { listOpen = false } // a click on empty space closes the list
        .background(GlassBackground())
        .environment(\.colorScheme, .dark)
        .onAppear { pairFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in pairFocused = true } // the window is not key yet in onAppear
        .task { await model.loadInstruments() }
        .onChange(of: model.exchange) { _, _ in Task { await model.loadInstruments() } }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    private var exchangePicker: some View {
        Menu {
            ForEach(model.exchanges, id: \.self) { id in Button(id.capitalized) { model.exchange = id } }
        } label: {
            pill {
                HStack(spacing: 8) {
                    ExchangeLogo(exchange: model.exchange, size: 18)
                    Text(model.exchange.capitalized).font(.system(size: 13))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }

    private var pairField: some View {
        pill {
            HStack(spacing: 6) {
                TextField("GRAM/USDT", text: $model.pairText)
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($pairFocused)
                    .onChange(of: model.pairText) { _, text in if pairFocused, text != lastPicked { listOpen = true; highlight = 0 } }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.return) { choose() }
                    .onKeyPress(.escape) { listOpen ? { listOpen = false; return .handled }() : .ignored }
                if model.instrumentsLoading { ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14).help("Updating the pair list…") }
                Button { listOpen.toggle(); pairFocused = true } label: {
                    Image(systemName: listOpen ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Pairs of \(model.exchange.capitalized)")
            }
        }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let count = model.suggestions.count
        guard count > 0 else { return .ignored }
        if !listOpen { listOpen = true; return .handled }
        highlight = min(max(highlight + step, 0), count - 1)
        return .handled
    }

    private func choose() -> KeyPress.Result {
        let items = model.suggestions
        guard listOpen, items.indices.contains(highlight) else { return .ignored }
        pick(items[highlight])
        return .handled
    }

    private func pick(_ item: Instrument) {
        model.pick(item)
        lastPicked = model.pairText
        listOpen = false
    }

    private func create(_ title: String, _ direction: Direction, _ color: Color) -> some View {
        Button {
            model.direction = direction
            Task { if let request = await model.validate() { onCreate(request) } }
        } label: { Text(model.isChecking ? "Checking…" : title) }
        .buttonStyle(PillStyle(fill: color, flexible: true, minHeight: 30))
        .disabled(model.isChecking || model.pairText.trimmingCharacters(in: .whitespaces).isEmpty)
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
                ScrollViewReader { proxy in
                  ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element) { index, item in
                            Button { pick(item) } label: {
                                Text("\(item.base)/\(item.quote)").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 3).contentShape(Rectangle())
                                    .background(index == highlight ? Self.accent.opacity(0.6) : .clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                  }
                  .onChange(of: highlight) { _, index in if items.indices.contains(index) { proxy.scrollTo(items[index]) } }
                }
                .frame(height: min(CGFloat(items.count) * 24, 48)) // two rows: what fits over the buttons, the rest scrolls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.17)))
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
    }
}

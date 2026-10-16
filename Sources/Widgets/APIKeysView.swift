import AppKit
import SwiftUI

/// "API Keys" window: one card per exchange, switched with the exchange drop-down.
public struct APIKeysView: View {
    let models: [APIKeysModel]
    let onClose: () -> Void
    @State private var selected: String

    public init(models: [APIKeysModel], initial: String? = nil, onClose: @escaping () -> Void) {
        self.models = models
        self.onClose = onClose
        _selected = State(initialValue: models.contains { $0.exchange == initial } ? initial! : models.first?.exchange ?? "")
    }

    public var body: some View {
        if let model = models.first(where: { $0.exchange == selected }) {
            APIKeysCard(model: model, exchanges: models.map(\.exchange), select: { selected = $0 }, onClose: onClose).id(selected)
        }
    }
}

/// A dark glass panel like the stickers (reference: exchange row with status, masked key and secret).
struct APIKeysCard: View {
    @Bindable var model: APIKeysModel
    let exchanges: [String]
    let select: (String) -> Void
    let onClose: () -> Void
    @FocusState private var keyFocused: Bool
    @State private var revealKey: Bool
    @State private var editingSecret = false

    init(model: APIKeysModel, exchanges: [String], select: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.model = model
        self.exchanges = exchanges
        self.select = select
        self.onClose = onClose
        _revealKey = State(initialValue: !model.hasSavedKey) // a key being typed or pasted is shown; a saved one is masked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Keys").font(.system(size: 16, weight: .semibold))

            HStack(spacing: 10) {
                ExchangeLogo(exchange: model.exchange, size: 28).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        exchangeMenu
                        if model.connected {
                            HStack(spacing: 5) { Circle().fill(Theme.positive).frame(width: 7, height: 7); Text("Connected") }
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.positive)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.positive.opacity(0.14)))
                        }
                    }
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(model.readOnly == false ? Theme.warning : Theme.secondaryText)
                }
                Spacer()
                Button("Test") { Task { await model.test() } }
                    .buttonStyle(PillStyle(fill: Theme.field, flexible: false, minHeight: 28)).padding(.horizontal, 0)
                    .disabled(!model.canSubmit)
            }

            row("API Key") {
                Group {
                    if revealKey { TextField("", text: $model.keyText).focused($keyFocused) } else { SecureField("", text: $model.keyText) }
                }
                iconButton(revealKey ? "eye.slash" : "eye", help: revealKey ? "Hide" : "Show") { revealKey.toggle() }
                iconButton("doc.on.doc", help: "Copy the key") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.keyText, forType: .string)
                }
            }

            row("Secret") {
                if model.hasSavedKey && !editingSecret {
                    Text(String(repeating: "•", count: 20)).foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 8)
                    Text("Stored in Keychain").font(.system(size: 12, design: .default)).foregroundStyle(Theme.secondaryText)
                    iconButton("pencil", help: "Enter a new secret") { editingSecret = true }
                } else {
                    SecureField(model.hasSavedKey ? "new secret" : "", text: $model.secretText)
                }
            }

            statusView

            HStack(spacing: 8) {
                Button("Remove") { model.remove(); editingSecret = false; revealKey = true }
                    .buttonStyle(PillStyle(fill: Theme.negative.opacity(0.9), flexible: false, minHeight: 34)).disabled(!model.hasSavedKey)
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                    .buttonStyle(PillStyle(fill: Theme.field, flexible: false, minHeight: 34))
                Button("Save") { Task { await model.save(); if model.status == .ok("Saved") { editingSecret = false; revealKey = false } } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillStyle(fill: Color(red: 0.04, green: 0.45, blue: 1.0), flexible: false, minHeight: 34)).disabled(!model.canSubmit)
            }
        }
        .padding(14)
        .frame(width: 600)
        .background(GlassBackground())
        .environment(\.colorScheme, .dark)
        .onAppear { keyFocused = true }
    }

    /// The exchange name as a drop-down of all exchanges.
    private var exchangeMenu: some View {
        Menu {
            ForEach(exchanges, id: \.self) { id in Button(id.capitalized) { select(id) } }
        } label: {
            HStack(spacing: 5) {
                Text(model.exchange.capitalized).font(.system(size: 15, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var subtitle: String {
        var parts: [String] = []
        switch model.readOnly {
        case true?: parts.append("Read-only")
        case false?: parts.append("Trading or withdrawals enabled: use a read-only key")
        case nil: if !model.hasSavedKey { parts.append("Use a read-only key") }
        }
        if let when = model.lastChecked {
            parts.append("Last checked " + when.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().hour(.twoDigits(amPM: .omitted)).minute()))
        } else if model.hasSavedKey {
            parts.append("Not checked yet")
        }
        return parts.joined(separator: " · ")
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).frame(width: 64, alignment: .leading)
            HStack(spacing: 8) { content() }
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 12).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
        }
    }

    private func iconButton(_ symbol: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.secondaryText).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .idle: EmptyView()
        case .working(let text): HStack(spacing: 6) { ProgressView().controlSize(.small); Text(text) }.font(.system(size: 12))
        case .ok: EmptyView() // the Connected badge says it
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.negative).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

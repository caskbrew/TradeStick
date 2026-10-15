import SwiftUI

/// "Exchange API Keys" window content.
public struct APIKeysView: View {
    @Bindable var model: APIKeysModel
    let onClose: () -> Void

    public init(model: APIKeysModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Binance API key").font(.headline)
            Text("Used only to read your trade history. Create a read-only key (no trading, no withdrawals). It is stored in the macOS Keychain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("API Key")
                    TextField("", text: $model.keyText).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Secret")
                    SecureField(model.hasSavedKey ? "saved (leave empty to keep)" : "", text: $model.secretText).textFieldStyle(.roundedBorder)
                }
            }
            statusView
            HStack {
                Button("Remove", role: .destructive) { model.remove() }.disabled(!model.hasSavedKey)
                Spacer()
                Button("Test") { Task { await model.test() } }.disabled(!model.canSubmit)
                Button("Save") { Task { await model.save() } }.keyboardShortcut(.defaultAction).disabled(!model.canSubmit)
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 440)
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .idle: EmptyView()
        case .working(let text): HStack { ProgressView().controlSize(.small); Text(text) }.font(.callout)
        case .ok(let text, let warnings):
            VStack(alignment: .leading, spacing: 4) {
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }.font(.callout)
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.negative).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

import SwiftUI

/// "API Keys" window, laid out like the New Trade dialog: small grey labels over the fields.
public struct APIKeysView: View {
    @Bindable var model: APIKeysModel
    let onClose: () -> Void
    @FocusState private var keyFocused: Bool

    public init(model: APIKeysModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("API Keys").font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Exchange").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: .constant(model.exchange)) { Text("Binance").tag("binance") }.labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API Key").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("", text: $model.keyText).textFieldStyle(.roundedBorder).focused($keyFocused)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Secret").font(.system(size: 12)).foregroundStyle(.secondary)
                SecureField(model.hasSavedKey ? "saved, leave empty to keep" : "", text: $model.secretText).textFieldStyle(.roundedBorder)
            }

            Text("Used only to read your trade history. Use a read-only key (no trading, no withdrawals). Stored in the macOS Keychain.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            statusView

            HStack {
                Button("Remove", role: .destructive) { model.remove() }.disabled(!model.hasSavedKey)
                Spacer()
                Button("Test") { Task { await model.test() } }.disabled(!model.canSubmit)
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Save") { Task { await model.save() } }.keyboardShortcut(.defaultAction).disabled(!model.canSubmit)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { keyFocused = true }
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .idle: EmptyView()
        case .working(let text): HStack(spacing: 6) { ProgressView().controlSize(.small); Text(text) }.font(.system(size: 12))
        case .ok(let text, let warnings):
            VStack(alignment: .leading, spacing: 4) {
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.negative).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

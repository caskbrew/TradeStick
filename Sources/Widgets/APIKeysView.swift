import SwiftUI

/// "API Keys" window in the look of the stickers: dark, white text, pill fields and buttons.
public struct APIKeysView: View {
    @Bindable var model: APIKeysModel
    let onClose: () -> Void
    @FocusState private var keyFocused: Bool

    /// Window background; the app sets the same colour on the window itself.
    public static let background = Color(red: 0.10, green: 0.11, blue: 0.14)

    public init(model: APIKeysModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("API Keys").font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 5) {
                label("Exchange")
                Text("Binance").font(.system(size: 13)).padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            }

            VStack(alignment: .leading, spacing: 5) {
                label("API Key")
                field {
                    TextField("", text: $model.keyText).focused($keyFocused)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                label("Secret")
                field {
                    SecureField(model.hasSavedKey ? "saved, leave empty to keep" : "", text: $model.secretText)
                }
            }

            Text("Used only to read your trade history. Use a read-only key (no trading, no withdrawals). Stored in the macOS Keychain.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)

            statusView

            HStack(spacing: 8) {
                Button("Remove") { model.remove() }
                    .buttonStyle(PillStyle(fill: Theme.negative.opacity(0.55), flexible: false, minHeight: 30)).disabled(!model.hasSavedKey)
                Spacer()
                Button("Test") { Task { await model.test() } }
                    .buttonStyle(PillStyle(fill: Theme.field, flexible: false, minHeight: 30)).disabled(!model.canSubmit)
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                    .buttonStyle(PillStyle(fill: Theme.field, flexible: false, minHeight: 30))
                Button("Save") { Task { await model.save() } }.keyboardShortcut(.defaultAction)
                    .buttonStyle(PillStyle(fill: Theme.accent, flexible: false, minHeight: 30)).disabled(!model.canSubmit)
            }
        }
        .padding(.horizontal, 22).padding(.bottom, 20).padding(.top, 30) // the title bar is transparent: leave room for its buttons
        .frame(width: 600)
        .background(Self.background)
        .environment(\.colorScheme, .dark)
        .onAppear { keyFocused = true }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .idle: EmptyView()
        case .working(let text): HStack(spacing: 6) { ProgressView().controlSize(.small); Text(text) }.font(.system(size: 12))
        case .ok(let text, let warnings):
            VStack(alignment: .leading, spacing: 4) {
                Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.positive)
                ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning) }
            }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.negative).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

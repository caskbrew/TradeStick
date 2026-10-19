import AppKit
import SwiftUI

/// "About" card: what the app is, how a trade goes through it, and where to report a bug or ask for something.
public struct AboutView: View {
    public static let repository = URL(string: "https://github.com/caskbrew/TradeStickies")!
    public static let issues = URL(string: "https://github.com/caskbrew/TradeStickies/issues/new")!

    let version: String
    let icon: NSImage?
    let onClose: () -> Void

    public init(version: String, icon: NSImage?, onClose: @escaping () -> Void) {
        self.version = version; self.icon = icon; self.onClose = onClose
    }

    static let steps: [(title: String, text: String)] = [
        ("New Stick  ⇧⌘N", "Pick the exchange, the pair and which side comes first (buy first or sell first). An empty sticker appears."),
        ("Add transactions", "Type them in (⌘B), or pull them from your exchange: Import Transaction (⇧⌘B). Importing needs a read-only API key: API Keys (⇧⌘K). Fees are counted in the cost."),
        ("Read the sticker", "The live price, the money invested, the quantity, the average rate and the profit or loss, in money and in percent. Show Transactions (⌘L) lists the history."),
        ("Make it yours", "Drag it anywhere, zoom with ⌘+ and ⌘−, Pin Window (⌘P) to keep it above other windows, Hide Window (⌘W). A hidden stick comes back from the menu-bar list."),
    ]

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Group {
                    if let icon { Image(nsImage: icon).resizable().interpolation(.high) } else { Color.clear }
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("TradeStickies").font(.system(size: 22, weight: .semibold))
                    Text("Version \(version)").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
            }
            Text("A floating sticker for every crypto trade: the live price and your profit at the average cost, always on screen. Binance and Poloniex.")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Text("How it works").font(.system(size: 13, weight: .semibold))
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.field))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.system(size: 13, weight: .medium))
                            Text(step.text).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))

            Text("Your trades stay on this Mac, API keys in the Keychain. The app talks only to the exchanges.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Link("GitHub", destination: Self.repository)
                Link("Report a bug or suggest an idea", destination: Self.issues)
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                    .buttonStyle(PillStyle(fill: Theme.field, flexible: false, minHeight: 36))
            }
            .font(.system(size: 13))
        }
        .padding(18)
        .frame(width: 480)
        .background(GlassBackground())
        .environment(\.colorScheme, .dark)
    }
}

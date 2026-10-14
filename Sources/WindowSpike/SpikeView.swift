import SwiftUI

struct SpikeView: View {
    let panel: StickerPanel
    let flags: PanelFlags
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GRAM / USDT").font(.headline)
            Text("0.05500")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            TextField("type here (focus test)", text: $text)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(flags.expanded ? "Collapse" : "Expand") { panel.setExpanded(!flags.expanded) }
                Button("Close") { panel.orderOut(nil) }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }
}

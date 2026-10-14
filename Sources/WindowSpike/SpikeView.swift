import SwiftUI

struct SpikeView: View {
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GRAM / USDT").font(.headline)
            Text("0.05500")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            TextField("type here (focus test)", text: $text)
                .textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }
}

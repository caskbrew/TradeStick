import SwiftUI

/// Colour semantics (FR-UI-8): green and red only for plus and minus; amber only for warnings.
enum Theme {
    static let positive = Color(red: 0.25, green: 0.85, blue: 0.55)
    static let negative = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let warning = Color(red: 1.0, green: 0.74, blue: 0.25)
    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let secondaryText = Color.white.opacity(0.62)
    static let divider = Color.white.opacity(0.10)
    static let field = Color.white.opacity(0.08)

    static func pnl(_ value: Decimal?) -> Color {
        guard let value else { return .white.opacity(0.5) }
        return value > 0 ? positive : value < 0 ? negative : .white.opacity(0.85)
    }

    /// One stable colour per coin name for the monogram (FR-UI-7).
    static func monogram(_ symbol: String) -> Color {
        let hash = symbol.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return Color(hue: Double(abs(hash) % 360) / 360, saturation: 0.55, brightness: 0.85)
    }
}

struct GlassBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

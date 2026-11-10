import SwiftUI

/// Colour semantics (FR-UI-8): green and red only for plus and minus; amber only for warnings.
enum Theme {
    static let positive = Color(red: 0.16, green: 0.90, blue: 0.60)
    static let negative = Color(red: 1.0, green: 0.29, blue: 0.34)
    static let warning = Color(red: 1.0, green: 0.74, blue: 0.25)
    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let secondaryText = Color(red: 0.75, green: 0.78, blue: 0.83) // light enough for small text on the glass over a bright desktop
    static let divider = Color.white.opacity(0.10)
    static let field = Color.white.opacity(0.08)
    /// Dividers inside the sticker's cards, and between the rows of the list.
    static let line = Color.white.opacity(0.16)
    static let rowLine = Color.white.opacity(0.09)
    static let dot = Color(red: 0.14, green: 0.91, blue: 0.61)
    static let pin = Color(red: 0.07, green: 0.61, blue: 1.0)

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

/// Animations that respect System Settings ▸ Accessibility ▸ Display ▸ Reduce motion (none then; the change is instant).
enum Motion {
    static func ease(_ duration: Double) -> Animation? { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeInOut(duration: duration) }
}

/// What replaces the glass when the user asked for Reduce transparency or Increase contrast: near-opaque, with a clear rim.
struct SolidGlass: View {
    var radius: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(red: 0.09, green: 0.10, blue: 0.12))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
    }
}

/// The window server draws Liquid Glass, so a picture of the view alone (the screenshot tests) shows it empty:
/// those turn this off and get the frosted stand-in.
public enum GlassStyle {
    @MainActor public static var system = true
    @MainActor static var available: Bool { if #available(macOS 26, *) { system } else { false } }
}

/// Apple's Liquid Glass where the system has it (macOS 26), the frosted material below it before that.
struct GlassBackground: View {
    var radius: CGFloat = 22
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                SolidGlass(radius: radius)
            } else if #available(macOS 26, *), GlassStyle.available {
                LiquidGlass(radius: radius)
            } else {
                frosted
            }
        }
        .allowsHitTesting(false) // a press on the glass reaches the drag area behind it
    }

    private var frosted: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    }
}

/// Liquid Glass, tinted dark so the white text stays readable over any desktop.
@available(macOS 26, *)
struct LiquidGlass: View {
    var radius: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Color.clear.glassEffect(.clear.tint(Color(red: 0.05, green: 0.07, blue: 0.09).opacity(0.3)), in: shape)
            .environment(\.controlActiveState, .key) // an inactive window is drawn as a pale paper: keep it as the active one
            .overlay(shape.fill(Color(red: 0.03, green: 0.05, blue: 0.07).opacity(0.62))) // takes the milkiness off the glass; the same in every window, active or not
    }
}

/// The sticker's own card (also the list and the form): Liquid Glass, or before macOS 26 near-opaque blue-black
/// with a rim that is lit at the top.
struct StickerGlass: View {
    var radius: CGFloat = 15
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        if reduceTransparency || contrast == .increased {
            SolidGlass(radius: radius)
        } else if #available(macOS 26, *), GlassStyle.available {
            LiquidGlass(radius: radius)
        } else {
            frosted
        }
    }

    private var frosted: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(red: 0.075, green: 0.09, blue: 0.105).opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(
                LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

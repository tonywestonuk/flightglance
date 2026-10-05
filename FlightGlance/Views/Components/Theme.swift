import SwiftUI
import UIKit

extension Color {
    /// A colour that adapts to light and dark appearance.
    init(light: UInt32, dark: UInt32, opacity: Double = 1) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light, alpha: opacity)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// App colours. Restrained: one teal accent, amber for caution, red only for problems.
/// Pairs were chosen for WCAG AA contrast against the panel backgrounds in both appearances.
enum Theme {
    static let accent = Color(light: 0x0B6E7A, dark: 0x5CCFC4)
    /// Text/icons placed on an `accent` fill.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x04201E)
    static let caution = Color(light: 0x8A5300, dark: 0xF2B544)
    static let problem = Color(light: 0xB42318, dark: 0xFF8A80)
    static let good = Color(light: 0x1C6E37, dark: 0x6FD68E)
    static let simulated = Color(light: 0x5B3FA8, dark: 0xB9A4FF)

    static let background = Color(light: 0xF2F4F6, dark: 0x05101B)
    static let card = Color(light: 0xFFFFFF, dark: 0x0E1C2B)
    static let cardBorder = Color(light: 0x000000, dark: 0xFFFFFF, opacity: 0.08)
    static let panel = Color(light: 0xF7F8FA, dark: 0x0A1624)
    static let secondaryText = Color(light: 0x4A5866, dark: 0xA3B3C2)

    static let cornerRadius: CGFloat = 16
}

/// Colours for the offline map, tuned to be calm and legible in a dim cabin.
struct MapPalette {
    var background = Color(light: 0xC8D5DF, dark: 0x040B13)
    var ocean = Color(light: 0xCADCEA, dark: 0x0A1726)
    // Globe
    var space = Color(light: 0xE4EBF1, dark: 0x02060B)
    var atmosphere = Color(light: 0x7FB9DA, dark: 0x3D8DB8, opacity: 0.55)
    var oceanLit = Color(light: 0xDCEAF4, dark: 0x0F2A42)
    var limbShade = Color(light: 0x24425C, dark: 0x000000, opacity: 0.22)
    var rim = Color(light: 0x8FB2CC, dark: 0x5E9CC4, opacity: 0.6)
    var land = Color(light: 0xF4F1EA, dark: 0x2A3B4B)
    var coast = Color(light: 0x8FA4B6, dark: 0x5A7690)
    var border = Color(light: 0xC2B49C, dark: 0x445B70)
    var graticule = Color(light: 0x5B7389, dark: 0x8FB0CC, opacity: 0.16)
    var cityDot = Color(light: 0x56636F, dark: 0x93A7B9)
    var cityText = Color(light: 0x34404B, dark: 0xB5C3D0)
    var countryText = Color(light: 0x7A6A55, dark: 0x8FA4B8)
    var waterText = Color(light: 0x4A7598, dark: 0x7FAED3)
    var halo = Color(light: 0xF8F6F1, dark: 0x0B1A29, opacity: 0.9)
    var route = Color(light: 0x4F6377, dark: 0x9BB0C4)
    var track = Color(light: 0x0B6E7A, dark: 0x5CCFC4)
    var trackHalo = Color(light: 0xFFFFFF, dark: 0x05101B, opacity: 0.75)
    var aircraft = Color(light: 0x0D2236, dark: 0xFFFFFF)
    var aircraftOutline = Color(light: 0xFFFFFF, dark: 0x0B1A29)
    var staleAircraft = Color(light: 0x7A8794, dark: 0x6D7F90)
    var accuracy = Color(light: 0x0B6E7A, dark: 0x5CCFC4, opacity: 0.18)
    var marker = Color(light: 0x0D2236, dark: 0xE9EEF3)
    var markerLabelBackground = Color(light: 0x0D2236, dark: 0xE9EEF3)
    var markerLabelText = Color(light: 0xFFFFFF, dark: 0x0B1A29)

    static let standard = MapPalette()
}

/// Card container used on the setup screen and info sheets.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.cardBorder))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }

    /// Floating control background over the map: Liquid Glass on iOS 26, material before.
    @ViewBuilder
    func floatingChrome<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Theme.cardBorder))
        }
    }
}

/// Prominent full-width button with explicit colours so its label keeps strong contrast in
/// both appearances (system prominent buttons put white text on the light-teal dark-mode tint).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .foregroundStyle(isEnabled ? Theme.onAccent : Color.secondary)
            .background(isEnabled ? Theme.accent : Color.secondary.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Small uppercase section caption.
struct Eyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Theme.secondaryText)
    }
}

import SwiftUI

/// Brand palette from `klic-assets/color.md`. Dark-first.
enum KlicColor {
    // Backgrounds / surfaces (space-indigo)
    static let background = Color(hex: 0x0E0F16)   // space-indigo-950
    static let surface = Color(hex: 0x14151F)      // space-indigo-900
    static let surfaceRaised = Color(hex: 0x282A3E) // space-indigo-800

    // Primary action / brand (punch-red) and danger (flag-red)
    static let primary = Color(hex: 0xED122B)      // punch-red-500
    static let danger = Color(hex: 0xFA052E)       // flag-red-500

    // Text
    static let textPrimary = Color(hex: 0xF0F2F4)  // bright-snow-50
    static let textMuted = Color(hex: 0x9299A0)    // slate-grey-400
    static let onPrimary = Color.white
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

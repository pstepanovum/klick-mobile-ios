import SwiftUI
import UIKit

enum KlicColor {
    // Backgrounds / surfaces — pure grayscale, adapts to color scheme
    static let background    = Color.adaptive(dark: 0x0D0D0D, light: 0xF5F5F5)
    static let surface       = Color.adaptive(dark: 0x1A1A1A, light: 0xFFFFFF)
    static let surfaceRaised = Color.adaptive(dark: 0x2D2D2D, light: 0xE5E5E5)

    // Brand accent — same in both schemes
    static let primary  = Color(hex: 0xED122B)
    static let danger   = Color(hex: 0xFA052E)

    // Text
    static let textPrimary = Color.adaptive(dark: 0xF2F2F2, light: 0x111111)
    static let textMuted   = Color.adaptive(dark: 0x878787, light: 0x666666)
    static let onPrimary   = Color.white
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: 1
        )
    }

    static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
    }
}

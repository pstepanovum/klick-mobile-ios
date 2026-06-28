import SwiftUI

final class ThemeManager: ObservableObject {
    enum Scheme: String, CaseIterable, Identifiable {
        case dark  = "Dark"
        case light = "Light"

        var id: String { rawValue }
        var colorScheme: ColorScheme { self == .dark ? .dark : .light }
    }

    @Published var scheme: Scheme {
        didSet { UserDefaults.standard.set(scheme.rawValue, forKey: "klic_theme") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "klic_theme") ?? ""
        scheme = Scheme(rawValue: saved) ?? .dark
    }
}

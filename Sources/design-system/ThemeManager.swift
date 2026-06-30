import SwiftUI

final class ThemeManager: ObservableObject {
    enum NightMode: String, CaseIterable, Identifiable {
        case system    = "System"
        case disabled  = "Disabled"
        case scheduled = "Scheduled"
        case automatic = "Automatic"

        var id: String { rawValue }

        var colorScheme: ColorScheme? {
            switch self {
            case .system, .scheduled, .automatic: return nil  // follow iOS system setting
            case .disabled: return .light                      // always light
            }
        }
    }

    @Published var nightMode: NightMode {
        didSet { UserDefaults.standard.set(nightMode.rawValue, forKey: "klic_night_mode") }
    }

    var colorScheme: ColorScheme? { nightMode.colorScheme }

    init() {
        let saved = UserDefaults.standard.string(forKey: "klic_night_mode") ?? ""
        nightMode = NightMode(rawValue: saved) ?? .system
    }
}

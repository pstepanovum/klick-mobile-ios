import SwiftUI

/// Logical icon set used across the app. The brand SVGs live in `design/icons/{Bold,Line}`
/// and are versioned with the repo. For M0 these map to SF Symbols so the UI renders and
/// tints cleanly on the dark theme; `scripts/generate-icons.sh` converts the brand SVGs into
/// an asset catalog of template images, after which `symbol` is swapped for `Image("ic_…")`.
enum KlicIcon {
    case mic, micOff
    case camera, cameraOff
    case video, phone, callEnd
    case message, send, search, user, addUser, settings, close, back

    /// SF Symbol placeholder — replace with the generated brand asset in M2.
    var symbol: String {
        switch self {
        case .mic: return "mic.fill"
        case .micOff: return "mic.slash.fill"
        case .camera: return "camera.fill"
        case .cameraOff: return "camera.slash.fill"
        case .video: return "video.fill"
        case .phone: return "phone.fill"
        case .callEnd: return "phone.down.fill"
        case .message: return "message.fill"
        case .send: return "paperplane.fill"
        case .search: return "magnifyingglass"
        case .user: return "person.fill"
        case .addUser: return "person.badge.plus"
        case .settings: return "gearshape.fill"
        case .close: return "xmark"
        case .back: return "chevron.left"
        }
    }
}

struct Icon: View {
    let icon: KlicIcon
    var size: CGFloat = 22
    var color: Color = KlicColor.textPrimary

    init(_ icon: KlicIcon, size: CGFloat = 22, color: Color = KlicColor.textPrimary) {
        self.icon = icon
        self.size = size
        self.color = color
    }

    var body: some View {
        Image(systemName: icon.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
    }
}

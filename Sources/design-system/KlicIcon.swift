import SwiftUI

enum KlicIcon {
    case mic, micOff
    case camera, cameraOff
    case video, phone, callEnd
    case message, send, search
    case user, addUser
    case settings, close, back

    // Bold variant — use for action/filled contexts (buttons, call controls).
    var bold: String {
        switch self {
        case .mic:       return "ic_bold_mic"
        case .micOff:    return "ic_bold_call_muted"
        case .camera:    return "ic_bold_camera"
        case .cameraOff: return "ic_bold_camera_slash"
        case .video:     return "ic_bold_video"
        case .phone:     return "ic_bold_phone"
        case .callEnd:   return "ic_bold_call_slash"
        case .message:   return "ic_bold_message"
        case .send:      return "ic_bold_send"
        case .search:    return "ic_bold_search"
        case .user:      return "ic_bold_user"
        case .addUser:   return "ic_bold_user_plus"
        case .settings:  return "ic_bold_setting"
        case .close:     return "ic_bold_close"
        case .back:      return "ic_bold_arrow_left"
        }
    }

    // Line variant — use for tab bar and structural/nav icons.
    var line: String {
        switch self {
        case .mic:       return "ic_line_mic"
        case .micOff:    return "ic_line_call_muted"
        case .camera:    return "ic_line_camera"
        case .cameraOff: return "ic_line_camera_slash"
        case .video:     return "ic_line_video"
        case .phone:     return "ic_line_phone"
        case .callEnd:   return "ic_line_call_slash"
        case .message:   return "ic_line_message"
        case .send:      return "ic_line_send"
        case .search:    return "ic_line_search"
        case .user:      return "ic_line_user"
        case .addUser:   return "ic_line_user_plus"
        case .settings:  return "ic_line_setting"
        case .close:     return "ic_line_close"
        case .back:      return "ic_line_arrow_left"
        }
    }
}

enum IconStyle { case bold, line }

struct Icon: View {
    let icon: KlicIcon
    var size: CGFloat = 22
    var color: Color = KlicColor.textPrimary
    var style: IconStyle = .bold

    init(_ icon: KlicIcon, size: CGFloat = 22, color: Color = KlicColor.textPrimary, style: IconStyle = .bold) {
        self.icon  = icon
        self.size  = size
        self.color = color
        self.style = style
    }

    var body: some View {
        let name = style == .bold ? icon.bold : icon.line
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}

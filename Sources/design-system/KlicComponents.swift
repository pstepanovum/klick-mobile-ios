import SwiftUI

/// Fully-rounded, flat primary button. No shadows, no strokes (per design rules).
struct PillButton: View {
    let title: String
    var fill: Color = KlicColor.primary
    var textColor: Color = KlicColor.onPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(KlicFont.headline())
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Circular in-call control (mic / camera / end). Flat, fully rounded.
struct CircleControl: View {
    let icon: KlicIcon
    var fill: Color = KlicColor.surfaceRaised
    var iconColor: Color = KlicColor.textPrimary
    var diameter: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 26, color: iconColor)
                .frame(width: diameter, height: diameter)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Checkbox with an inline "I agree to the Privacy Policy" label.
struct KlicCheckbox: View {
    @Binding var isChecked: Bool
    let onPrivacyTap: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isChecked.toggle() }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isChecked ? KlicColor.primary : Color.clear)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isChecked ? KlicColor.primary : KlicColor.textMuted.opacity(0.45),
                            lineWidth: 1.5
                        )
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(KlicColor.onPrimary)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)

            HStack(spacing: 3) {
                Text("I agree to the")
                    .font(KlicFont.caption(13))
                    .foregroundStyle(KlicColor.textMuted)
                Button("Privacy Policy") { onPrivacyTap() }
                    .font(KlicFont.caption(13))
                    .foregroundStyle(KlicColor.primary)
            }

            Spacer()
        }
    }
}

/// Flat text field on a rounded surface — no border, no outline.
struct KlicTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(KlicFont.body())
        .foregroundStyle(KlicColor.textPrimary)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(KlicColor.surface, in: Capsule())
    }
}

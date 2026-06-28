import SwiftUI

/// Circular avatar that loads a remote image, falling back to the user's initials.
struct AvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .empty: LoadingCircle()
                    default: initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: some View {
        ZStack {
            Circle().fill(KlicColor.primary.opacity(0.18))
            Text(initialsText)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(KlicColor.primary)
        }
    }

    private var initialsText: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

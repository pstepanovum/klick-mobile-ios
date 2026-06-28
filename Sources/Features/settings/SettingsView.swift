import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    appearanceSection
                    accountSection
                }
                .padding(20)
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Settings")
        }
        .tint(KlicColor.primary)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .font(KlicFont.headline())
                .foregroundStyle(KlicColor.textPrimary)
            HStack(spacing: 10) {
                ForEach(ThemeManager.Scheme.allCases) { scheme in
                    ThemeChip(
                        label: scheme.rawValue,
                        isSelected: themeManager.scheme == scheme
                    ) {
                        themeManager.scheme = scheme
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var accountSection: some View {
        VStack(spacing: 10) {
            if let user = session.currentUser {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.displayName)
                            .font(KlicFont.headline())
                            .foregroundStyle(KlicColor.textPrimary)
                        Text("@\(user.username)")
                            .font(KlicFont.caption())
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    Spacer()
                }
                .padding(18)
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            PillButton(title: "Log out", fill: KlicColor.surfaceRaised, textColor: KlicColor.textMuted) {
                session.logout()
            }
        }
    }
}

private struct ThemeChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(KlicFont.medium(14))
                .foregroundStyle(isSelected ? KlicColor.onPrimary : KlicColor.textMuted)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(
                    isSelected ? KlicColor.primary : KlicColor.surfaceRaised,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

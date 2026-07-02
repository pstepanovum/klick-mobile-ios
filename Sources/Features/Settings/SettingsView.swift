import SwiftUI
import Inject

struct SettingsView: View {
    @ObserveInjection var inject
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    profileHeader

                    // My Profile + Appearance
                    mainSection

                    // Notifications + Data and Storage (CALLS.md §8.3/§8.5)
                    dataSection

                    // Updates — own card, visually separated
                    updatesSection

                    // Privacy — own card, navigates to full page
                    privacySection

                    PillButton(title: "Log out", fill: KlicColor.surfaceRaised, textColor: KlicColor.textMuted) {
                        session.logout()
                    }
                    VStack(spacing: 6) {
                        KlicLottieView(name: "07", height: 140)
                        Text("Version \(appVersion)")
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
                .adaptiveWidth()
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Settings")
        }
        .tint(KlicColor.primary)
        .enableInjection()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // MARK: Profile header

    private var profileHeader: some View {
        NavigationLink { EditProfileView() } label: {
            VStack(spacing: 10) {
                if let user = session.currentUser {
                    AvatarView(url: user.avatarUrl, name: user.displayName, size: 80)
                    Text(user.displayName)
                        .font(KlicFont.headline())
                        .foregroundStyle(KlicColor.textPrimary)
                    CopyableUsername(username: user.username)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        .buttonStyle(.plain)
    }

    // MARK: My Profile + Appearance

    private var mainSection: some View {
        VStack(spacing: 0) {
            NavigationLink { EditProfileView() } label: {
                SettingsRow(icon: "person", title: "My Profile")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            NavigationLink { AppearanceView() } label: {
                SettingsRow(icon: "sun.max", title: "Appearance")
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Notifications + Data and Storage

    private var dataSection: some View {
        VStack(spacing: 0) {
            NavigationLink { NotificationsSettingsView() } label: {
                SettingsRow(icon: "bell", title: "Notifications")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            NavigationLink { DataStorageView() } label: {
                SettingsRow(icon: "externaldrive", title: "Data and Storage")
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Updates

    private var updatesSection: some View {
        VStack(spacing: 0) {
            NavigationLink { AppUpdateInfoView(version: appVersion) } label: {
                SettingsRow(icon: "arrow.down.circle", title: "Updates")
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Privacy

    private var privacySection: some View {
        VStack(spacing: 0) {
            NavigationLink { PrivacyView() } label: {
                SettingsRow(icon: "lock", title: "Privacy")
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Appearance page

private struct AppearanceView: View {
    @ObserveInjection var inject
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Chat Themes — placeholder, not yet implemented
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        Image(systemName: "paintbrush")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(KlicColor.primary)
                            .frame(width: 32, height: 32)
                            .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        Text("Chat Themes")
                            .font(KlicFont.body())
                            .foregroundStyle(KlicColor.textMuted)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(KlicColor.textMuted.opacity(0.4))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                // Night mode
                VStack(spacing: 0) {
                    NavigationLink { AutoNightModeView() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "moon")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(KlicColor.primary)
                                .frame(width: 32, height: 32)
                                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            Text("Auto-Night Mode")
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textPrimary)
                            Spacer()
                            Text(themeManager.nightMode.rawValue)
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textMuted)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .enableInjection()
    }
}

// MARK: - Auto-Night Mode picker

private struct AutoNightModeView: View {
    @ObserveInjection var inject
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(ThemeManager.NightMode.allCases.enumerated()), id: \.element.id) { idx, mode in
                    Button {
                        themeManager.nightMode = mode
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.rawValue)
                                    .font(KlicFont.body())
                                    .foregroundStyle(KlicColor.textPrimary)
                                if let subtitle = mode.subtitle {
                                    Text(subtitle)
                                        .font(KlicFont.caption(12))
                                        .foregroundStyle(KlicColor.textMuted)
                                }
                            }
                            Spacer()
                            if themeManager.nightMode == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(KlicColor.primary)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if idx < ThemeManager.NightMode.allCases.count - 1 {
                        Divider().padding(.leading, 20).opacity(0.4)
                    }
                }
            }
            .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Auto-Night Mode")
        .navigationBarTitleDisplayMode(.inline)
        .enableInjection()
    }
}

// MARK: - Updates info page

private struct AppUpdateInfoView: View {
    let version: String

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // App icon + version badge
                VStack(spacing: 12) {
                    Image(systemName: "app.badge")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(KlicColor.primary)
                    Text("Klic \(version)")
                        .font(KlicFont.headline())
                        .foregroundStyle(KlicColor.textPrimary)
                    Text("You're on the latest version")
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                // Info rows
                VStack(spacing: 0) {
                    infoRow(label: "Version", value: version)
                    Divider().padding(.leading, 20).opacity(0.4)
                    infoRow(label: "Platform", value: "iOS")
                    Divider().padding(.leading, 20).opacity(0.4)
                    infoRow(label: "Distribution", value: "TestFlight")
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                Text("iOS updates are delivered via TestFlight. Android users can update directly from Settings → App updates.")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Updates")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
            Spacer()
            Text(value)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

// MARK: - Privacy page

private struct PrivacyView: View {
    @EnvironmentObject var session: AppSession
    @State private var showLastSeen = true
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 0) {
                    Toggle(isOn: $showLastSeen) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Last seen")
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textPrimary)
                            Text("If turned off, you won't see anyone else's last seen.")
                                .font(KlicFont.caption(12))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                    }
                    .tint(KlicColor.primary)
                    .disabled(saving)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .onChange(of: showLastSeen) { _, newValue in
                        guard newValue != (session.currentUser?.showLastSeen ?? true) else { return }
                        Task { await save(newValue) }
                    }
                }
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { showLastSeen = session.currentUser?.showLastSeen ?? true }
    }

    private func save(_ value: Bool) async {
        saving = true
        defer { saving = false }
        if let user = try? await APIClient.shared.updateProfile(showLastSeen: value) {
            session.updateCurrentUser(user)
        } else {
            showLastSeen = session.currentUser?.showLastSeen ?? true
        }
    }
}

// MARK: - Shared helpers

private struct SettingsRow: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KlicColor.primary)
                .frame(width: 32, height: 32)
                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KlicColor.textMuted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

private struct CopyableUsername: View {
    let username: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = username
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.15)) { copied = false }
            }
        } label: {
            HStack(spacing: 6) {
                Text("@\(username)")
                    .font(KlicFont.caption())
                    .foregroundStyle(copied ? KlicColor.primary : KlicColor.textMuted)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? KlicColor.primary : KlicColor.textMuted.opacity(0.45))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                copied ? KlicColor.primary.opacity(0.1) : KlicColor.surfaceRaised,
                in: Capsule()
            )
            .animation(.easeInOut(duration: 0.15), value: copied)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - NightMode subtitles

private extension ThemeManager.NightMode {
    var subtitle: String? {
        switch self {
        case .system:    return "Follows your iOS appearance setting"
        case .disabled:  return "Always light"
        case .scheduled: return "Set custom day / night hours"
        case .automatic: return "Based on ambient light"
        }
    }
}

import SwiftUI

/// Settings → Notifications (CALLS.md §8.5): the four global push toggles synced via
/// GET/PUT /me/notification-prefs, the global default ringtone (what CallKit rings
/// with), and "Reset notification settings" (DELETE + local tone prefs reset).
struct NotificationsSettingsView: View {
    @State private var prefs = ChatLocalPrefs.cachedGlobalPrefs()
    @State private var loaded = false
    @State private var saving = false
    @State private var showResetConfirm = false
    @State private var ringtone = ChatLocalPrefs.globalRingtone

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                togglesCard
                ringtoneCard
                resetCard

                Text("Message, group, call and friend-request pushes are filtered server-side by these switches. Alert tones are per-device; the sound of a delivered push notification stays the system default.")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Tolerates the server not being deployed yet — falls back to the cached copy.
            if let fetched = try? await APIClient.shared.notificationPrefs() {
                prefs = fetched
                ChatLocalPrefs.cacheGlobalPrefs(fetched)
            }
            loaded = true
        }
        .confirmationDialog(
            "Reset notification settings?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { Task { await reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turns every notification back on and restores the default tones.")
        }
    }

    private var togglesCard: some View {
        VStack(spacing: 0) {
            toggleRow("Message notifications", icon: "message", value: bindingFor(\.messages))
            Divider().padding(.leading, 64).opacity(0.4)
            toggleRow("Group notifications", icon: "person.3", value: bindingFor(\.groups))
            Divider().padding(.leading, 64).opacity(0.4)
            toggleRow("Call notifications", icon: "phone", value: bindingFor(\.calls))
            Divider().padding(.leading, 64).opacity(0.4)
            toggleRow("Friend requests", icon: "person.badge.plus", value: bindingFor(\.friendRequests))
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var ringtoneCard: some View {
        VStack(spacing: 0) {
            NavigationLink {
                TonePickerView(
                    title: "Ringtone",
                    tones: KlicTone.ringtones,
                    selectedFile: ringtone
                ) { file in
                    ringtone = file
                    ChatLocalPrefs.globalRingtone = file
                    CallKitManager.shared.updateRingtone()
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(KlicColor.primary)
                        .frame(width: 32, height: 32)
                        .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Text("Ringtone")
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                    Spacer()
                    Text(KlicTone.ringtones.first(where: { $0.file == ringtone })?.name ?? "Klic")
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

    private var resetCard: some View {
        VStack(spacing: 0) {
            Button {
                showResetConfirm = true
            } label: {
                Text("Reset notification settings")
                    .font(KlicFont.body())
                    .foregroundStyle(KlicColor.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func toggleRow(_ title: String, icon: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KlicColor.primary)
                .frame(width: 32, height: 32)
                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Toggle(title, isOn: value)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
                .tint(KlicColor.primary)
                .disabled(saving)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func bindingFor(_ keyPath: WritableKeyPath<NotificationPrefs, Bool>) -> Binding<Bool> {
        Binding(
            get: { prefs[keyPath: keyPath] },
            set: { newValue in
                let previous = prefs
                prefs[keyPath: keyPath] = newValue
                ChatLocalPrefs.cacheGlobalPrefs(prefs)
                guard loaded else { return }
                Task { await push(previous: previous) }
            }
        )
    }

    private func push(previous: NotificationPrefs) async {
        saving = true
        defer { saving = false }
        do {
            let updated = try await APIClient.shared.updateNotificationPrefs(
                messages: prefs.messages, groups: prefs.groups,
                calls: prefs.calls, friendRequests: prefs.friendRequests
            )
            prefs = updated
            ChatLocalPrefs.cacheGlobalPrefs(updated)
        } catch {
            // Server unreachable / endpoint not deployed — keep the local copy, revert nothing
            // hard: the cached copy still applies to foreground gating.
            _ = previous
        }
    }

    private func reset() async {
        try? await APIClient.shared.resetNotificationPrefs()
        prefs = .defaults
        ChatLocalPrefs.cacheGlobalPrefs(.defaults)
        ChatLocalPrefs.resetAllTones()
        ringtone = ChatLocalPrefs.globalRingtone
        CallKitManager.shared.updateRingtone()
    }
}

// MARK: - Tone picker (shared with the per-chat pages)

/// Picks one of the bundled tones; plays a preview on tap.
struct TonePickerView: View {
    let title: String
    let tones: [KlicTone]
    let selectedFile: String?
    let onSelect: (String?) -> Void

    @State private var selection: String?

    init(title: String, tones: [KlicTone], selectedFile: String?, onSelect: @escaping (String?) -> Void) {
        self.title = title
        self.tones = tones
        self.selectedFile = selectedFile
        self.onSelect = onSelect
        _selection = State(initialValue: selectedFile)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(tones.enumerated()), id: \.element.id) { index, tone in
                    Button {
                        selection = tone.file
                        onSelect(tone.file)
                        tone.preview()
                    } label: {
                        HStack {
                            Text(tone.name)
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textPrimary)
                            Spacer()
                            if selection == tone.file {
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
                    if index < tones.count - 1 {
                        Divider().padding(.leading, 20).opacity(0.4)
                    }
                }
            }
            .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

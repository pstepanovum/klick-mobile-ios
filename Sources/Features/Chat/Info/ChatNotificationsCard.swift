import SwiftUI

/// Notifications section shown on BOTH chat-info pages (CALLS.md §8.4).
///
/// - Messages: mute (8 hours / 1 week / Always → PUT /conversations/:id/prefs),
///   "Mute @all mentions" (groups only), Alert tone (bundled list, LOCAL pref —
///   applies to in-app/foreground sounds; the APNs push sound stays default).
/// - Calls: mute (same durations → callsMutedUntil) and Ringtone (LOCAL pref;
///   CallKit's actual ring is the single global pick from Settings → Notifications —
///   iOS cannot vary the CallKit ringtone per chat).
struct ChatNotificationsCard: View {
    let conversationId: String
    let isGroup: Bool

    @State private var prefs = ConversationPrefs(messagesMutedUntil: nil, muteMentions: false, callsMutedUntil: nil)
    @State private var loaded = false
    @State private var muteMentions = false
    @State private var alertTone: String?
    @State private var ringtone: String?
    @State private var showMessageMuteDialog = false
    @State private var showCallMuteDialog = false

    init(conversationId: String, isGroup: Bool) {
        self.conversationId = conversationId
        self.isGroup = isGroup
        _alertTone = State(initialValue: ChatLocalPrefs.alertTone(conversationId))
        _ringtone = State(initialValue: ChatLocalPrefs.ringtone(conversationId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header("Notifications")

            // Messages
            Button {
                showMessageMuteDialog = true
            } label: {
                valueRow(icon: "message", title: "Mute messages",
                         value: ChatLocalPrefs.muteSummary(prefs.messagesMutedUntil))
            }
            .buttonStyle(.plain)

            if isGroup {
                Divider().padding(.leading, 64).opacity(0.4)
                HStack(spacing: 14) {
                    rowIcon("at")
                    Toggle("Mute @all mentions", isOn: $muteMentions)
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                        .tint(KlicColor.primary)
                        .onChange(of: muteMentions) { _, newValue in
                            guard loaded else { return }
                            Task { await push(muteMentions: newValue) }
                        }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }

            Divider().padding(.leading, 64).opacity(0.4)

            NavigationLink {
                TonePickerView(
                    title: "Alert tone",
                    tones: KlicTone.alertTones,
                    selectedFile: alertTone
                ) { file in
                    alertTone = file
                    ChatLocalPrefs.setAlertTone(file, conversationId)
                }
            } label: {
                valueRow(icon: "bell", title: "Alert tone",
                         value: KlicTone.alertTones.first(where: { $0.file == alertTone })?.name ?? "Default")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            // Calls
            Button {
                showCallMuteDialog = true
            } label: {
                valueRow(icon: "phone", title: "Mute calls",
                         value: ChatLocalPrefs.muteSummary(prefs.callsMutedUntil))
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            NavigationLink {
                TonePickerView(
                    title: "Ringtone",
                    tones: KlicTone.ringtones,
                    selectedFile: ringtone ?? ChatLocalPrefs.globalRingtone
                ) { file in
                    ringtone = file
                    ChatLocalPrefs.setRingtone(file, conversationId)
                }
            } label: {
                valueRow(icon: "bell.badge", title: "Ringtone",
                         value: KlicTone.ringtones.first(where: { $0.file == (ringtone ?? ChatLocalPrefs.globalRingtone) })?.name ?? "Klic")
            }
            .buttonStyle(.plain)

            Text("Tones are stored on this device. Delivered push notifications keep the default sound, and the incoming-call ring uses the global ringtone from Settings → Notifications.")
                .font(KlicFont.caption(11))
                .foregroundStyle(KlicColor.textMuted)
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 14)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
        .task { await load() }
        .confirmationDialog("Mute messages", isPresented: $showMessageMuteDialog, titleVisibility: .visible) {
            muteButtons { iso in Task { await push(messagesMutedUntil: iso) } }
        }
        .confirmationDialog("Mute call notifications", isPresented: $showCallMuteDialog, titleVisibility: .visible) {
            muteButtons { iso in Task { await push(callsMutedUntil: iso) } }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func muteButtons(_ apply: @escaping (String?) -> Void) -> some View {
        Button("For 8 hours") { apply(ChatLocalPrefs.isoString(Date().addingTimeInterval(8 * 3600))) }
        Button("For 1 week") { apply(ChatLocalPrefs.isoString(Date().addingTimeInterval(7 * 24 * 3600))) }
        Button("Always") { apply(ChatLocalPrefs.alwaysMutedISO) }
        Button("Unmute") { apply(nil) }
        Button("Cancel", role: .cancel) {}
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(KlicFont.headline(17))
            .foregroundStyle(KlicColor.textPrimary)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private func rowIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(KlicColor.primary)
            .frame(width: 32, height: 32)
            .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func valueRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 14) {
            rowIcon(icon)
            Text(title)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
            Spacer()
            Text(value)
                .font(KlicFont.body(14))
                .foregroundStyle(KlicColor.textMuted)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KlicColor.textMuted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Sync

    private func load() async {
        // try? — tolerate a server without the endpoint; local cache still applies.
        if let fetched = try? await APIClient.shared.conversationPrefs(conversationId: conversationId) {
            prefs = fetched
            ChatLocalPrefs.cacheMutes(conversationId, prefs: fetched)
        }
        muteMentions = prefs.muteMentions ?? false
        loaded = true
    }

    private func push(
        messagesMutedUntil: String?? = nil,
        muteMentions: Bool? = nil,
        callsMutedUntil: String?? = nil
    ) async {
        // Optimistic local update — foreground gating keeps working even when the
        // server hasn't shipped the endpoint yet.
        if let value = messagesMutedUntil { prefs.messagesMutedUntil = value }
        if let muteMentions { prefs.muteMentions = muteMentions }
        if let value = callsMutedUntil { prefs.callsMutedUntil = value }
        ChatLocalPrefs.cacheMutes(conversationId, prefs: prefs)

        if let updated = try? await APIClient.shared.updateConversationPrefs(
            conversationId: conversationId,
            messagesMutedUntil: messagesMutedUntil,
            muteMentions: muteMentions,
            callsMutedUntil: callsMutedUntil
        ) {
            prefs = updated
            self.muteMentions = updated.muteMentions ?? false
            ChatLocalPrefs.cacheMutes(conversationId, prefs: updated)
        }
    }
}

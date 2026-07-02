import SwiftUI
import Inject

/// A friend's profile: large avatar (or initials), name, @username, live presence,
/// and Audio / Video call buttons. Presence/last-seen honor the privacy setting.
struct ProfileView: View {
    @ObserveInjection var inject
    let userId: String
    let username: String
    let displayName: String
    let avatarUrl: String?
    var onCall: (String) -> Void          // "AUDIO" | "VIDEO"
    var onMessage: (() -> Void)? = nil    // shown only when provided (e.g. from Friends)
    var onInvite: (() -> Void)? = nil
    /// When opened from a chat: the direct conversation's id — unlocks the chat-info
    /// sections (media browser, starred, storage, save-to-photos, notifications; §8.4).
    var conversationId: String? = nil
    /// Chat members (incl. the current user) for sender-name resolution in those sections.
    var chatMembers: [ChatProfileTarget] = []

    @ObservedObject private var socket = SocketService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserProfile?

    private var resolvedAvatar: String? { profile?.avatarUrl ?? avatarUrl }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                AvatarView(url: resolvedAvatar, name: displayName, size: 132)
                    .padding(.top, 24)

                VStack(spacing: 6) {
                    Text(displayName)
                        .font(KlicFont.headline(24))
                        .foregroundStyle(KlicColor.textPrimary)
                    Text("@\(username)")
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textMuted)
                    if let presence = presenceText {
                        Text(presence)
                            .font(KlicFont.caption())
                            .foregroundStyle(isOnline ? KlicColor.primary : KlicColor.textMuted)
                    }
                }

                HStack(spacing: 16) {
                    CallActionButton(systemName: "phone.fill", label: "Audio") { onCall("AUDIO"); dismiss() }
                    CallActionButton(systemName: "video.fill", label: "Video") { onCall("VIDEO"); dismiss() }
                    if let onMessage {
                        CallActionButton(systemName: "message.fill", label: "Message") { onMessage(); dismiss() }
                    }
                    if let onInvite {
                        CallActionButton(systemName: "person.badge.plus.fill", label: "Invite") { onInvite(); dismiss() }
                    }
                }
                .padding(.top, 8)

                // Chat-info sections (only when reached from a conversation; §8.4).
                if let conversationId {
                    ChatInfoCommonRows(
                        conversationId: conversationId,
                        members: chatMembers.isEmpty
                            ? [ChatProfileTarget(id: userId, username: username, displayName: displayName, avatarUrl: avatarUrl)]
                            : chatMembers
                    )
                    .padding(.top, 12)

                    ChatNotificationsCard(conversationId: conversationId, isGroup: false)
                }
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task { profile = try? await APIClient.shared.userProfile(id: userId) }
        .enableInjection()
    }

    private var isOnline: Bool { socket.presence[userId]?.online == true }

    private var presenceText: String? {
        if isOnline { return "Online" }
        let live = socket.presence[userId]?.lastSeen
        let fetched = profile?.lastSeenAt.flatMap(SocketService.parseDate)
        guard let date = live ?? fetched else { return nil }
        return Self.lastSeen(date)
    }

    private static func lastSeen(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) { f.dateFormat = "HH:mm"; return "last seen today at \(f.string(from: date))" }
        if cal.isDateInYesterday(date) { f.dateFormat = "HH:mm"; return "last seen yesterday at \(f.string(from: date))" }
        f.dateFormat = "MMM d"; return "last seen \(f.string(from: date))"
    }
}

private struct CallActionButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(KlicColor.onPrimary)
                    .frame(width: 60, height: 60)
                    .background(KlicColor.primary, in: Circle())
                Text(label)
                    .font(KlicFont.caption())
                    .foregroundStyle(KlicColor.textMuted)
            }
        }
        .buttonStyle(.plain)
    }
}

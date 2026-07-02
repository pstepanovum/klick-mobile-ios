import SwiftUI

/// Tappable nav-bar title → the peer's or group's profile, with live presence/member count underneath.
extension ChatView {
    @ViewBuilder var chatHeader: some View {
        if isDirect, let peer = conversation.members.first {
            NavigationLink {
                ProfileView(
                    userId: peer.id, username: peer.username,
                    displayName: peer.displayName, avatarUrl: peer.avatarUrl,
                    onCall: { kind in Task { await startCall(kind: kind) } },
                    conversationId: conversation.id,
                    chatMembers: memberTargets
                )
            } label: {
                HStack(spacing: 8) {
                    AvatarView(url: peer.avatarUrl, name: peer.displayName, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(peer.displayName)
                            .font(KlicFont.headline(16))
                            .foregroundStyle(KlicColor.textPrimary)
                        if let sub = headerSubtitle {
                            Text(sub)
                                .font(KlicFont.caption(11))
                                .foregroundStyle(isPeerOnline ? KlicColor.primary : KlicColor.textMuted)
                        }
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .background(KlicColor.surface, in: Capsule())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                GroupInfoView(
                    conversationId: conversation.id,
                    title: title,
                    initialDetails: groupDetails,
                    fallbackMembers: memberTargets,
                    onSelectMember: { member in
                        selectedMember = member
                    },
                    onUpdated: { details in
                        groupDetails = details
                    },
                    onDeleted: {
                        dismiss()
                    },
                    onStartCall: { kind in
                        Task { await startCall(kind: kind) }
                    },
                    onSearchMessages: {
                        showMessageSearch = true
                    }
                )
            } label: {
                HStack(spacing: 8) {
                    AvatarView(url: groupAvatarUrl, name: title, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(KlicFont.headline(16))
                            .foregroundStyle(KlicColor.textPrimary)
                        if let sub = headerSubtitle {
                            Text(sub)
                                .font(KlicFont.caption(11))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .background(KlicColor.surface, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    var isPeerOnline: Bool {
        guard isDirect else { return false }
        guard let id = conversation.members.first?.id else { return false }
        return socket.presence[id]?.online == true
    }

    var headerSubtitle: String? {
        if !isDirect {
            return "\(memberCount) members"
        }
        guard let id = conversation.members.first?.id else { return nil }
        if socket.presence[id]?.online == true { return "Online" }
        guard let date = socket.presence[id]?.lastSeen else { return nil }
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) { f.dateFormat = "HH:mm"; return "last seen \(f.string(from: date))" }
        if cal.isDateInYesterday(date) { return "last seen yesterday" }
        f.dateFormat = "MMM d"; return "last seen \(f.string(from: date))"
    }
}

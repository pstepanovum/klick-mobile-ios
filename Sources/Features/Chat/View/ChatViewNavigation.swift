import SwiftUI

/// Calls, sender lookups, and cross-navigation to profiles/direct chats.
extension ChatView {
    func startCall(kind: String) async {
        guard !isStartingCall else { return }
        isStartingCall = true
        defer { isStartingCall = false }
        // Starting a call on a conversation that already has one live joins it instead —
        // the server would 409 the POST /calls with call_exists anyway.
        if !isDirect, let ongoing = activeCallInfo {
            await joinActiveCall(ongoing)
            return
        }
        guard let s = try? await APIClient.shared.startCall(conversationId: conversation.id, kind: kind)
        else { return }
        CallKitManager.shared.startOutgoing(
            s,
            peerName: title,
            peerId: isDirect ? conversation.members.first?.id : nil,
            peerAvatarUrl: isDirect ? conversation.members.first?.avatarUrl : nil,
            conversationId: conversation.id,
            isGroup: !isDirect
        )
    }

    /// Fetch the conversation's in-progress call (group chats only) — drives the "Join call"
    /// banner. Refreshed on open and on call:invite / call:end / call:participant-joined/left.
    func refreshActiveCall() async {
        guard !isDirect else { return }
        activeCallInfo = try? await APIClient.shared.activeCall(conversationId: conversation.id)
    }

    /// Late-join the ongoing group call via the token flow (same as answering, but reported
    /// to CallKit as an outgoing call — no incoming ring).
    func joinActiveCall(_ info: ActiveCallInfo) async {
        await CallKitManager.shared.joinOngoing(
            callId: info.callId,
            conversationId: conversation.id,
            title: title,
            kind: info.kind
        )
    }

    func senderDisplayName(for userId: String) -> String {
        if userId == myId {
            return session.currentUser?.displayName ?? "You"
        }
        return memberTargets.first(where: { $0.id == userId })?.displayName ?? "User"
    }

    func senderAvatarURL(for userId: String) -> String? {
        if userId == myId {
            return session.currentUser?.avatarUrl
        }
        return memberTargets.first(where: { $0.id == userId })?.avatarUrl
    }

    func replyAuthorName(for userId: String) -> String {
        userId == myId ? "You" : senderDisplayName(for: userId)
    }

    func openProfile(for userId: String) {
        guard userId != myId else { return }
        guard let member = memberTargets.first(where: { $0.id == userId }) else { return }
        selectedMember = member
    }

    func openDirectChat(with member: ChatProfileTarget) async {
        guard member.id != myId else { return }
        if let conversation = try? await APIClient.shared.openConversation(userId: member.id) {
            await MainActor.run {
                self.selectedMember = nil
                self.openedConversation = conversation
            }
        }
    }

    func startDirectCall(with member: ChatProfileTarget, kind: String) async {
        guard member.id != myId else { return }
        guard let directConversation = try? await APIClient.shared.openConversation(userId: member.id),
              let session = try? await APIClient.shared.startCall(conversationId: directConversation.id, kind: kind)
        else { return }
        CallKitManager.shared.startOutgoing(
            session,
            peerName: member.displayName,
            peerId: member.id,
            peerAvatarUrl: member.avatarUrl
        )
    }

    func sendInvite(to member: ChatProfileTarget) async {
        guard member.id != myId else { return }
        _ = try? await APIClient.shared.sendFriendRequest(userId: member.id)
    }

    func loadGroupDetails() async {
        groupDetails = try? await APIClient.shared.conversationDetails(id: conversation.id)
    }
}

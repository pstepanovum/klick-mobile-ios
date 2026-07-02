import Foundation
import SocketIO

/// Socket.io client mirroring `klic-server/src/realtime/events.ts`.
@MainActor
final class SocketService: ObservableObject {
    static let shared = SocketService()

    private var manager: SocketManager?
    private var socket: SocketIOClient?

    @Published var incomingCall: CallInvite?
    @Published var lastMessage: Message?

    /// Live presence per user id (online + last-seen, when shared).
    @Published var presence: [String: PresenceInfo] = [:]
    /// Most recent read / delivered receipt — chats apply these to their messages.
    @Published var lastRead: Receipt?
    @Published var lastDelivered: Receipt?
    /// When a peer last signalled they're typing, keyed by conversation id (cleared on stop).
    @Published var typingByConversation: [String: Date] = [:]
    /// Most recent reaction / delete events — the open chat merges these into its messages.
    @Published var lastReaction: ReactionUpdate?
    @Published var lastDeleted: DeletedUpdate?
    /// Call membership events — drive the group chat "Join call" banner and pre-join ring UX.
    @Published var lastCallParticipantJoined: CallParticipantEvent?
    @Published var lastCallParticipantLeft: CallParticipantEvent?
    @Published var lastCallEnded: CallEndedEvent?

    private var myUserId: String?
    /// Per-conversation token used to invalidate a pending typing auto-clear.
    private var typingTokens: [String: UUID] = [:]

    struct PresenceInfo: Equatable { var online: Bool; var lastSeen: Date? }
    struct Receipt: Equatable { let conversationId: String; let userId: String; let at: Date }
    struct ReactionUpdate: Equatable { let conversationId: String; let messageId: String; let reactions: [Reaction] }
    struct DeletedUpdate: Equatable { let conversationId: String; let messageId: String }
    struct CallParticipantEvent: Equatable { let callId: String; let userId: String }
    struct CallEndedEvent: Equatable { let callId: String }

    struct CallInvite: Identifiable {
        let id: String          // callId
        let conversationId: String
        let roomName: String
        let livekitUrl: String
        let kind: String
        let fromDisplayName: String
        let fromUserId: String?
        var conversationType: String?    // "DIRECT" | "GROUP"
        var conversationTitle: String?   // group title, else the caller's display name
        var participantCount: Int?
        var isGroup: Bool { conversationType == "GROUP" }
        /// What the system call UI / in-call header shows: "<Caller> · <Group title>" for groups.
        var displayTitle: String {
            guard isGroup else { return fromDisplayName }
            let title = conversationTitle?.trimmingCharacters(in: .whitespaces)
            guard let title, !title.isEmpty else { return fromDisplayName }
            return "\(fromDisplayName) · \(title)"
        }
    }

    func connect() {
        guard let token = TokenStore.accessToken else { return }
        myUserId = AccessToken.subject(of: token)
        let url = URL(string: AppConfig.socketOrigin)!
        let manager = SocketManager(socketURL: url, config: [
            .log(false),
            .compress,
            .connectParams(["token": token]),
            .extraHeaders(["Authorization": "Bearer \(token)"]),
        ])
        self.manager = manager
        let socket = manager.defaultSocket
        self.socket = socket

        socket.on("message:new") { [weak self] data, _ in
            guard let self,
                  let dict = data.first as? [String: Any],
                  let json = try? JSONSerialization.data(withJSONObject: dict),
                  let msg = try? JSONDecoder().decode(Message.self, from: json) else { return }
            // Decrypt-or-passthrough off the socket thread, then publish.
            Task { @MainActor in
                self.lastMessage = await E2eeMessaging.shared.materialize(msg)
                // Acknowledge delivery for messages from others (drives the second tick).
                if msg.senderId != self.myUserId {
                    self.emit("message:delivered", ["conversationId": msg.conversationId])
                }
            }
        }
        socket.on("presence:update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let userId = dict["userId"] as? String else { return }
            let online = dict["online"] as? Bool ?? false
            let lastSeen = (dict["lastSeen"] as? String).flatMap(Self.parseDate)
            self?.presence[userId] = PresenceInfo(online: online, lastSeen: lastSeen)
        }
        socket.on("message:read") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let conversationId = dict["conversationId"] as? String,
                  let userId = dict["userId"] as? String,
                  let at = (dict["readAt"] as? String).flatMap(Self.parseDate) else { return }
            self?.lastRead = Receipt(conversationId: conversationId, userId: userId, at: at)
        }
        socket.on("message:delivered") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let conversationId = dict["conversationId"] as? String,
                  let userId = dict["userId"] as? String,
                  let at = (dict["deliveredAt"] as? String).flatMap(Self.parseDate) else { return }
            self?.lastDelivered = Receipt(conversationId: conversationId, userId: userId, at: at)
        }
        socket.on("typing") { [weak self] data, _ in
            guard let self,
                  let dict = data.first as? [String: Any],
                  let conversationId = dict["conversationId"] as? String else { return }
            let isTyping = dict["isTyping"] as? Bool ?? false
            DispatchQueue.main.async {
                if isTyping {
                    let token = UUID()
                    self.typingTokens[conversationId] = token
                    self.typingByConversation[conversationId] = Date()
                    // Auto-clear if no further signal arrives (peer stopped without sending).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                        guard self.typingTokens[conversationId] == token else { return }
                        self.typingByConversation[conversationId] = nil
                    }
                } else {
                    self.typingTokens[conversationId] = UUID() // invalidate any pending clear
                    self.typingByConversation[conversationId] = nil
                }
            }
        }
        socket.on("message:reaction") { [weak self] data, _ in
            guard let self,
                  let dict = data.first as? [String: Any],
                  let conversationId = dict["conversationId"] as? String,
                  let messageId = dict["messageId"] as? String else { return }
            let raw = dict["reactions"] as? [[String: Any]] ?? []
            let reactions: [Reaction] = raw.compactMap { r in
                guard let emoji = r["emoji"] as? String, let count = r["count"] as? Int else { return nil }
                return Reaction(emoji: emoji, count: count, mine: r["mine"] as? Bool ?? false)
            }
            self.lastReaction = ReactionUpdate(conversationId: conversationId, messageId: messageId, reactions: reactions)
        }
        socket.on("message:deleted") { [weak self] data, _ in
            guard let self,
                  let dict = data.first as? [String: Any],
                  let conversationId = dict["conversationId"] as? String,
                  let messageId = dict["messageId"] as? String else { return }
            self.lastDeleted = DeletedUpdate(conversationId: conversationId, messageId: messageId)
        }
        socket.on("call:invite") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            let invite = CallInvite(dict: dict)
            self?.incomingCall = invite
            // Ring via the system call UI (Dynamic Island / Lock Screen).
            CallKitManager.shared.reportIncoming(invite)
        }
        socket.on("call:accept") { data, _ in
            guard let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String else { return }
            CallKitManager.shared.handlePeerAccepted(callId: callId)
        }
        socket.on("call:participant-joined") { [weak self] data, _ in
            guard let self,
                  let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String,
                  let userId = dict["userId"] as? String else { return }
            self.lastCallParticipantJoined = CallParticipantEvent(callId: callId, userId: userId)
            // Someone else's media joined — a group call is "answered" on the first join
            // (1:1 also gets call:accept). Fires on EVERY media-joined, including our own
            // echoed back and repeats after a rejoin, so it must stay idempotent.
            if userId != self.myUserId {
                CallKitManager.shared.handlePeerAccepted(callId: callId)
            }
        }
        socket.on("call:participant-left") { [weak self] data, _ in
            guard let self,
                  let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String,
                  let userId = dict["userId"] as? String else { return }
            self.lastCallParticipantLeft = CallParticipantEvent(callId: callId, userId: userId)
        }
        socket.on("call:decline") { data, _ in
            guard let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String else { return }
            CallKitManager.shared.handlePeerDeclined(callId: callId)
        }
        socket.on("call:cancel") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String else { return }
            // .unanswered → iOS shows "Missed" instead of "Unavailable" in the system call log.
            CallKitManager.shared.handleRemoteCallEnded(callId: callId, reason: .unanswered)
            self?.lastCallEnded = CallEndedEvent(callId: callId)
        }
        socket.on("call:end") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String else { return }
            CallKitManager.shared.handleRemoteCallEnded(callId: callId)
            self?.lastCallEnded = CallEndedEvent(callId: callId)
        }
        socket.connect()
    }

    func emit(_ event: String, _ payload: [String: Any]) { socket?.emit(event, payload) }
    func disconnect() { socket?.disconnect() }

    /// Parse an ISO-8601 timestamp with or without fractional seconds.
    static func parseDate(_ iso: String) -> Date? {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        return f1.date(from: iso) ?? f2.date(from: iso)
    }
}

private extension SocketService.CallInvite {
    init(dict: [String: Any]) {
        let from = dict["from"] as? [String: Any]
        self.init(
            id: dict["callId"] as? String ?? "",
            conversationId: dict["conversationId"] as? String ?? "",
            roomName: dict["roomName"] as? String ?? "",
            livekitUrl: dict["livekitUrl"] as? String ?? "",
            kind: dict["kind"] as? String ?? "AUDIO",
            fromDisplayName: from?["displayName"] as? String ?? "Unknown",
            fromUserId: from?["id"] as? String,
            conversationType: dict["conversationType"] as? String,
            conversationTitle: dict["conversationTitle"] as? String,
            participantCount: dict["participantCount"] as? Int
        )
    }
}

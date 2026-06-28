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

    private var myUserId: String?

    struct PresenceInfo: Equatable { var online: Bool; var lastSeen: Date? }
    struct Receipt: Equatable { let conversationId: String; let userId: String; let at: Date }

    struct CallInvite: Identifiable {
        let id: String          // callId
        let conversationId: String
        let roomName: String
        let livekitUrl: String
        let kind: String
        let fromDisplayName: String
        let fromUserId: String?
    }

    func connect() {
        guard let token = TokenStore.accessToken else { return }
        myUserId = AccessToken.subject(of: token)
        let url = URL(string: "https://api.89.34.230.2.sslip.io")!
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
            self.lastMessage = msg
            // Acknowledge delivery for messages from others (drives the second tick).
            if msg.senderId != self.myUserId {
                self.emit("message:delivered", ["conversationId": msg.conversationId])
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
        socket.on("call:decline") { data, _ in
            guard let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String else { return }
            CallKitManager.shared.handlePeerDeclined(callId: callId)
        }
        socket.on("call:cancel") { data, _ in
            guard let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String else { return }
            CallKitManager.shared.handleRemoteCallEnded(callId: callId)
        }
        socket.on("call:end") { data, _ in
            guard let dict = data.first as? [String: Any],
                  let callId = dict["callId"] as? String else { return }
            CallKitManager.shared.handleRemoteCallEnded(callId: callId)
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
            fromUserId: from?["id"] as? String
        )
    }
}

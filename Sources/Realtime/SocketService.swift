import Foundation
import SocketIO

/// Socket.io client mirroring `klick-server/src/realtime/events.ts`.
@MainActor
final class SocketService: ObservableObject {
    static let shared = SocketService()

    private var manager: SocketManager?
    private var socket: SocketIOClient?

    @Published var incomingCall: CallInvite?
    @Published var lastMessage: Message?

    struct CallInvite: Identifiable {
        let id: String          // callId
        let conversationId: String
        let roomName: String
        let livekitUrl: String
        let kind: String
        let fromDisplayName: String
    }

    func connect() {
        guard let token = TokenStore.accessToken else { return }
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
            guard let dict = data.first as? [String: Any],
                  let json = try? JSONSerialization.data(withJSONObject: dict),
                  let msg = try? JSONDecoder().decode(Message.self, from: json) else { return }
            self?.lastMessage = msg
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
            fromDisplayName: from?["displayName"] as? String ?? "Unknown"
        )
    }
}

import Foundation
import CallKit
import AVFoundation

/// Central call coordinator. Bridges CallKit (the system call UI shown on the Lock Screen and
/// in the Dynamic Island) with the LiveKit media session and the Live Activity.
@MainActor
final class CallKitManager: NSObject, ObservableObject {
    static let shared = CallKitManager()

    struct ActiveCall: Identifiable {
        let id: String          // callId
        let roomName: String
        let livekitUrl: String
        var token: String
        let kind: String
        let peerName: String
        var isVideo: Bool { kind == "VIDEO" }
    }

    /// When set, the app shows the in-call screen.
    @Published var activeCall: ActiveCall?

    private let provider: CXProvider
    private let controller = CXCallController()
    private var uuidToCallId: [UUID: String] = [:]
    private var callIdToUUID: [String: UUID] = [:]
    private var pendingInvites: [String: SocketService.CallInvite] = [:]

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // MARK: Incoming (from socket or VoIP push)

    func reportIncoming(_ invite: SocketService.CallInvite) {
        let uuid = uuid(for: invite.id)
        pendingInvites[invite.id] = invite
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: invite.fromDisplayName)
        update.hasVideo = invite.kind == "VIDEO"
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in }
    }

    // MARK: Outgoing (user taps call)

    func startOutgoing(_ session: CallSession, peerName: String) {
        let uuid = uuid(for: session.callId)
        activeCall = ActiveCall(
            id: session.callId, roomName: session.roomName, livekitUrl: session.livekitUrl,
            token: session.token, kind: session.kind ?? "AUDIO", peerName: peerName
        )
        let handle = CXHandle(type: .generic, value: peerName)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = session.kind == "VIDEO"
        controller.request(CXTransaction(action: action)) { _ in }
    }

    // MARK: In-call controls routed through CallKit

    func requestEnd() {
        guard let id = activeCall?.id, let uuid = callIdToUUID[id] else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
    }

    func requestSetMuted(_ muted: Bool) {
        guard let id = activeCall?.id, let uuid = callIdToUUID[id] else { return }
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted))) { _ in }
    }

    // MARK: Helpers

    private func uuid(for callId: String) -> UUID {
        if let existing = callIdToUUID[callId] { return existing }
        let uuid = UUID()
        callIdToUUID[callId] = uuid
        uuidToCallId[uuid] = callId
        return uuid
    }

    private func clear(_ callId: String) {
        if let uuid = callIdToUUID[callId] { uuidToCallId[uuid] = nil }
        callIdToUUID[callId] = nil
        pendingInvites[callId] = nil
    }
}

extension CallKitManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {}

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            guard let callId = uuidToCallId[action.uuid], let invite = pendingInvites[callId] else {
                action.fail(); return
            }
            do {
                let session = try await APIClient.shared.joinToken(callId: callId)
                activeCall = ActiveCall(
                    id: callId, roomName: invite.roomName, livekitUrl: session.livekitUrl,
                    token: session.token, kind: invite.kind, peerName: invite.fromDisplayName
                )
                await CallService.shared.join(url: session.livekitUrl, token: session.token, video: invite.kind == "VIDEO")
                CallActivityController.start(peerName: invite.fromDisplayName, isVideo: invite.kind == "VIDEO")
                CallActivityController.update(status: "Connected", muted: false, isVideo: invite.kind == "VIDEO")
                action.fulfill()
            } catch {
                action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            guard let call = activeCall else { action.fail(); return }
            await CallService.shared.join(url: call.livekitUrl, token: call.token, video: call.isVideo)
            CallActivityController.start(peerName: call.peerName, isVideo: call.isVideo)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            if let id = activeCall?.id { try? await APIClient.shared.endCall(callId: id); clear(id) }
            await CallService.shared.leave()
            CallActivityController.end()
            activeCall = nil
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            await CallService.shared.setMic(enabled: !action.isMuted)
            CallActivityController.update(
                status: "Connected", muted: action.isMuted, isVideo: activeCall?.isVideo ?? false
            )
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}

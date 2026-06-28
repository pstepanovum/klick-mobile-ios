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
        let isOutgoing: Bool
        var isVideo: Bool { kind == "VIDEO" }
    }

    /// When set, the app shows the in-call screen.
    @Published var activeCall: ActiveCall?
    @Published var statusText = "Calling..."

    private let provider: CXProvider
    private let controller = CXCallController()
    private var uuidToCallId: [UUID: String] = [:]
    private var callIdToUUID: [String: UUID] = [:]
    private var pendingInvites: [String: SocketService.CallInvite] = [:]
    private var ringTimeoutTask: Task<Void, Never>?

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
        statusText = "Calling..."
        activeCall = ActiveCall(
            id: session.callId, roomName: session.roomName, livekitUrl: session.livekitUrl,
            token: session.token, kind: session.kind ?? "AUDIO", peerName: peerName, isOutgoing: true
        )
        let handle = CXHandle(type: .generic, value: peerName)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = session.kind == "VIDEO"
        controller.request(CXTransaction(action: action)) { _ in }
        startRingTimeout(callId: session.callId)
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
        ringTimeoutTask?.cancel()
        ringTimeoutTask = nil
    }

    private func startRingTimeout(callId: String) {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            await MainActor.run {
                guard let self, self.activeCall?.id == callId, self.statusText != "Connected" else { return }
                self.statusText = "No answer"
                SocketService.shared.emit("call:cancel", ["callId": callId])
                if let uuid = self.callIdToUUID[callId] {
                    self.controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
                }
            }
        }
    }

    private func finishCall(callId: String, status: String, notifyServer: Bool, dismissAfter seconds: UInt64 = 1_500_000_000) {
        ringTimeoutTask?.cancel()
        statusText = status
        if notifyServer { Task { try? await APIClient.shared.endCall(callId: callId) } }
        if let uuid = callIdToUUID[callId] {
            provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
        Task {
            await CallService.shared.leave()
            CallActivityController.end()
            try? await Task.sleep(nanoseconds: seconds)
            await MainActor.run {
                if self.activeCall?.id == callId { self.activeCall = nil }
                self.clear(callId)
            }
        }
    }

    func handlePeerAccepted(callId: String) {
        guard activeCall?.id == callId else { return }
        ringTimeoutTask?.cancel()
        statusText = "Connected"
        CallActivityController.update(status: "Connected", muted: false, isVideo: activeCall?.isVideo ?? false)
    }

    func handlePeerDeclined(callId: String) {
        guard activeCall?.id == callId else { return }
        finishCall(callId: callId, status: "Busy", notifyServer: true)
    }

    func handleRemoteCallEnded(callId: String) {
        guard activeCall?.id == callId || pendingInvites[callId] != nil else { return }
        finishCall(callId: callId, status: "Ended", notifyServer: false, dismissAfter: 500_000_000)
    }
}

extension CallKitManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {}

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            guard let callId = uuidToCallId[action.uuid] else { action.fail(); return }
            action.fulfill()
            statusText = "Connecting..."
            do {
                // Everything needed to join comes from the token response, so answering
                // works even if the original invite is no longer in memory.
                print("CallKit answer: requesting join token for \(callId)")
                let session = try await APIClient.shared.joinToken(callId: callId)
                let invite = pendingInvites[callId]
                let kind = invite?.kind ?? session.kind ?? "AUDIO"
                let isVideo = kind == "VIDEO"
                let peerName = invite?.fromDisplayName ?? "Call"
                statusText = "Connected"
                activeCall = ActiveCall(
                    id: callId, roomName: session.roomName, livekitUrl: session.livekitUrl,
                    token: session.token, kind: kind, peerName: peerName, isOutgoing: false
                )
                try await CallService.shared.join(url: session.livekitUrl, token: session.token, video: isVideo)
                SocketService.shared.emit("call:accept", ["callId": callId])
                CallActivityController.start(peerName: peerName, isVideo: isVideo)
                CallActivityController.update(status: "Connected", muted: false, isVideo: isVideo)
            } catch {
                print("CallKit answer failed for \(callId): \(error)")
                SocketService.shared.emit("call:decline", ["callId": callId])
                finishCall(callId: callId, status: "Call failed", notifyServer: false, dismissAfter: 500_000_000)
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            guard let call = activeCall else { action.fail(); return }
            do {
                try await CallService.shared.join(url: call.livekitUrl, token: call.token, video: call.isVideo)
            } catch {
                SocketService.shared.emit("call:cancel", ["callId": call.id])
                action.fail()
                return
            }
            CallActivityController.start(peerName: call.peerName, isVideo: call.isVideo)
            CallActivityController.update(status: statusText, muted: false, isVideo: call.isVideo)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            let id = activeCall?.id ?? uuidToCallId[action.uuid]
            if let id {
                if activeCall == nil, pendingInvites[id] != nil {
                    SocketService.shared.emit("call:decline", ["callId": id])
                } else {
                    try? await APIClient.shared.endCall(callId: id)
                }
                clear(id)
            }
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

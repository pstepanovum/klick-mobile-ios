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
        var peerId: String?
        let isOutgoing: Bool
        var isVideo: Bool { kind == "VIDEO" }
    }

    /// When set, the app shows the in-call screen.
    @Published var activeCall: ActiveCall?
    @Published var statusText = "Calling..."

    private let provider: CXProvider
    private let controller = CXCallController()
    private let uuidMapDefaultsKey = "klic.callkit.uuidToCallId"
    private var uuidToCallId: [UUID: String] = [:]
    private var callIdToUUID: [String: UUID] = [:]
    private var pendingInvites: [String: SocketService.CallInvite] = [:]
    /// Ring timeouts keyed by callId — never share one task across calls, or an overlapping
    /// call clobbers the other's timeout and the abandoned call never self-cancels.
    private var ringTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var finishingCallIds = Set<String>()
    private var recentlyEndedCallIds = Set<String>()

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // MARK: Incoming (from socket or VoIP push)

    func reportIncoming(_ invite: SocketService.CallInvite) {
        APIClient.mobileDiagnostic(event: "callkit.reportIncoming", callId: invite.id, detail: invite.fromDisplayName)
        if recentlyEndedCallIds.contains(invite.id) {
            APIClient.mobileDiagnostic(event: "callkit.reportIncoming.ignoredEnded", callId: invite.id)
            return
        }
        let uuid = uuid(for: invite.id)
        if pendingInvites[invite.id] != nil {
            APIClient.mobileDiagnostic(
                event: "callkit.reportIncoming.duplicate",
                callId: invite.id,
                detail: uuid.uuidString
            )
            return
        }
        pendingInvites[invite.id] = invite
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: invite.fromDisplayName)
        update.hasVideo = invite.kind == "VIDEO"
        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                APIClient.mobileDiagnostic(
                    event: "callkit.reportIncoming.failed",
                    callId: invite.id,
                    detail: String(describing: error)
                )
            } else {
                APIClient.mobileDiagnostic(event: "callkit.reportIncoming.ok", callId: invite.id)
            }
        }
    }

    // MARK: Outgoing (user taps call)

    func startOutgoing(_ session: CallSession, peerName: String, peerId: String? = nil) {
        if activeCall != nil {
            APIClient.mobileDiagnostic(
                event: "callkit.start.ignored.activeCall",
                callId: session.callId,
                detail: peerName
            )
            Task { try? await APIClient.shared.endCall(callId: session.callId) }
            return
        }
        let uuid = uuid(for: session.callId)
        statusText = "Calling..."
        activeCall = ActiveCall(
            id: session.callId, roomName: session.roomName, livekitUrl: session.livekitUrl,
            token: session.token, kind: session.kind ?? "AUDIO", peerName: peerName,
            peerId: peerId, isOutgoing: true
        )
        let handle = CXHandle(type: .generic, value: peerName)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = session.kind == "VIDEO"
        controller.request(CXTransaction(action: action)) { _ in }
        startRingTimeout(callId: session.callId)
    }

    // MARK: In-call controls routed through CallKit

    func requestEnd() {
        guard let id = activeCall?.id else { return }
        guard let uuid = callIdToUUID[id] else {
            APIClient.mobileDiagnostic(event: "callkit.end.fallback.missingUUID", callId: id)
            finishCall(callId: id, status: "Ended", notifyServer: true, dismissAfter: 0)
            return
        }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { error in
            if let error {
                APIClient.mobileDiagnostic(
                    event: "callkit.end.request.failed",
                    callId: id,
                    detail: String(describing: error)
                )
                Task { @MainActor in
                    self.finishCall(callId: id, status: "Ended", notifyServer: true, dismissAfter: 0)
                }
            }
        }
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
        persist(callId: callId, for: uuid)
        return uuid
    }

    private func clear(_ callId: String) {
        if let uuid = callIdToUUID[callId] {
            uuidToCallId[uuid] = nil
            removePersistedCallId(for: uuid)
        }
        callIdToUUID[callId] = nil
        pendingInvites[callId] = nil
        cancelRingTimeout(callId)
    }

    private func cancelRingTimeout(_ callId: String) {
        ringTimeoutTasks[callId]?.cancel()
        ringTimeoutTasks[callId] = nil
    }

    private func cancelAllRingTimeouts() {
        for task in ringTimeoutTasks.values { task.cancel() }
        ringTimeoutTasks.removeAll()
    }

    private func callId(for uuid: UUID) -> String? {
        if let callId = uuidToCallId[uuid] { return callId }
        let fallbackCallId: String?
        if let persisted = persistedCallId(for: uuid) {
            fallbackCallId = persisted
        } else if pendingInvites.count == 1 {
            fallbackCallId = pendingInvites.keys.first
        } else if callIdToUUID.count == 1 {
            // The in-memory/persisted map was lost but we only know one call — answer it
            // rather than failing outright (CallKit hands us a UUID we must resolve).
            fallbackCallId = callIdToUUID.keys.first
        } else {
            fallbackCallId = nil
        }
        guard let callId = fallbackCallId else { return nil }
        uuidToCallId[uuid] = callId
        callIdToUUID[callId] = uuid
        persist(callId: callId, for: uuid)
        return callId
    }

    private func persist(callId: String, for uuid: UUID) {
        var map = UserDefaults.standard.dictionary(forKey: uuidMapDefaultsKey) as? [String: String] ?? [:]
        map[uuid.uuidString] = callId
        UserDefaults.standard.set(map, forKey: uuidMapDefaultsKey)
    }

    private func persistedCallId(for uuid: UUID) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: uuidMapDefaultsKey) as? [String: String]
        return map?[uuid.uuidString]
    }

    private func removePersistedCallId(for uuid: UUID) {
        var map = UserDefaults.standard.dictionary(forKey: uuidMapDefaultsKey) as? [String: String] ?? [:]
        map[uuid.uuidString] = nil
        UserDefaults.standard.set(map, forKey: uuidMapDefaultsKey)
    }

    private func endSystemCall(callId: String, reason: CXCallEndedReason = .remoteEnded) {
        guard let uuid = callIdToUUID[callId] else { return }
        APIClient.mobileDiagnostic(event: "callkit.reportEnded", callId: callId, detail: uuid.uuidString)
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
    }

    private func startRingTimeout(callId: String) {
        cancelRingTimeout(callId)
        ringTimeoutTasks[callId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            await MainActor.run {
                guard let self, self.activeCall?.id == callId, self.statusText != "Connected" else { return }
                self.statusText = "No answer"
                SocketService.shared.emit("call:cancel", ["callId": callId])
                Task { try? await APIClient.shared.endCall(callId: callId) }
                if let uuid = self.callIdToUUID[callId] {
                    self.controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
                }
            }
        }
    }

    private func finishCall(callId: String, status: String, notifyServer: Bool, dismissAfter seconds: UInt64 = 1_500_000_000) {
        guard !finishingCallIds.contains(callId) else { return }
        finishingCallIds.insert(callId)
        recentlyEndedCallIds.insert(callId)
        cancelRingTimeout(callId)
        statusText = status
        if activeCall?.id == callId {
            activeCall = nil
        }
        if notifyServer { Task { try? await APIClient.shared.endCall(callId: callId) } }
        endSystemCall(callId: callId)
        Task {
            await CallService.shared.leave()
            CallActivityController.end()
            try? await Task.sleep(nanoseconds: seconds)
            await MainActor.run {
                self.clear(callId)
                self.finishingCallIds.remove(callId)
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                    await MainActor.run { self.recentlyEndedCallIds.remove(callId) }
                }
            }
        }
    }

    /// Tear down a call we're walking away from (because we're answering a different one)
    /// without touching the shared media session / Live Activity — the call we're switching
    /// to reconfigures those itself, so doing it here would race and kill the new call's UI.
    private func endAbandonedCall(_ callId: String) {
        recentlyEndedCallIds.insert(callId)
        cancelRingTimeout(callId)
        SocketService.shared.emit("call:cancel", ["callId": callId])
        Task { try? await APIClient.shared.endCall(callId: callId) }
        endSystemCall(callId: callId)
        clear(callId)
        if activeCall?.id == callId { activeCall = nil }
    }

    func handlePeerAccepted(callId: String) {
        guard activeCall?.id == callId else { return }
        cancelRingTimeout(callId)
        statusText = "Connected"
        CallActivityController.update(status: "Connected", muted: false, isVideo: activeCall?.isVideo ?? false)
    }

    func handlePeerDeclined(callId: String) {
        guard activeCall?.id == callId else { return }
        finishCall(callId: callId, status: "Busy", notifyServer: true)
    }

    func handleRemoteCallEnded(callId: String) {
        guard activeCall?.id == callId || pendingInvites[callId] != nil || callIdToUUID[callId] != nil else { return }
        finishCall(callId: callId, status: "Ended", notifyServer: false, dismissAfter: 500_000_000)
    }

    func handleMediaPeerDisconnected(callId: String) {
        guard activeCall?.id == callId else { return }
        APIClient.mobileDiagnostic(event: "callkit.mediaPeerDisconnected.end", callId: callId)
        finishCall(callId: callId, status: "Ended", notifyServer: false, dismissAfter: 500_000_000)
    }

    func enableCameraFromSystemVideoButtonIfNeeded() {
        guard let call = activeCall,
              statusText == "Connected",
              CallService.shared.isConnected,
              !call.isVideo,
              !CallService.shared.cameraEnabled
        else { return }
        APIClient.mobileDiagnostic(event: "callkit.systemVideo.enableCamera", callId: call.id)
        Task {
            await CallService.shared.setCamera(enabled: true)
            CallActivityController.update(status: statusText, muted: !CallService.shared.micEnabled, isVideo: true)
        }
    }
}

extension CallKitManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            APIClient.mobileDiagnostic(event: "callkit.provider.reset", callId: activeCall?.id)
            cancelAllRingTimeouts()
            if let callId = activeCall?.id {
                recentlyEndedCallIds.insert(callId)
                clear(callId)
            }
            activeCall = nil
            await CallService.shared.leave()
            CallActivityController.end()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            APIClient.mobileDiagnostic(event: "callkit.answer.enter", detail: action.uuid.uuidString)
            guard let callId = callId(for: action.uuid) else {
                APIClient.mobileDiagnostic(event: "callkit.answer.missingCallId", detail: action.uuid.uuidString)
                action.fail()
                return
            }
            APIClient.mobileDiagnostic(event: "callkit.answer.fulfill", callId: callId)
            action.fulfill()
            // Answering this call means giving up any other one we had going (e.g. our own
            // outgoing call to someone else). End it server-side and in CallKit so it can't
            // linger ringing — the cause of stuck RINGING calls during overlap.
            if let other = activeCall, other.id != callId {
                APIClient.mobileDiagnostic(event: "callkit.answer.endOther", callId: other.id, detail: callId)
                endAbandonedCall(other.id)
            }
            statusText = "Connecting..."
            do {
                // Everything needed to join comes from the token response, so answering
                // works even if the original invite is no longer in memory.
                print("CallKit answer: requesting join token for \(callId)")
                APIClient.mobileDiagnostic(event: "callkit.answer.token.start", callId: callId)
                let session = try await APIClient.shared.joinToken(callId: callId)
                APIClient.mobileDiagnostic(event: "callkit.answer.token.ok", callId: callId)
                let invite = pendingInvites[callId]
                let kind = invite?.kind ?? session.kind ?? "AUDIO"
                let isVideo = kind == "VIDEO"
                let peerName = invite?.fromDisplayName ?? "Call"
                activeCall = ActiveCall(
                    id: callId, roomName: session.roomName, livekitUrl: session.livekitUrl,
                    token: session.token, kind: kind, peerName: peerName,
                    peerId: invite?.fromUserId, isOutgoing: false
                )
                APIClient.mobileDiagnostic(event: "callkit.answer.livekit.start", callId: callId)
                try await CallService.shared.join(
                    callId: callId,
                    url: session.livekitUrl,
                    token: session.token,
                    video: isVideo
                )
                statusText = "Connected"
                APIClient.mobileDiagnostic(event: "callkit.answer.livekit.ok", callId: callId)
                SocketService.shared.emit("call:accept", ["callId": callId])
                CallActivityController.start(peerName: peerName, isVideo: isVideo)
                CallActivityController.update(status: "Connected", muted: false, isVideo: isVideo)
            } catch {
                print("CallKit answer failed for \(callId): \(error)")
                APIClient.mobileDiagnostic(
                    event: "callkit.answer.failed",
                    callId: callId,
                    detail: String(describing: error)
                )
                SocketService.shared.emit("call:decline", ["callId": callId])
                finishCall(callId: callId, status: "Call failed", notifyServer: false, dismissAfter: 500_000_000)
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            guard let call = activeCall else { action.fail(); return }
            action.fulfill()
            do {
                APIClient.mobileDiagnostic(event: "callkit.start.fulfill", callId: call.id)
                try await CallService.shared.join(
                    callId: call.id,
                    url: call.livekitUrl,
                    token: call.token,
                    video: call.isVideo
                )
            } catch {
                SocketService.shared.emit("call:cancel", ["callId": call.id])
                return
            }
            CallActivityController.start(peerName: call.peerName, isVideo: call.isVideo)
            CallActivityController.update(status: statusText, muted: false, isVideo: call.isVideo)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            let id = activeCall?.id ?? callId(for: action.uuid)
            APIClient.mobileDiagnostic(event: "callkit.end.enter", callId: id, detail: action.uuid.uuidString)
            if let id {
                recentlyEndedCallIds.insert(id)
                if activeCall == nil, pendingInvites[id] != nil {
                    SocketService.shared.emit("call:decline", ["callId": id])
                } else if statusText != "Connected" {
                    SocketService.shared.emit("call:cancel", ["callId": id])
                    try? await APIClient.shared.endCall(callId: id)
                } else {
                    SocketService.shared.emit("call:end", ["callId": id])
                    try? await APIClient.shared.endCall(callId: id)
                }
                endSystemCall(callId: id)
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

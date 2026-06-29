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
        // Custom incoming-call ringtone (bundled CallKit-compatible sound). CallKit plays this
        // for incoming calls; falls back to the system ringtone if the resource is missing.
        config.ringtoneSound = "ring.caf"
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    // MARK: Incoming (from socket or VoIP push)

    func reportIncoming(_ invite: SocketService.CallInvite, completion: (() -> Void)? = nil) {
        APIClient.mobileDiagnostic(event: "callkit.reportIncoming", callId: invite.id, detail: invite.fromDisplayName)
        if recentlyEndedCallIds.contains(invite.id) {
            APIClient.mobileDiagnostic(event: "callkit.reportIncoming.ignoredEnded", callId: invite.id)
            completion?()
            return
        }
        let uuid = uuid(for: invite.id)
        if pendingInvites[invite.id] != nil {
            APIClient.mobileDiagnostic(
                event: "callkit.reportIncoming.duplicate",
                callId: invite.id,
                detail: uuid.uuidString
            )
            completion?()
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
            completion?()
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
            Task { try? await APIClient.shared.cancelCall(callId: session.callId) }
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
        } else if let single = persistedSingleCallId() {
            // A fresh process (VoIP push launched the app) has empty in-memory maps, but
            // persisted state holds exactly one call — resolve to it instead of failing.
            fallbackCallId = single
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

    /// The single persisted callId, when exactly one call is known — used to resolve a CallKit
    /// answer UUID after a cold launch where the in-memory maps are empty.
    private func persistedSingleCallId() -> String? {
        let map = UserDefaults.standard.dictionary(forKey: uuidMapDefaultsKey) as? [String: String]
        return map?.count == 1 ? map?.values.first : nil
    }

    private func persistedUUID(for callId: String) -> UUID? {
        let map = UserDefaults.standard.dictionary(forKey: uuidMapDefaultsKey) as? [String: String] ?? [:]
        return map.first(where: { $0.value == callId }).flatMap { UUID(uuidString: $0.key) }
    }

    private func restorePersistedMapping(for callId: String) {
        guard callIdToUUID[callId] == nil, let uuid = persistedUUID(for: callId) else { return }
        callIdToUUID[callId] = uuid
        uuidToCallId[uuid] = callId
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
                Task { try? await APIClient.shared.cancelCall(callId: callId) }
                if let uuid = self.callIdToUUID[callId] {
                    self.controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
                }
            }
        }
    }

    private func finishCallOnServer(callId: String, wasOutgoing: Bool, wasConnected: Bool) async {
        if wasConnected {
            try? await APIClient.shared.endCall(callId: callId)
        } else if wasOutgoing {
            try? await APIClient.shared.cancelCall(callId: callId)
        } else {
            try? await APIClient.shared.declineCall(callId: callId)
        }
    }

    private func finishCall(callId: String, status: String, notifyServer: Bool, dismissAfter seconds: UInt64 = 1_500_000_000) {
        guard !finishingCallIds.contains(callId) else { return }
        let wasOutgoing = activeCall?.id == callId ? activeCall?.isOutgoing == true : false
        let wasConnected = activeCall?.id == callId && statusText == "Connected"
        finishingCallIds.insert(callId)
        recentlyEndedCallIds.insert(callId)
        cancelRingTimeout(callId)
        statusText = status
        if activeCall?.id == callId {
            activeCall = nil
        }
        if notifyServer {
            Task { await self.finishCallOnServer(callId: callId, wasOutgoing: wasOutgoing, wasConnected: wasConnected) }
        }
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
        let wasOutgoing = activeCall?.id == callId ? activeCall?.isOutgoing == true : true
        let wasConnected = activeCall?.id == callId && statusText == "Connected"
        recentlyEndedCallIds.insert(callId)
        cancelRingTimeout(callId)
        Task { await self.finishCallOnServer(callId: callId, wasOutgoing: wasOutgoing, wasConnected: wasConnected) }
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

    /// LiveKit is re-establishing media after a network change — keep the call, show the state.
    func handleReconnecting(callId: String?) {
        guard let callId, activeCall?.id == callId, statusText == "Connected" else { return }
        statusText = "Reconnecting…"
        CallActivityController.update(
            status: "Reconnecting…",
            muted: !CallService.shared.micEnabled,
            isVideo: activeCall?.isVideo ?? false
        )
    }

    func handleReconnected(callId: String?) {
        guard let callId, activeCall?.id == callId, statusText == "Reconnecting…" else { return }
        statusText = "Connected"
        CallActivityController.update(
            status: "Connected",
            muted: !CallService.shared.micEnabled,
            isVideo: activeCall?.isVideo ?? false
        )
    }

    func handlePeerDeclined(callId: String) {
        if activeCall?.id == callId {
            finishCall(callId: callId, status: "Busy", notifyServer: false)
        } else {
            handleRemoteCallEnded(callId: callId)
        }
    }

    /// Tear down a call ended remotely. Returns true if a known call was actually dismissed,
    /// so a VoIP `call.end` push can tell whether it still needs to satisfy `mustReport`.
    @discardableResult
    func handleRemoteCallEnded(callId: String) -> Bool {
        restorePersistedMapping(for: callId)
        guard activeCall?.id == callId || pendingInvites[callId] != nil || callIdToUUID[callId] != nil else {
            return false
        }
        finishCall(callId: callId, status: "Ended", notifyServer: false, dismissAfter: 500_000_000)
        return true
    }

    /// Satisfy PushKit's `mustReport` contract for a `call.end` push that arrived with no live
    /// call to dismiss (e.g. the invite push was missed): report a call to CallKit and end it
    /// immediately. Prevents app termination on iOS 26.4+; only ever runs in that rare edge case.
    func reportEndedForCompliance(callId: String) {
        let uuid = uuid(for: callId)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: pendingInvites[callId]?.fromDisplayName ?? "Call")
        recentlyEndedCallIds.insert(callId)
        APIClient.mobileDiagnostic(event: "callkit.reportEndedForCompliance", callId: callId)
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                self.clear(callId)
            }
        }
    }

    func handleMediaPeerDisconnected(callId: String) {
        guard activeCall?.id == callId else { return }
        APIClient.mobileDiagnostic(event: "callkit.mediaPeerDisconnected.end", callId: callId)
        finishCall(callId: callId, status: "Ended", notifyServer: true, dismissAfter: 500_000_000)
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
            if let call = activeCall {
                let wasConnected = statusText == "Connected"
                recentlyEndedCallIds.insert(call.id)
                await finishCallOnServer(callId: call.id, wasOutgoing: call.isOutgoing, wasConnected: wasConnected)
                clear(call.id)
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
                try await APIClient.shared.mediaJoined(callId: callId)
                statusText = "Connected"
                APIClient.mobileDiagnostic(event: "callkit.answer.livekit.ok", callId: callId)
                CallActivityController.start(peerName: peerName, isVideo: isVideo)
                CallActivityController.update(status: "Connected", muted: false, isVideo: isVideo)
            } catch {
                print("CallKit answer failed for \(callId): \(error)")
                // If the call was torn down while we were still connecting (caller hung up
                // fast, or the peer dropped), the join throws "Cancelled"/"disconnected" —
                // that's not a real failure, so clean up quietly without a misleading
                // "Call failed" banner or a spurious decline back to the (gone) caller.
                if recentlyEndedCallIds.contains(callId) {
                    APIClient.mobileDiagnostic(event: "callkit.answer.cancelledDuringJoin", callId: callId)
                    finishCall(callId: callId, status: "Ended", notifyServer: false, dismissAfter: 0)
                } else {
                    APIClient.mobileDiagnostic(
                        event: "callkit.answer.failed",
                        callId: callId,
                        detail: String(describing: error)
                    )
                    try? await APIClient.shared.failCall(callId: callId)
                    finishCall(callId: callId, status: "Call failed", notifyServer: false, dismissAfter: 500_000_000)
                }
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
                try await APIClient.shared.mediaJoined(callId: call.id)
            } catch {
                try? await APIClient.shared.cancelCall(callId: call.id)
                finishCall(callId: call.id, status: "Call failed", notifyServer: false, dismissAfter: 500_000_000)
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
                    try? await APIClient.shared.declineCall(callId: id)
                } else if statusText != "Connected" {
                    if activeCall?.id == id && activeCall?.isOutgoing == true {
                        try? await APIClient.shared.cancelCall(callId: id)
                    } else {
                        try? await APIClient.shared.declineCall(callId: id)
                    }
                } else {
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

    // CallKit owns activation/deactivation of the call's audio session. LiveKit's audio engine is
    // gated OFF during join until this fires, so it can't activate the session ahead of CallKit
    // (the locked-screen "Audio Session Error 802" / running-timer-but-no-audio bug). On
    // didActivate we enable the engine on the now-active session; on didDeactivate we gate it off.
    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        APIClient.mobileDiagnostic(event: "callkit.audio.didActivate")
        Task { @MainActor in CallService.shared.activateAudioSession() }
    }
    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        APIClient.mobileDiagnostic(event: "callkit.audio.didDeactivate")
        Task { @MainActor in CallService.shared.deactivateAudioSession() }
    }
}

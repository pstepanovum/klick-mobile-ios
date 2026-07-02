import Foundation
import AVFoundation
import LiveKit

/// Wraps a LiveKit room for a call: join/leave, in-call controls (mute mic, camera on/off),
/// and publishes the local video track plus a per-remote participant list for rendering
/// (one entry for a 1:1 call, several for a group call). Media is routed by the SFU.
@MainActor
final class CallService: NSObject, ObservableObject {
    static let shared = CallService()

    /// One remote member of the call, keyed by their userId (the LiveKit identity).
    struct RemoteCallParticipant: Identifiable {
        let id: String              // userId == LiveKit identity
        let name: String
        var videoTrack: VideoTrack?
        var micMuted: Bool
        var isSpeaking: Bool
        /// True while the participant dropped from the SFU and their 60s grace timer runs.
        var isInGrace: Bool
    }

    private(set) var room = Room()
    private var currentCallId: String?

    @Published private(set) var isConnected = false
    @Published private(set) var isReconnecting = false
    @Published private(set) var micEnabled = true
    @Published private(set) var cameraEnabled = false
    /// Whether call audio is routed to the loudspeaker (vs. the earpiece / a connected headset).
    @Published private(set) var speakerOn = false
    @Published private(set) var localVideoTrack: VideoTrack?
    @Published private(set) var remoteVideoTrack: VideoTrack?
    /// Remote members of the call (live from the room, plus peers inside their grace window).
    @Published private(set) var participants: [RemoteCallParticipant] = []

    /// Set while we're tearing the room down on purpose, so the resulting `.disconnected`
    /// state change isn't mistaken for a network drop that should end the call.
    private var isLeaving = false

    /// Peers that dropped from the SFU and are inside their 60s reconnect grace window,
    /// keyed by identity (userId) → last-known display name. A dropped peer NEVER ends the
    /// call directly (D1) — only its grace expiry does, and only for a 1:1 call.
    private var gracePeers: [String: String] = [:]
    private var graceTasks: [String: Task<Void, Never>] = [:]

    /// Runs while we re-enter the room after a terminal local disconnect (LiveKit's own
    /// resume gave up, e.g. WiFi→LTE with an IP change). Canceled by leave().
    private var rejoinTask: Task<Void, Never>?

    private var isGroupCall: Bool { CallKitManager.shared.activeCall?.isGroup ?? false }

    /// True once CallKit has reported the audio session active for the current call.
    /// LiveKit's audio engine stays gated off until then so it can't activate the session
    /// ahead of CallKit (the cause of the locked-screen "Audio Session Error 802").
    private var audioSessionActive = false

    /// Whether we've published the mic for the current call yet. The mic is published only after
    /// CallKit activates the session, and exactly once — `join()` and `activateAudioSession()`
    /// both call `publishMicIfReady`, whichever is ready last.
    private var micPublished = false

    /// Last audio route we applied based on whether any video is on screen. Drives automatic
    /// speaker (video) ↔ earpiece (audio-only) switching as cameras turn on/off mid-call.
    private var videoRouteActive = false

    override init() {
        super.init()
        // CallKit owns the AVAudioSession lifecycle: it calls setActive(true) on didActivate
        // and setActive(false) when the call ends. LiveKit must NOT deactivate the session
        // on its own (isAutomaticDeactivationEnabled = false), because setEngineAvailability(.none)
        // in join() would otherwise call setActive(false) on the CallKit-owned session, making
        // it impossible to re-activate from a locked-screen background context — the root cause
        // of "answered on locked screen → no audio". isAutomaticConfigurationEnabled stays true
        // so LiveKit still applies the session category/mode/options when the engine starts.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = true
        AudioManager.shared.audioSession.isAutomaticDeactivationEnabled = false
        room.add(delegate: self)
    }

    /// `rejoin` re-enters an ongoing call after a terminal disconnect: the room is force-recreated
    /// (the old one is dead), isReconnecting stays up until the loop succeeds, and the mic goes
    /// through the exact same publishMicIfReady gating — audioSessionActive is already true
    /// mid-call (CallKit never deactivated), so the publish happens right after connect.
    func join(callId: String, url: String, token: String, video: Bool, rejoin: Bool = false) async throws {
        do {
            isLeaving = false
            if !rejoin { isReconnecting = false }
            prepareRoom(callId: callId, force: rejoin)
            APIClient.mobileDiagnostic(event: "livekit.join.configure", callId: callId, detail: video ? "video" : "audio")
            // Hand LiveKit a fixed, valid session configuration instead of letting it compute
            // one on the fly — the dynamic path occasionally failed to configure on the first
            // (cold-start) call ("Audio Session Error 802"). Mode .videoChat routes to the
            // speaker, .voiceChat to the earpiece.
            AudioManager.shared.sessionConfiguration = AudioSessionConfiguration(
                category: .playAndRecord,
                categoryOptions: [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay],
                mode: video ? .videoChat : .voiceChat
            )
            // Declare the AVAudioSession CATEGORY up front (we do NOT activate it — only CallKit
            // does, via provider(didActivate:)). This is what lets a locked / cold-launch
            // (VoIP-relaunched) answer get audio: with the engine gated off below, LiveKit doesn't
            // configure the session until the engine starts, so on a cold launch CallKit has nothing
            // to activate → didActivate never fires → the mic never publishes → silent both ways.
            // Device traces confirmed it: cold-launch answers got no didActivate; warm answers did.
            try? AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: video ? .videoChat : .voiceChat,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay]
            )
            AudioManager.shared.isSpeakerOutputPreferred = video
            speakerOn = video
            videoRouteActive = video
            micPublished = false
            // Gate LiveKit's audio engine OFF during connect/publish. It's turned on only AFTER
            // the mic is published (see publishMicIfReady), so capture (input) and playout (output)
            // start together in a single engine pass. Enabling it earlier brought the engine up
            // output-only and the mic never captured → the peer couldn't hear us.
            try? AudioManager.shared.setEngineAvailability(.none)
            APIClient.mobileDiagnostic(event: "livekit.join.connect.start", callId: callId)
            try await room.connect(url: url, token: token)
            APIClient.mobileDiagnostic(event: "livekit.join.connect.ok", callId: callId)
            isConnected = true
            // Camera is video-only and doesn't touch the audio session, so publish it right away
            // (this is why a locked-screen answer showed video but no audio).
            if video {
                APIClient.mobileDiagnostic(event: "livekit.join.camera.start", callId: callId)
                try await room.localParticipant.setCamera(enabled: true)
                APIClient.mobileDiagnostic(event: "livekit.join.camera.ok", callId: callId)
            }
            cameraEnabled = video
            refreshTracks()
            // Per the LiveKit maintainer's CallKit guidance (issue #181): publish the mic only
            // once CallKit has activated the audio session — publishing it during connect (before
            // the session is active) is what left locked-screen answers silent and even delayed
            // CallKit's didActivate. If CallKit already activated, publish now; otherwise
            // activateAudioSession() does it the moment didActivate fires.
            await publishMicIfReady(callId: callId)
        } catch {
            print("CallService.join failed: \(error)")
            APIClient.mobileDiagnostic(event: "livekit.join.failed", callId: callId, detail: String(describing: error))
            throw error
        }
    }

    func setMic(enabled: Bool) async {
        do {
            try await room.localParticipant.setMicrophone(enabled: enabled)
            micEnabled = enabled
            APIClient.mobileDiagnostic(
                event: "livekit.mic.toggle.ok",
                callId: currentCallId,
                detail: "enabled=\(enabled)"
            )
        } catch {
            APIClient.mobileDiagnostic(
                event: "livekit.mic.toggle.failed",
                callId: currentCallId,
                detail: String(describing: error)
            )
        }
    }

    func setCamera(enabled: Bool) async {
        do {
            try await room.localParticipant.setCamera(enabled: enabled)
            cameraEnabled = enabled
            if !enabled {
                localVideoTrack = nil
            }
            refreshTracks()
            APIClient.mobileDiagnostic(
                event: "livekit.camera.toggle.ok",
                callId: currentCallId,
                detail: "enabled=\(enabled)"
            )
        } catch {
            APIClient.mobileDiagnostic(
                event: "livekit.camera.toggle.failed",
                callId: currentCallId,
                detail: String(describing: error)
            )
        }
    }

    func toggleMic() async { await setMic(enabled: !micEnabled) }
    func toggleCamera() async { await setCamera(enabled: !cameraEnabled) }

    /// Toggle the call audio between the loudspeaker and the earpiece/headset. Overriding the
    /// output port routes immediately; `.none` lets the system pick the preferred route (a
    /// connected Bluetooth/wired headset wins), `.speaker` forces the loudspeaker.
    func toggleSpeaker() { setSpeaker(!speakerOn) }

    func setSpeaker(_ on: Bool) {
        // isSpeakerOutputPreferred is the single source of truth — LiveKit applies it via
        // overrideOutputAudioPort internally whenever it configures or reconfigures the session
        // (including after a reconnect). Calling overrideOutputAudioPort ourselves as well would
        // double-set the route and get silently reset the next time LiveKit reconfigures, leaving
        // speakerOn out of sync with the actual routing.
        AudioManager.shared.isSpeakerOutputPreferred = on
        speakerOn = on
        APIClient.mobileDiagnostic(event: "livekit.audio.speaker", callId: currentCallId, detail: on ? "on" : "off")
    }

    /// Flip between the front and back camera mid-call.
    func switchCamera() async {
        guard let track = localVideoTrack as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else { return }
        do {
            _ = try await capturer.switchCameraPosition()
            APIClient.mobileDiagnostic(event: "livekit.camera.switch.ok", callId: currentCallId)
        } catch {
            APIClient.mobileDiagnostic(
                event: "livekit.camera.switch.failed",
                callId: currentCallId,
                detail: String(describing: error)
            )
        }
    }

    /// CallKit activated the call's audio session — now it's safe to publish the mic and run the
    /// audio engine. publishMicIfReady publishes the mic and only then enables the engine, so input
    /// and output start together (enabling the engine before the publish left the mic silent).
    func activateAudioSession() {
        audioSessionActive = true
        let callId = currentCallId
        Task { @MainActor in
            if let callId { await publishMicIfReady(callId: callId) }
        }
    }

    /// CallKit deactivated the session (call ended / interrupted) — gate the engine back off so a
    /// later publish can't activate the session before CallKit does on the next call.
    func deactivateAudioSession() {
        audioSessionActive = false
        try? AudioManager.shared.setEngineAvailability(.none)
    }

    /// Publish the mic for `callId` exactly once, and only when both the room is connected AND
    /// CallKit has activated the audio session. Called from `join()` (after connect) and from
    /// `activateAudioSession()` (on didActivate) — whichever readies last actually publishes.
    private func publishMicIfReady(callId: String) async {
        // isLeaving guard: leave() sets isLeaving before awaiting room.disconnect(), so the main
        // actor is free to run other tasks (like a CallKit didActivate) during that suspension.
        // Without this check, publishMicIfReady could run on a tearing-down room and either throw
        // or succeed — leaving a mic track published on a room that's about to be discarded.
        guard currentCallId == callId, isConnected, audioSessionActive, !micPublished, !isLeaving else { return }
        micPublished = true
        do {
            APIClient.mobileDiagnostic(event: "livekit.join.mic.start", callId: callId)
            try await room.localParticipant.setMicrophone(enabled: true)
            micEnabled = true
            APIClient.mobileDiagnostic(event: "livekit.join.mic.ok", callId: callId)
            // Engine on only NOW — with the mic published, it starts capture + playout in one pass.
            try? AudioManager.shared.setEngineAvailability(.default)
            APIClient.mobileDiagnostic(event: "livekit.audio.engineStart", callId: callId)
            refreshTracks()
        } catch {
            micPublished = false
            APIClient.mobileDiagnostic(
                event: "livekit.join.mic.failed",
                callId: callId,
                detail: String(describing: error)
            )
        }
    }

    func leave() async {
        let callId = currentCallId
        isLeaving = true
        // A user-initiated (or remote-signaled) teardown cancels any in-flight rejoin
        // attempt and all remote-drop grace timers.
        rejoinTask?.cancel()
        rejoinTask = nil
        cancelAllGrace()
        APIClient.mobileDiagnostic(event: "livekit.leave.start", callId: callId)
        await room.disconnect()
        isConnected = false
        isReconnecting = false
        localVideoTrack = nil
        remoteVideoTrack = nil
        participants = []
        currentCallId = nil
        // Reset the audio gate for the next call. Re-enable engine availability so any non-call
        // audio isn't left disabled; the next join() re-gates it off until CallKit activates.
        audioSessionActive = false
        micPublished = false
        try? AudioManager.shared.setEngineAvailability(.default)
        // Session deactivation is CallKit's responsibility (isAutomaticDeactivationEnabled = false).
        // Re-enabling the engine here lets system audio resume after the call ends.
        APIClient.mobileDiagnostic(event: "livekit.leave.ok", callId: callId)
    }

    private func prepareRoom(callId: String, force: Bool = false) {
        // Only recreate the room when switching to a different call.
        // If the room is already connecting/connected for this same callId,
        // leave it alone — recreating it would orphan the live session and
        // briefly produce two concurrent LiveKit rooms (the duplicate-video bug).
        // A rejoin forces a fresh Room: the old one is terminally disconnected.
        if force || currentCallId != callId {
            room.remove(delegate: self)
            room = Room()
            room.add(delegate: self)
        }
        currentCallId = callId
    }

    /// Recompute the tracks we render. Track accessors target LiveKit Swift SDK v2.
    private func refreshTracks() {
        localVideoTrack = room.localParticipant.videoTracks.first?.track as? VideoTrack
        remoteVideoTrack = room.remoteParticipants.values
            .flatMap { $0.videoTracks }
            .first?.track as? VideoTrack
        refreshParticipants()
        APIClient.mobileDiagnostic(
            event: "livekit.tracks.refresh",
            callId: currentCallId,
            detail: "localVideo=\(localVideoTrack != nil) remoteVideo=\(remoteVideoTrack != nil)"
        )
        updateAudioRouteForVideo()
    }

    /// Rebuild the participants array from the live room plus any peers in grace. Called on
    /// its own for mute/speaking updates (they're frequent — no diagnostics, no route change).
    private func refreshParticipants() {
        var list: [RemoteCallParticipant] = room.remoteParticipants.values.compactMap { p in
            guard let id = p.identity?.stringValue, !id.isEmpty else { return nil }
            let name = p.name?.isEmpty == false ? p.name! : (gracePeers[id] ?? "Participant")
            return RemoteCallParticipant(
                id: id,
                name: name,
                videoTrack: p.videoTracks.first?.track as? VideoTrack,
                micMuted: !p.isMicrophoneEnabled(),
                isSpeaking: p.isSpeaking,
                isInGrace: false
            )
        }
        let present = Set(list.map(\.id))
        for (id, name) in gracePeers where !present.contains(id) {
            list.append(RemoteCallParticipant(
                id: id, name: name, videoTrack: nil, micMuted: true, isSpeaking: false, isInGrace: true
            ))
        }
        participants = list.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    // MARK: Remote-drop grace (per-participant, 60s)

    /// Hold a dropped peer's spot for 60s instead of ending the call. If they reconnect
    /// (participantDidConnect with the same identity) the timer is canceled; on expiry a
    /// 1:1 call ends (server notified — outcome completed), a group call just drops the tile
    /// (the server retires the call when its last participant leaves).
    private func startGrace(identity: String, name: String, callId: String) {
        gracePeers[identity] = name
        graceTasks[identity]?.cancel()
        APIClient.mobileDiagnostic(event: "livekit.remote.grace.start", callId: callId, detail: identity)
        graceTasks[identity] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, !Task.isCancelled, self.currentCallId == callId,
                  self.gracePeers[identity] != nil else { return }
            self.gracePeers[identity] = nil
            self.graceTasks[identity] = nil
            self.refreshParticipants()
            APIClient.mobileDiagnostic(event: "livekit.remote.grace.expired", callId: callId, detail: identity)
            if !self.isGroupCall {
                CallKitManager.shared.handlePeerGraceExpired(callId: callId)
            }
        }
        // 1:1: surface the only peer's drop as "Reconnecting…" while the window runs.
        if !isGroupCall { CallKitManager.shared.handleReconnecting(callId: callId) }
    }

    private func clearGrace(identity: String) {
        graceTasks[identity]?.cancel()
        graceTasks[identity] = nil
        gracePeers[identity] = nil
    }

    private func cancelAllGrace() {
        for task in graceTasks.values { task.cancel() }
        graceTasks.removeAll()
        gracePeers.removeAll()
    }

    // MARK: Rejoin loop (local terminal disconnect)

    /// LiveKit's built-in resume gave up. Instead of ending the call (D1), fetch a fresh token
    /// and reconnect: backoff 1s/2s/4s then 8s steps, ~60s total budget. 404/409/410 on the
    /// token mean the call is already over server-side → finish quietly, no server notify.
    /// Canceled by hang-up (leave()) or a socket call:end/cancel/decline.
    private func startRejoin(callId: String) {
        guard rejoinTask == nil else { return }
        isReconnecting = true
        // The room connection is gone — any per-peer grace timers are about US, not them.
        cancelAllGrace()
        CallKitManager.shared.handleReconnecting(callId: callId)
        let wasMicMuted = !micEnabled
        let wasCameraOn = cameraEnabled
        let wasSpeakerOn = speakerOn
        APIClient.mobileDiagnostic(event: "livekit.rejoin.start", callId: callId)
        rejoinTask = Task { @MainActor [weak self] in
            defer { self?.rejoinTask = nil }
            let deadline = Date().addingTimeInterval(60)
            var delaySeconds = 1.0
            while let self, !Task.isCancelled, !self.isLeaving, self.currentCallId == callId {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                guard !Task.isCancelled, !self.isLeaving, self.currentCallId == callId else { return }
                // Fresh token — the old one died with the previous session.
                let session: CallSession
                do {
                    session = try await APIClient.shared.joinToken(callId: callId)
                } catch let APIError.server(_, status) where [404, 409, 410].contains(status) {
                    APIClient.mobileDiagnostic(event: "livekit.rejoin.callOver", callId: callId, detail: "\(status)")
                    CallKitManager.shared.handleRemoteCallEnded(callId: callId)
                    return
                } catch {
                    guard Date() < deadline else { break }
                    delaySeconds = min(delaySeconds * 2, 8)
                    continue
                }
                do {
                    // Same connect path as a first join; camera restored to the user's
                    // pre-drop state, mic re-published via publishMicIfReady (the audio
                    // session is still active — CallKit never deactivated it mid-call).
                    try await self.join(
                        callId: callId, url: session.livekitUrl, token: session.token,
                        video: wasCameraOn, rejoin: true
                    )
                    if wasMicMuted { await self.setMic(enabled: false) }
                    if self.speakerOn != wasSpeakerOn { self.setSpeaker(wasSpeakerOn) }
                    _ = try? await APIClient.shared.mediaJoined(callId: callId)
                    self.isReconnecting = false
                    APIClient.mobileDiagnostic(event: "livekit.rejoin.ok", callId: callId)
                    CallKitManager.shared.handleReconnected(callId: callId)
                    return
                } catch {
                    APIClient.mobileDiagnostic(
                        event: "livekit.rejoin.attempt.failed",
                        callId: callId,
                        detail: String(describing: error)
                    )
                    guard Date() < deadline else { break }
                    delaySeconds = min(delaySeconds * 2, 8)
                }
            }
            guard let self, !Task.isCancelled, !self.isLeaving, self.currentCallId == callId else { return }
            APIClient.mobileDiagnostic(event: "livekit.rejoin.gaveUp", callId: callId)
            CallKitManager.shared.handleRejoinGaveUp(callId: callId)
        }
    }

    /// Keep the loudspeaker on whenever any video is on screen, and fall back to the earpiece
    /// ("regular phone" mode) the moment both sides have their camera off — without a manual
    /// toggle. Only acts on a change so a user's manual speaker choice during an audio-only
    /// stretch isn't overridden until the video state actually flips.
    private func updateAudioRouteForVideo() {
        let videoActive = cameraEnabled || localVideoTrack != nil || remoteVideoTrack != nil
        guard videoActive != videoRouteActive else { return }
        videoRouteActive = videoActive
        setSpeaker(videoActive)
    }
}

extension CallService: RoomDelegate {
    // LiveKit drives reconnection automatically across network changes (e.g. WiFi↔cellular).
    // We surface it so the call survives the blip with a "Reconnecting…" status, and only end
    // the call if the connection is lost terminally (and it wasn't a user-initiated hang-up).
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor in
            APIClient.mobileDiagnostic(
                event: "livekit.connectionState",
                callId: currentCallId,
                detail: "\(oldConnectionState) -> \(connectionState)"
            )
            switch connectionState {
            case .reconnecting:
                isReconnecting = true
                CallKitManager.shared.handleReconnecting(callId: currentCallId)
            case .connected:
                isReconnecting = false
                CallKitManager.shared.handleReconnected(callId: currentCallId)
            case .disconnected:
                if !isLeaving, let callId = currentCallId {
                    // Terminal disconnect that wasn't a hang-up: LiveKit's resume gave up
                    // (e.g. WiFi→LTE with an IP change). Rejoin with a fresh token instead
                    // of ending the call (D1).
                    APIClient.mobileDiagnostic(event: "livekit.connection.lost", callId: callId)
                    startRejoin(callId: callId)
                } else {
                    isReconnecting = false
                }
            default:
                break
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            APIClient.mobileDiagnostic(event: "livekit.remote.subscribe", callId: currentCallId)
            // refreshTracks recomputes local/remote video AND re-evaluates the speaker/earpiece
            // route, so the peer turning their camera on flips us to speaker.
            refreshTracks()
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            APIClient.mobileDiagnostic(event: "livekit.remote.unsubscribe", callId: currentCallId)
            // refreshTracks recomputes video state AND re-evaluates the route, so the peer turning
            // their camera off drops us back to the earpiece ("regular phone" mode).
            refreshTracks()
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            APIClient.mobileDiagnostic(event: "livekit.remote.connect", callId: currentCallId)
            // The same identity coming back cancels their reconnect grace window.
            if let identity = participant.identity?.stringValue { clearGrace(identity: identity) }
            refreshTracks()
            if !isGroupCall, gracePeers.isEmpty {
                CallKitManager.shared.handleReconnected(callId: currentCallId)
            }
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            let callId = currentCallId
            APIClient.mobileDiagnostic(event: "livekit.remote.disconnect", callId: callId)
            // NEVER end the call here (D1) — the peer may just be switching networks. Hold
            // their tile for a 60s grace window; only its expiry acts (and only for 1:1).
            // Skip while a local rejoin runs: the whole room dropped because WE did.
            if let callId, !isLeaving, rejoinTask == nil,
               let identity = participant.identity?.stringValue, !identity.isEmpty {
                let name = participant.name?.isEmpty == false ? participant.name! : identity
                startGrace(identity: identity, name: name, callId: callId)
            }
            refreshTracks()
        }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor in refreshParticipants() }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor in refreshParticipants() }
    }
}

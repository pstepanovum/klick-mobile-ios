import Foundation
import AVFoundation
import LiveKit

/// Wraps a LiveKit room for a 1:1 call: join/leave, in-call controls (mute mic, camera on/off),
/// and publishes the local + remote video tracks for rendering. Media is routed by the SFU.
@MainActor
final class CallService: NSObject, ObservableObject {
    static let shared = CallService()

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

    /// Set while we're tearing the room down on purpose, so the resulting `.disconnected`
    /// state change isn't mistaken for a network drop that should end the call.
    private var isLeaving = false

    /// True once CallKit has reported the audio session active for the current call.
    /// LiveKit's audio engine stays gated off until then so it can't activate the session
    /// ahead of CallKit (the cause of the locked-screen "Audio Session Error 802").
    private var audioSessionActive = false

    /// Whether we've published the mic for the current call yet. The mic is published only after
    /// CallKit activates the session, and exactly once — `join()` and `activateAudioSession()`
    /// both call `publishMicIfReady`, whichever is ready last.
    private var micPublished = false

    /// Safety net for the mic publish (see `scheduleMicPublishFallback`). Canceled on `leave()`.
    private var micPublishFallbackTask: Task<Void, Never>?

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

    func join(callId: String, url: String, token: String, video: Bool) async throws {
        do {
            isLeaving = false
            isReconnecting = false
            prepareRoom(callId: callId)
            APIClient.mobileDiagnostic(event: "livekit.join.configure", callId: callId, detail: video ? "video" : "audio")
            // Hand LiveKit a fixed, valid session configuration instead of letting it compute
            // one on the fly — the dynamic path occasionally failed to configure on the first
            // (cold-start) call ("Audio Session Error 802"). Mode .videoChat routes to the
            // speaker, .voiceChat to the earpiece.
            AudioManager.shared.sessionConfiguration = AudioSessionConfiguration(
                category: .playAndRecord,
                categoryOptions: [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay],
                mode: video ? .videoChat : .voiceChat
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
            // …and if that callback is never delivered (seen on locked-screen / cold-launch
            // answers), publish the mic ourselves shortly after — see scheduleMicPublishFallback.
            scheduleMicPublishFallback(callId: callId)
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

    /// Safety net for the mic publish. The mic is normally published the instant CallKit reports the
    /// audio session active (`provider(didActivate:)` → `activateAudioSession`). On some answers —
    /// notably a locked-screen or cold-launch (VoIP-push) answer — that callback isn't delivered, so
    /// the mic is never published and the peer can't hear us (one-way audio); and because the audio
    /// session never goes active, the `audio` background mode can't keep us alive, so the app gets
    /// suspended when the screen locks and the call-teardown signals (socket `call:end`, LiveKit
    /// participant-disconnect) never arrive — leaving CallKit stuck "in a call". By the time this
    /// fires CallKit has activated the session (it does so right after the call is answered), so it's
    /// safe to mark it active and publish. No-ops if the mic is already published; canceled on leave.
    private func scheduleMicPublishFallback(callId: String) {
        micPublishFallbackTask?.cancel()
        micPublishFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled,
                  self.currentCallId == callId, self.isConnected,
                  !self.micPublished, !self.isLeaving else { return }
            APIClient.mobileDiagnostic(event: "livekit.audio.micPublishFallback", callId: callId)
            self.audioSessionActive = true
            await self.publishMicIfReady(callId: callId)
        }
    }

    func leave() async {
        let callId = currentCallId
        isLeaving = true
        micPublishFallbackTask?.cancel()
        micPublishFallbackTask = nil
        APIClient.mobileDiagnostic(event: "livekit.leave.start", callId: callId)
        await room.disconnect()
        isConnected = false
        isReconnecting = false
        localVideoTrack = nil
        remoteVideoTrack = nil
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

    private func prepareRoom(callId: String) {
        // Only recreate the room when switching to a different call.
        // If the room is already connecting/connected for this same callId,
        // leave it alone — recreating it would orphan the live session and
        // briefly produce two concurrent LiveKit rooms (the duplicate-video bug).
        if currentCallId != callId {
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
        APIClient.mobileDiagnostic(
            event: "livekit.tracks.refresh",
            callId: currentCallId,
            detail: "localVideo=\(localVideoTrack != nil) remoteVideo=\(remoteVideoTrack != nil)"
        )
        updateAudioRouteForVideo()
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
                isReconnecting = false
                if !isLeaving, let callId = currentCallId {
                    APIClient.mobileDiagnostic(event: "livekit.connection.lost", callId: callId)
                    CallKitManager.shared.handleMediaPeerDisconnected(callId: callId)
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
            refreshTracks()
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            let callId = currentCallId
            APIClient.mobileDiagnostic(event: "livekit.remote.disconnect", callId: callId)
            refreshTracks()
            if let callId {
                CallKitManager.shared.handleMediaPeerDisconnected(callId: callId)
            }
        }
    }
}

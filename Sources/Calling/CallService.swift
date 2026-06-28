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
    @Published private(set) var micEnabled = true
    @Published private(set) var cameraEnabled = false
    @Published private(set) var localVideoTrack: VideoTrack?
    @Published private(set) var remoteVideoTrack: VideoTrack?

    override init() {
        super.init()
        // Let LiveKit own the AVAudioSession lifecycle (configure → activate → start engine,
        // and deactivate on leave). Our previous manual setActive(true) raced CallKit's own
        // activation and intermittently failed with "Audio Engine Error (-3010)", so ~half of
        // answered calls connected with no audio. LiveKit sequences activation with the engine.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = true
        AudioManager.shared.audioSession.isAutomaticDeactivationEnabled = true
        room.add(delegate: self)
    }

    func join(callId: String, url: String, token: String, video: Bool) async throws {
        do {
            prepareRoom(callId: callId)
            APIClient.mobileDiagnostic(event: "livekit.join.configure", callId: callId, detail: video ? "video" : "audio")
            // Speaker for video, earpiece for audio — applied to the session LiveKit manages.
            AudioManager.shared.isSpeakerOutputPreferred = video
            APIClient.mobileDiagnostic(event: "livekit.join.connect.start", callId: callId)
            try await room.connect(url: url, token: token)
            APIClient.mobileDiagnostic(event: "livekit.join.connect.ok", callId: callId)
            APIClient.mobileDiagnostic(event: "livekit.join.mic.start", callId: callId)
            try await room.localParticipant.setMicrophone(enabled: true)
            APIClient.mobileDiagnostic(event: "livekit.join.mic.ok", callId: callId)
            if video {
                APIClient.mobileDiagnostic(event: "livekit.join.camera.start", callId: callId)
                try await room.localParticipant.setCamera(enabled: true)
                APIClient.mobileDiagnostic(event: "livekit.join.camera.ok", callId: callId)
            }
            isConnected = true
            micEnabled = true
            cameraEnabled = video
            refreshTracks()
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

    func leave() async {
        let callId = currentCallId
        APIClient.mobileDiagnostic(event: "livekit.leave.start", callId: callId)
        await room.disconnect()
        isConnected = false
        localVideoTrack = nil
        remoteVideoTrack = nil
        currentCallId = nil
        // LiveKit deactivates the session itself (isAutomaticDeactivationEnabled) once the
        // engine stops — deactivating it here too races CallKit's own teardown.
        APIClient.mobileDiagnostic(event: "livekit.leave.ok", callId: callId)
    }

    private func prepareRoom(callId: String) {
        if currentCallId != callId || room.connectionState != .disconnected {
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
    }
}

extension CallService: RoomDelegate {
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            APIClient.mobileDiagnostic(event: "livekit.remote.subscribe", callId: currentCallId)
            if let track = publication.track as? VideoTrack {
                remoteVideoTrack = track
            } else {
                refreshTracks()
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            APIClient.mobileDiagnostic(event: "livekit.remote.unsubscribe", callId: currentCallId)
            if publication.track is VideoTrack {
                remoteVideoTrack = nil
            } else {
                refreshTracks()
            }
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

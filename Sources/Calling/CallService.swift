import Foundation
import LiveKit

/// Wraps a LiveKit room for a 1:1 call: join/leave, in-call controls (mute mic, camera on/off),
/// and publishes the local + remote video tracks for rendering. Media is routed by the SFU.
@MainActor
final class CallService: NSObject, ObservableObject {
    static let shared = CallService()

    let room = Room()

    @Published private(set) var isConnected = false
    @Published private(set) var micEnabled = true
    @Published private(set) var cameraEnabled = false
    @Published private(set) var localVideoTrack: VideoTrack?
    @Published private(set) var remoteVideoTrack: VideoTrack?

    override init() {
        super.init()
        room.add(delegate: self)
    }

    func join(url: String, token: String, video: Bool) async {
        do {
            try await room.connect(url: url, token: token)
            try await room.localParticipant.setMicrophone(enabled: true)
            if video { try await room.localParticipant.setCamera(enabled: true) }
            isConnected = true
            micEnabled = true
            cameraEnabled = video
            refreshTracks()
        } catch {
            print("CallService.join failed: \(error)")
        }
    }

    func setMic(enabled: Bool) async {
        micEnabled = enabled
        try? await room.localParticipant.setMicrophone(enabled: enabled)
    }

    func setCamera(enabled: Bool) async {
        cameraEnabled = enabled
        try? await room.localParticipant.setCamera(enabled: enabled)
        refreshTracks()
    }

    func toggleMic() async { await setMic(enabled: !micEnabled) }
    func toggleCamera() async { await setCamera(enabled: !cameraEnabled) }

    func leave() async {
        await room.disconnect()
        isConnected = false
        localVideoTrack = nil
        remoteVideoTrack = nil
    }

    /// Recompute the tracks we render. Track accessors target LiveKit Swift SDK v2.
    private func refreshTracks() {
        localVideoTrack = room.localParticipant.videoTracks.first?.track as? VideoTrack
        remoteVideoTrack = room.remoteParticipants.values
            .flatMap { $0.videoTracks }
            .first?.track as? VideoTrack
    }
}

extension CallService: RoomDelegate {
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in refreshTracks() }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in refreshTracks() }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in refreshTracks() }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in refreshTracks() }
    }
}

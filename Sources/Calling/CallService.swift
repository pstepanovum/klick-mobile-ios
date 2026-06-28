import Foundation
import LiveKit

/// Wraps a LiveKit room for a 1:1 call and exposes the in-call controls
/// (mute mic, camera on/off). Media is routed by the LiveKit SFU.
@MainActor
final class CallService: ObservableObject {
    static let shared = CallService()

    let room = Room()

    @Published private(set) var isConnected = false
    @Published private(set) var micEnabled = true
    @Published private(set) var cameraEnabled = false

    /// Join a LiveKit room with a server-minted token. `video` enables the camera on join.
    func join(url: String, token: String, video: Bool) async {
        do {
            try await room.connect(url: url, token: token)
            try await room.localParticipant.setMicrophone(enabled: true)
            if video { try await room.localParticipant.setCamera(enabled: true) }
            isConnected = true
            micEnabled = true
            cameraEnabled = video
        } catch {
            print("CallService.join failed: \(error)")
        }
    }

    func toggleMic() async {
        micEnabled.toggle()
        try? await room.localParticipant.setMicrophone(enabled: micEnabled)
    }

    func toggleCamera() async {
        cameraEnabled.toggle()
        try? await room.localParticipant.setCamera(enabled: cameraEnabled)
    }

    func leave() async {
        await room.disconnect()
        isConnected = false
    }
}

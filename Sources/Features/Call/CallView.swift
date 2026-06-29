import SwiftUI

struct CallView: View {
    let call: CallKitManager.ActiveCall

    @StateObject private var service = CallService.shared
    @StateObject private var callKit = CallKitManager.shared

    var body: some View {
        ZStack {
            KlicColor.background.ignoresSafeArea()

            // Remote video fills the screen whenever a participant publishes video.
            if shouldShowVideo, let remote = service.remoteVideoTrack {
                CallVideoView(track: remote).ignoresSafeArea()
            } else {
                avatar
            }

            VStack {
                header
                Spacer()
                controls
            }
            .padding(.vertical, 56)

            // Local camera preview (picture-in-picture)
            if shouldShowVideo, service.cameraEnabled, let local = service.localVideoTrack {
                CallVideoView(track: local)
                    .frame(width: 110, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private var avatar: some View {
        VStack(spacing: 14) {
            AvatarView(
                url: call.peerId.map { APIClient.avatarURL(forUserId: $0) },
                name: call.peerName,
                size: 120
            )
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(call.peerName).font(KlicFont.title()).foregroundStyle(KlicColor.textPrimary)
            Text(callKit.statusText)
                .font(KlicFont.body()).foregroundStyle(KlicColor.textMuted)
        }
    }

    private var controls: some View {
        HStack(spacing: 24) {
            circleButton(service.micEnabled ? "mic.fill" : "mic.slash.fill") {
                Task {
                    await service.toggleMic()
                    CallActivityController.update(
                        status: callKit.statusText,
                        muted: !service.micEnabled,
                        isVideo: shouldShowVideo
                    )
                }
            }
            circleButton("phone.down.fill", fill: KlicColor.danger, iconColor: KlicColor.onPrimary, size: 72) {
                CallKitManager.shared.requestEnd()
            }
            circleButton(service.cameraEnabled ? "video.fill" : "video.slash.fill") {
                Task {
                    await service.toggleCamera()
                    CallActivityController.update(
                        status: callKit.statusText,
                        muted: !service.micEnabled,
                        isVideo: shouldShowVideo
                    )
                }
            }
            if service.cameraEnabled {
                circleButton("arrow.triangle.2.circlepath.camera") {
                    Task { await service.switchCamera() }
                }
            }
        }
    }

    // Circular in-call control using a native SF Symbol.
    private func circleButton(
        _ systemName: String,
        fill: Color = KlicColor.surfaceRaised,
        iconColor: Color = KlicColor.textPrimary,
        size: CGFloat = 64,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var shouldShowVideo: Bool {
        service.cameraEnabled || service.localVideoTrack != nil || service.remoteVideoTrack != nil
    }
}

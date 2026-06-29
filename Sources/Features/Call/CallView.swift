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
            CircleControl(icon: service.micEnabled ? .mic : .micOff) {
                Task {
                    await service.toggleMic()
                    CallActivityController.update(
                        status: callKit.statusText,
                        muted: !service.micEnabled,
                        isVideo: shouldShowVideo
                    )
                }
            }
            CircleControl(
                icon: .callEnd, fill: KlicColor.danger, iconColor: KlicColor.onPrimary, diameter: 72
            ) {
                CallKitManager.shared.requestEnd()
            }
            CircleControl(icon: service.cameraEnabled ? .camera : .cameraOff) {
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
                Button { Task { await service.switchCamera() } } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(KlicColor.textPrimary)
                        .frame(width: 64, height: 64)
                        .background(KlicColor.surfaceRaised, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var shouldShowVideo: Bool {
        service.cameraEnabled || service.localVideoTrack != nil || service.remoteVideoTrack != nil
    }
}

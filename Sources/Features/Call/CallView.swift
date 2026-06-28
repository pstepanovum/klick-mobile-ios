import SwiftUI

struct CallView: View {
    let call: CallKitManager.ActiveCall

    @StateObject private var service = CallService.shared

    var body: some View {
        ZStack {
            KlicColor.background.ignoresSafeArea()

            // Remote video fills the screen for video calls; otherwise an avatar.
            if call.isVideo, let remote = service.remoteVideoTrack {
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
            if call.isVideo, service.cameraEnabled, let local = service.localVideoTrack {
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
            Circle().fill(KlicColor.surfaceRaised).frame(width: 120, height: 120)
                .overlay(Icon(.user, size: 48, color: KlicColor.textMuted))
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(call.peerName).font(KlicFont.title()).foregroundStyle(KlicColor.textPrimary)
            Text(service.isConnected ? "Connected" : "Calling…")
                .font(KlicFont.body()).foregroundStyle(KlicColor.textMuted)
        }
    }

    private var controls: some View {
        HStack(spacing: 24) {
            CircleControl(icon: service.micEnabled ? .mic : .micOff) {
                CallKitManager.shared.requestSetMuted(service.micEnabled)
            }
            CircleControl(
                icon: .callEnd, fill: KlicColor.danger, iconColor: KlicColor.onPrimary, diameter: 72
            ) {
                CallKitManager.shared.requestEnd()
            }
            CircleControl(icon: service.cameraEnabled ? .camera : .cameraOff) {
                Task { await service.toggleCamera() }
            }
        }
    }
}

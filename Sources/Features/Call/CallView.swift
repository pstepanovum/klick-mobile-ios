import SwiftUI

struct CallView: View {
    let session: CallSession
    let peerName: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var call = CallService.shared

    var body: some View {
        ZStack {
            KlicColor.background.ignoresSafeArea()
            VStack(spacing: 16) {
                Spacer()
                Circle().fill(KlicColor.surfaceRaised).frame(width: 120, height: 120)
                    .overlay(Icon(.user, size: 48, color: KlicColor.textMuted))
                Text(peerName).font(KlicFont.title()).foregroundStyle(KlicColor.textPrimary)
                Text(call.isConnected ? "Connected" : "Calling…")
                    .font(KlicFont.body()).foregroundStyle(KlicColor.textMuted)
                Spacer()
                controls
            }
            .padding(.bottom, 48)
        }
        .task {
            await call.join(url: session.livekitUrl, token: session.token, video: session.kind == "VIDEO")
        }
    }

    private var controls: some View {
        HStack(spacing: 24) {
            CircleControl(icon: call.micEnabled ? .mic : .micOff) { Task { await call.toggleMic() } }
            CircleControl(
                icon: .callEnd, fill: KlicColor.danger, iconColor: KlicColor.onPrimary, diameter: 72
            ) {
                Task { await call.leave(); dismiss() }
            }
            CircleControl(icon: call.cameraEnabled ? .camera : .cameraOff) { Task { await call.toggleCamera() } }
        }
    }
}

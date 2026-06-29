import SwiftUI

struct CallView: View {
    let call: CallKitManager.ActiveCall

    @StateObject private var service = CallService.shared
    @StateObject private var callKit = CallKitManager.shared

    /// When true the local camera is the full-screen feed and the remote becomes the small card
    /// (tap the card or its expand button to swap, WhatsApp-style).
    @State private var localFullscreen = false
    /// Committed center of the draggable card (nil = its default top-right corner).
    @State private var cardCenter: CGPoint? = nil
    @GestureState private var dragTranslation = CGSize.zero

    private let cardSize = CGSize(width: 110, height: 160)

    var body: some View {
        GeometryReader { geo in
            // Pick which feed is full-screen and which rides in the draggable card.
            let local = service.cameraEnabled ? service.localVideoTrack : nil
            let remote = service.remoteVideoTrack
            let primaryIsLocal = localFullscreen && local != nil
            let primaryTrack = primaryIsLocal ? local : remote
            let secondaryTrack = primaryIsLocal ? remote : local

            ZStack {
                KlicColor.background.ignoresSafeArea()

                if shouldShowVideo, let primaryTrack {
                    CallVideoView(track: primaryTrack).ignoresSafeArea()
                } else {
                    avatar
                }

                VStack {
                    header
                    Spacer()
                    controls
                }
                .padding(.vertical, 56)

                // Draggable, tap-to-swap picture-in-picture card for the secondary feed.
                if shouldShowVideo, let secondaryTrack {
                    let defaultCenter = CGPoint(x: geo.size.width - cardSize.width / 2 - 16,
                                                y: cardSize.height / 2 + 80)
                    let center = cardCenter ?? defaultCenter
                    let live = CGPoint(x: center.x + dragTranslation.width,
                                       y: center.y + dragTranslation.height)
                    CallVideoView(track: secondaryTrack)
                        .frame(width: cardSize.width, height: cardSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.25), lineWidth: 1))
                        .overlay(alignment: .topLeading) {
                            Image(systemName: "arrow.up.backward.and.arrow.down.forward")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(6)
                        }
                        .shadow(radius: 8)
                        .position(live)
                        .gesture(
                            DragGesture()
                                .updating($dragTranslation) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    var c = CGPoint(x: center.x + value.translation.width,
                                                    y: center.y + value.translation.height)
                                    // Snap to the nearest side, clamp vertically to stay on screen.
                                    let halfW = cardSize.width / 2 + 16
                                    c.x = c.x < geo.size.width / 2 ? halfW : geo.size.width - halfW
                                    c.y = min(max(c.y, cardSize.height / 2 + 70),
                                              geo.size.height - cardSize.height / 2 - 70)
                                    withAnimation(.spring(response: 0.3)) { cardCenter = c }
                                }
                        )
                        .onTapGesture { withAnimation { localFullscreen.toggle() } }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Don't let the screen dim/lock while the call UI is up (matches Android's keepScreenOn).
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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
        // Over video: the name is plain white text and only the status ("Connected") gets a small
        // white pill. On a voice/avatar call, use theme colors with no pill.
        VStack(spacing: 8) {
            Text(call.peerName)
                .font(KlicFont.title())
                .foregroundStyle(shouldShowVideo ? Color.white : KlicColor.textPrimary)
            if shouldShowVideo {
                Text(callKit.statusText)
                    .font(KlicFont.caption(13))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white))
            } else {
                Text(callKit.statusText)
                    .font(KlicFont.body())
                    .foregroundStyle(KlicColor.textMuted)
            }
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
            // Speaker / earpiece toggle — most useful on a voice call (video defaults to speaker).
            if !shouldShowVideo {
                circleButton(
                    service.speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    fill: service.speakerOn ? KlicColor.primary : KlicColor.surfaceRaised,
                    iconColor: service.speakerOn ? KlicColor.onPrimary : KlicColor.textPrimary
                ) {
                    service.toggleSpeaker()
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

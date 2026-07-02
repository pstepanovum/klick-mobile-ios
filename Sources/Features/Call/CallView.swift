import SwiftUI
import LiveKit
import Inject

struct CallView: View {
    @ObserveInjection var inject
    let call: CallKitManager.ActiveCall

    @ObservedObject private var service = CallService.shared
    @ObservedObject private var callKit = CallKitManager.shared

    /// When true the local camera is the full-screen feed and the remote becomes the small card
    /// (tap the card or its expand button to swap, WhatsApp-style).
    @State private var localFullscreen = false
    /// Committed center of the draggable card (nil = its default top-right corner).
    @State private var cardCenter: CGPoint? = nil
    @GestureState private var dragTranslation = CGSize.zero

    private let cardSize = CGSize(width: 110, height: 160)

    /// 2+ remotes → group grid; 0–1 remote → today's 1:1 layout (fullscreen feed + swap card).
    private var isGrid: Bool { service.participants.count >= 2 }

    var body: some View {
        GeometryReader { geo in
            // Pick which feed is full-screen and which rides in the draggable card. The
            // fullscreen surface only ever carries video when the REMOTE side has video
            // (§7.6) — my own camera alone renders as the small preview card over the
            // themed avatar layout, never as the fullscreen "video look".
            let local = service.cameraEnabled ? service.localVideoTrack : nil
            let remote = isGrid ? nil : service.remoteVideoTrack
            let primaryIsLocal = localFullscreen && local != nil && remote != nil
            let primaryTrack = primaryIsLocal ? local : remote
            let secondaryTrack = primaryIsLocal ? remote : local

            ZStack {
                KlicColor.background.ignoresSafeArea()

                if isGrid {
                    participantGrid
                } else if let primaryTrack {
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

                // Minimize: collapse the call screen into the floating root overlay so the
                // rest of the app is browsable mid-call. UI-only — media keeps running.
                VStack {
                    HStack {
                        Button {
                            callKit.callMinimized = true
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(videoLook ? Color.white : KlicColor.textPrimary)
                                .frame(width: 38, height: 38)
                                .background(
                                    videoLook ? Color.black.opacity(0.35) : KlicColor.surfaceRaised,
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 56)

                // Draggable picture-in-picture card: in the 1:1 layout it holds the secondary
                // feed (swap on tap when both sides have video, my lone camera preview
                // otherwise); in the grid it's always the local camera preview.
                if isGrid, let local {
                    pipCard(track: local, geo: geo, allowSwap: false)
                } else if !isGrid, let secondaryTrack {
                    pipCard(track: secondaryTrack, geo: geo, allowSwap: local != nil && remote != nil)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Don't let the screen dim/lock while the call UI is up (matches Android's keepScreenOn).
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .enableInjection()
    }

    /// 2-column grid of remote participants (video tile, or avatar + name; dimmed while a
    /// participant rides out their reconnect grace window). Local preview stays in the PiP card.
    private var participantGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach(service.participants) { participant in
                    ParticipantTile(participant: participant)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 140)
            .padding(.bottom, 170)
        }
        .scrollIndicators(.hidden)
    }

    /// Draggable, side-snapping PiP card; `allowSwap` enables the 1:1 tap-to-swap behavior.
    /// The live drag renders as a pure offset from the committed position (no per-frame
    /// state writes that relayout the screen); release commits where the finger left off
    /// and springs to the edge the flick was headed for (predicted end point).
    private func pipCard(track: VideoTrack, geo: GeometryProxy, allowSwap: Bool) -> some View {
        let defaultCenter = CGPoint(x: geo.size.width - cardSize.width / 2 - 16,
                                    y: cardSize.height / 2 + 80)
        let center = cardCenter ?? defaultCenter
        return CallVideoView(track: track)
            .frame(width: cardSize.width, height: cardSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.25), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if allowSwap {
                    Image(systemName: "arrow.up.backward.and.arrow.down.forward")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(6)
                }
            }
            .shadow(radius: 8)
            .position(center)
            .offset(dragTranslation)
            .gesture(
                DragGesture()
                    .updating($dragTranslation) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        // Commit exactly where the finger let go, unanimated — the gesture
                        // state resets to .zero in this same update, so the card doesn't
                        // jump — then spring to the snapped spot on the next runloop turn.
                        let release = CGPoint(x: center.x + value.translation.width,
                                              y: center.y + value.translation.height)
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { cardCenter = release }

                        let predicted = CGPoint(x: center.x + value.predictedEndTranslation.width,
                                                y: center.y + value.predictedEndTranslation.height)
                        // Snap to the side the flick was headed for, clamp vertically.
                        var target = predicted
                        let halfW = cardSize.width / 2 + 16
                        target.x = predicted.x < geo.size.width / 2 ? halfW : geo.size.width - halfW
                        target.y = min(max(target.y, cardSize.height / 2 + 70),
                                       geo.size.height - cardSize.height / 2 - 70)
                        Task { @MainActor in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                cardCenter = target
                            }
                        }
                    }
            )
            .onTapGesture { if allowSwap { withAnimation { localFullscreen.toggle() } } }
    }

    private var avatar: some View {
        VStack(spacing: 14) {
            AvatarView(
                url: call.peerAvatarUrl ?? call.peerId.map { APIClient.avatarURL(forUserId: $0) },
                name: call.peerName,
                size: 120
            )
        }
    }

    // §7.6: with the remote video fullscreen the header disappears entirely (controls
    // remain); an "On Hold" pill still surfaces over the video. Everything else — voice
    // call, or the peer's camera off even while MY camera is on — gets the standard
    // themed layout: name + status pill in theme colors, never white-on-nothing.
    @ViewBuilder private var header: some View {
        if videoLook {
            if service.isOnHold {
                Text("On Hold")
                    .font(KlicFont.caption(13))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white))
            }
        } else {
            VStack(spacing: 8) {
                Text(call.peerName)
                    .font(KlicFont.title())
                    .foregroundStyle(KlicColor.textPrimary)
                Text(callKit.statusText)
                    .font(KlicFont.caption(13))
                    .foregroundStyle(KlicColor.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(KlicColor.surfaceRaised, in: Capsule())
            }
        }
    }

    private var controls: some View {
        // With the camera on, the switch-camera button joins the row (5 buttons) —
        // shrink sizes/spacing so everything still fits on narrow phones.
        let compact = service.cameraEnabled
        let buttonSize: CGFloat = compact ? 54 : 64
        let endSize: CGFloat = compact ? 64 : 72
        return HStack(spacing: compact ? 14 : 24) {
            circleButton(service.micEnabled ? "mic.fill" : "mic.slash.fill", size: buttonSize) {
                Task {
                    await service.toggleMic()
                    CallActivityController.update(
                        status: callKit.statusText,
                        muted: !service.micEnabled,
                        isVideo: hasAnyVideo
                    )
                }
            }
            // Speaker / earpiece toggle — shown on voice AND video calls (video auto-routes to
            // the speaker, but the user can still force the earpiece; the automatic route only
            // re-applies when the video state next flips).
            circleButton(
                service.speakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                fill: service.speakerOn ? KlicColor.primary : KlicColor.surfaceRaised,
                iconColor: service.speakerOn ? KlicColor.onPrimary : KlicColor.textPrimary,
                size: buttonSize
            ) {
                service.toggleSpeaker()
            }
            circleButton("phone.down.fill", fill: KlicColor.danger, iconColor: KlicColor.onPrimary, size: endSize) {
                CallKitManager.shared.requestEnd()
            }
            circleButton(service.cameraEnabled ? "video.fill" : "video.slash.fill", size: buttonSize) {
                Task {
                    await service.toggleCamera()
                    CallActivityController.update(
                        status: callKit.statusText,
                        muted: !service.micEnabled,
                        isVideo: hasAnyVideo
                    )
                }
            }
            if service.cameraEnabled {
                circleButton("arrow.triangle.2.circlepath.camera", size: buttonSize) {
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

    /// The "video-call look" (white chrome over the fullscreen feed) keys on REMOTE video
    /// being rendered fullscreen — NOT on the local camera state (§7.6). In the group grid
    /// the background is themed, so the themed chrome applies there too.
    private var videoLook: Bool {
        !isGrid && service.remoteVideoTrack != nil
    }

    /// Whether any video is on screen at all — only used for the Live Activity's video flag.
    private var hasAnyVideo: Bool {
        service.cameraEnabled || service.localVideoTrack != nil || service.remoteVideoTrack != nil
    }
}

/// One remote member in the group-call grid: their video, or an avatar + name fallback,
/// with a mute badge and a speaking highlight. A participant in their reconnect grace
/// window renders dimmed with a "Reconnecting…" label.
private struct ParticipantTile: View {
    let participant: CallService.RemoteCallParticipant

    var body: some View {
        ZStack {
            if let track = participant.videoTrack, !participant.isInGrace {
                CallVideoView(track: track)
            } else {
                KlicColor.surfaceRaised
                AvatarView(
                    url: APIClient.avatarURL(forUserId: participant.id),
                    name: participant.name,
                    size: 64
                )
            }
        }
        .aspectRatio(3 / 4, contentMode: .fill)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 5) {
                Text(participant.name)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if participant.micMuted {
                    Image(systemName: "mic.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(8)
        }
        .overlay {
            if participant.isInGrace {
                ZStack {
                    Color.black.opacity(0.55)
                    Text("Reconnecting…")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    participant.isSpeaking && !participant.isInGrace
                        ? KlicColor.primary : Color.white.opacity(0.15),
                    lineWidth: participant.isSpeaking && !participant.isInGrace ? 2 : 1
                )
        )
    }
}

import SwiftUI
import LiveKit

/// Floating overlay rendered at the app root while the in-call screen is minimized:
/// a small remote-video tile when the call has video, or a compact pill (peer name +
/// live timer) for a voice call. Draggable with snap-to-edge; tap restores the full
/// call screen. Pure UI — the CallKit call and LiveKit room keep running underneath.
struct MinimizedCallOverlay: View {
    let call: CallKitManager.ActiveCall

    @ObservedObject private var service = CallService.shared
    @ObservedObject private var callKit = CallKitManager.shared

    /// Committed center of the overlay (nil = default top-right corner).
    @State private var center: CGPoint? = nil
    @GestureState private var dragTranslation = CGSize.zero

    private let tileSize = CGSize(width: 120, height: 160)
    private let pillSize = CGSize(width: 210, height: 52)

    private var showsVideo: Bool { service.remoteVideoTrack != nil }
    private var contentSize: CGSize { showsVideo ? tileSize : pillSize }

    var body: some View {
        GeometryReader { geo in
            let size = contentSize
            let defaultCenter = CGPoint(x: geo.size.width - size.width / 2 - 12,
                                        y: size.height / 2 + 12)
            let committed = center ?? defaultCenter
            let live = CGPoint(x: committed.x + dragTranslation.width,
                               y: committed.y + dragTranslation.height)

            content
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .position(live)
                .gesture(
                    DragGesture()
                        .updating($dragTranslation) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            var c = CGPoint(x: committed.x + value.translation.width,
                                            y: committed.y + value.translation.height)
                            // Snap to the nearest side, clamp vertically to stay on screen.
                            let halfW = size.width / 2 + 12
                            c.x = c.x < geo.size.width / 2 ? halfW : geo.size.width - halfW
                            c.y = min(max(c.y, size.height / 2 + 12),
                                      geo.size.height - size.height / 2 - 12)
                            withAnimation(.spring(response: 0.3)) { center = c }
                        }
                )
                .onTapGesture { callKit.callMinimized = false }
        }
        // Reset the committed position when the tile/pill shape changes, so a spot
        // clamped for one size can't leave the other partly off screen.
        .onChange(of: showsVideo) { _, _ in center = nil }
    }

    @ViewBuilder private var content: some View {
        if let track = service.remoteVideoTrack {
            CallVideoView(track: track)
                .frame(width: tileSize.width, height: tileSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.25), lineWidth: 1))
        } else {
            voicePill
        }
    }

    private var voicePill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(KlicColor.read)
                .frame(width: 8, height: 8)
            Text(call.peerName)
                .font(KlicFont.caption(14))
                .foregroundStyle(KlicColor.textPrimary)
                .lineLimit(1)
            if let connectedAt = callKit.connectedAt {
                Text(connectedAt, style: .timer)
                    .font(KlicFont.caption(13))
                    .monospacedDigit()
                    .foregroundStyle(KlicColor.read)
            } else {
                Text(callKit.statusText)
                    .font(KlicFont.caption(13))
                    .foregroundStyle(KlicColor.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: pillSize.width, height: pillSize.height)
        .background(Capsule().fill(KlicColor.surfaceRaised))
        .overlay(Capsule().stroke(KlicColor.read.opacity(0.5), lineWidth: 1))
    }
}

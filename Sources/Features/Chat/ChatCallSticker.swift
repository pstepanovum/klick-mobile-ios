import SwiftUI

// MARK: - Call event (a chat record of a finished call, like Telegram/WhatsApp)

/// A centered, tappable call-log row. Tap calls the peer back with the same kind.
struct CallEventRow: View {
    let call: CallEvent
    let outgoing: Bool
    let time: String
    let onCallBack: (String) -> Void

    private var video: Bool { call.isVideo }
    private var missed: Bool { call.outcome != "completed" }

    private var title: String {
        if missed { return outgoing ? "\(video ? "Video" : "Voice") call" : "Missed \(video ? "video" : "voice") call" }
        return "\(video ? "Video" : "Voice") call"
    }
    private var detail: String {
        if !missed { return CallEventRow.duration(call.durationMs) }
        return outgoing ? "No answer" : "Tap to call back"
    }
    private var tint: Color { missed ? .red : KlicColor.primary }

    var body: some View {
        Button { onCallBack(call.kind) } label: {
            HStack(spacing: 8) {
                Image(systemName: video ? "video.fill" : "phone.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(KlicFont.medium(13))
                    .foregroundStyle(KlicColor.textPrimary)
                Text(detail)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(missed ? tint : KlicColor.textMuted)
                Text(time)
                    .font(KlicFont.caption(11))
                    .foregroundStyle(KlicColor.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(KlicColor.surfaceRaised, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    static func duration(_ ms: Int?) -> String {
        let s = max(0, (ms ?? 0) / 1000)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Sticker message

/// A sent/received sticker — rendered from the bundled SVG asset (`Stickers/<id>`).
struct StickerMessageView: View {
    let stickerId: String
    let isMine: Bool
    let time: String?

    var body: some View {
        HStack(spacing: 6) {
            if isMine { Spacer(minLength: 56) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                Image("Stickers/\(stickerId)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 124, height: 124)
                if let time {
                    Text(time)
                        .font(KlicFont.caption(11))
                        .foregroundStyle(KlicColor.textMuted)
                        .padding(.horizontal, 4)
                }
            }
            if !isMine { Spacer(minLength: 56) }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Sticker picker

/// Grid of the built-in sticker pack. Loads the catalog (ids) and renders the bundled art.
struct StickerPicker: View {
    let onPick: (String) -> Void
    @State private var stickers: [Sticker] = []

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(stickers) { sticker in
                    Button { onPick(sticker.id) } label: {
                        Image("Stickers/\(sticker.id)")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 88)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(KlicColor.surface.ignoresSafeArea())
        .task { stickers = (try? await APIClient.shared.stickers()) ?? [] }
    }
}

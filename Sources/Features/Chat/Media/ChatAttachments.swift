import SwiftUI
import QuickLook

struct MessageAttachmentsView: View {
    let attachments: [Attachment]
    let isMine: Bool
    /// Caption rendered INSIDE the media card (image/bento messages only).
    var caption: String = ""
    var showTime: Bool = false
    var time: String = ""
    var status: String? = nil
    /// Star indicator (§8.4) shown next to the time/ticks.
    var starred: Bool = false
    /// Highlight "@all" mentions in the caption (group chats).
    var highlightMentions: Bool = false
    /// Conversation context for the auto-download gate + "Save to Photos" auto-save.
    var conversationId: String = ""
    var onOpenAttachment: (Attachment) -> Void = { _ in }
    var onLongPress: () -> Void = {}

    private var media: [Attachment] { attachments.filter { $0.isImage || $0.isVideo } }
    private var others: [Attachment] { attachments.filter { !($0.isImage || $0.isVideo) } }

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
            if !media.isEmpty {
                MediaMessageCard(
                    media: media,
                    caption: caption,
                    isMine: isMine,
                    time: time,
                    status: status,
                    starred: starred,
                    highlightMentions: highlightMentions,
                    conversationId: conversationId,
                    onOpen: onOpenAttachment,
                    onLongPress: onLongPress
                )
            }
            ForEach(Array(others.enumerated()), id: \.1.id) { index, attachment in
                // Time/ticks ride on the media card when there is one; otherwise on the
                // last non-media row (same as before).
                let isTimedRow = media.isEmpty && showTime && index == others.count - 1
                switch attachment.kind {
                case "VOICE":
                    VoiceAttachmentView(
                        attachment: attachment,
                        isMine: isMine,
                        time: isTimedRow ? time : nil,
                        status: isTimedRow ? status : nil,
                        starred: isTimedRow && starred
                    )
                default:
                    FileAttachmentView(
                        attachment: attachment,
                        isMine: isMine,
                        time: isTimedRow ? time : nil,
                        status: isTimedRow ? status : nil,
                        starred: isTimedRow && starred
                    )
                }
            }
        }
    }
}

/// Small star shown on starred bubbles next to the time/ticks.
struct StarIndicator: View {
    var onPrimary: Bool = false

    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 9))
            .foregroundStyle(onPrimary ? KlicColor.onPrimary.opacity(0.8) : Color.yellow)
    }
}

// MARK: - Unified image+caption card & bento grid

/// One bubble card for a message's images/videos: bento grid on top (inner radius 4pt
/// less than the card), caption + inline time/ticks below inside the same card. Without
/// a caption the grid stands alone with a dark translucent time/ticks pill overlaid
/// bottom-right on the media.
private struct MediaMessageCard: View {
    let media: [Attachment]
    let caption: String
    let isMine: Bool
    let time: String
    let status: String?
    var starred: Bool = false
    var highlightMentions: Bool = false
    var conversationId: String = ""
    let onOpen: (Attachment) -> Void
    var onLongPress: () -> Void = {}

    private let cardRadius: CGFloat = 18
    private let mediaWidth: CGFloat = 240
    private let gridInset: CGFloat = 4

    var body: some View {
        if caption.isEmpty {
            MediaBentoGrid(
                media: media, width: mediaWidth, cornerRadius: cardRadius,
                conversationId: conversationId, isMine: isMine, onOpen: onOpen
            )
            .overlay(alignment: .bottomTrailing) { overlayPill }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                MediaBentoGrid(
                    media: media,
                    width: mediaWidth - gridInset * 2,
                    cornerRadius: cardRadius - gridInset,
                    conversationId: conversationId,
                    isMine: isMine,
                    onOpen: onOpen
                )
                .padding(gridInset)

                HStack(alignment: .bottom, spacing: 6) {
                    RichMessageText(
                        text: caption,
                        font: UIFont(name: "TikTokSans-Regular", size: 16) ?? .systemFont(ofSize: 16),
                        textColor: UIColor(isMine ? KlicColor.onPrimary : KlicColor.textPrimary),
                        highlightMentions: highlightMentions,
                        mentionColor: UIColor(isMine ? KlicColor.onPrimary : KlicColor.primary),
                        onLongPress: onLongPress
                    )
                    HStack(spacing: 3) {
                        if starred { StarIndicator(onPrimary: isMine) }
                        Text(time)
                            .font(KlicFont.caption(11))
                            .foregroundStyle(isMine ? KlicColor.onPrimary.opacity(0.65) : KlicColor.textMuted)
                        if isMine, let status {
                            MessageTicks(status: status, onPrimary: isMine)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 9)
            }
            .frame(width: mediaWidth)
            .background(
                isMine ? KlicColor.primary : KlicColor.surfaceRaised,
                in: RoundedRectangle(cornerRadius: cardRadius)
            )
        }
    }

    private var overlayPill: some View {
        HStack(spacing: 3) {
            if starred { StarIndicator(onPrimary: true) }
            Text(time)
                .font(KlicFont.caption(11))
                .foregroundStyle(.white)
            if isMine, let status {
                MessageTicks(status: status, onPrimary: true)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(8)
    }
}

/// Bento layout for 1–n media attachments: 2 → side-by-side, 3 → one large + two
/// stacked, 4 → 2x2, >4 → 2x2 with a "+N" scrim on the fourth tile. Tapping a tile
/// opens the media viewer at that attachment.
private struct MediaBentoGrid: View {
    let media: [Attachment]
    let width: CGFloat
    var cornerRadius: CGFloat = 16
    var conversationId: String = ""
    var isMine: Bool = false
    let onOpen: (Attachment) -> Void

    private let spacing: CGFloat = 2

    var body: some View {
        layout
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder private var layout: some View {
        switch media.count {
        case 1:
            let attachment = media[0]
            MediaTile(attachment: attachment, conversationId: conversationId, isMine: isMine, onTap: { onOpen(attachment) })
                .frame(width: width, height: singleHeight(for: attachment))
        case 2:
            let tile = (width - spacing) / 2
            HStack(spacing: spacing) {
                ForEach(media) { attachment in
                    MediaTile(attachment: attachment, conversationId: conversationId, isMine: isMine, onTap: { onOpen(attachment) })
                        .frame(width: tile, height: tile * 1.3)
                }
            }
        case 3:
            // One large tile + two stacked on the right.
            let height: CGFloat = 200
            let largeWidth = (width - spacing) * 2 / 3
            let smallWidth = width - spacing - largeWidth
            let smallHeight = (height - spacing) / 2
            HStack(spacing: spacing) {
                MediaTile(attachment: media[0], conversationId: conversationId, isMine: isMine, onTap: { onOpen(media[0]) })
                    .frame(width: largeWidth, height: height)
                VStack(spacing: spacing) {
                    ForEach(media[1...]) { attachment in
                        MediaTile(attachment: attachment, conversationId: conversationId, isMine: isMine, onTap: { onOpen(attachment) })
                            .frame(width: smallWidth, height: smallHeight)
                    }
                }
            }
        default:
            // 2x2; anything past the fourth hides behind a "+N" scrim on tile 4.
            let tile = (width - spacing) / 2
            let visible = Array(media.prefix(4))
            let extra = media.count - 4
            VStack(spacing: spacing) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<2, id: \.self) { col in
                            let index = row * 2 + col
                            let attachment = visible[index]
                            MediaTile(attachment: attachment, conversationId: conversationId, isMine: isMine, onTap: { onOpen(attachment) })
                                .frame(width: tile, height: tile)
                                .overlay {
                                    if index == 3, extra > 0 {
                                        ZStack {
                                            Color.black.opacity(0.5)
                                            Text("+\(extra)")
                                                .font(KlicFont.headline(22))
                                                .foregroundStyle(.white)
                                        }
                                        .allowsHitTesting(false)
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    private func singleHeight(for attachment: Attachment) -> CGFloat {
        if attachment.isVideo {
            return width * 0.68
        }
        guard let attachmentWidth = attachment.width,
              let attachmentHeight = attachment.height,
              attachmentWidth > 0,
              attachmentHeight > 0 else {
            return width
        }
        return min(max(width * CGFloat(attachmentHeight) / CGFloat(attachmentWidth), 120), 320)
    }
}

/// One media cell in the bento grid: a filled image, or a video placeholder with a play
/// glyph and duration chip. Photos honor the auto-download matrix (§8.3): when the
/// current network disallows photo auto-download and the image isn't cached yet, the
/// tile shows a placeholder with a manual download button instead of fetching.
private struct MediaTile: View {
    let attachment: Attachment
    var conversationId: String = ""
    var isMine: Bool = false
    let onTap: () -> Void

    private enum LoadState {
        case idle, loading, loaded(UIImage), blocked, failed
    }

    @State private var state: LoadState = .idle

    var body: some View {
        Group {
            if attachment.isVideo {
                // Videos never auto-fetch (they stream on demand from the viewer),
                // so the placeholder-with-tap contract already holds for them.
                ZStack {
                    Color.black.opacity(0.85)
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.95))
                    if let milliseconds = attachment.durationMs, milliseconds > 0 {
                        Text(durationText(milliseconds))
                            .font(KlicFont.caption(11))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(6)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
            } else {
                imageBody
            }
        }
        .clipped()
    }

    @ViewBuilder private var imageBody: some View {
        switch state {
        case .loaded(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
        case .blocked:
            KlicColor.surfaceRaised
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(KlicColor.primary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file))
                            .font(KlicFont.caption(11))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { Task { await load(force: true) } }
        case .failed:
            KlicColor.surfaceRaised
                .overlay(Image(systemName: "photo").foregroundStyle(KlicColor.textMuted))
                .contentShape(Rectangle())
                .onTapGesture { Task { await load(force: true) } }
        default:
            KlicColor.surfaceRaised
                .overlay(LoadingCircle())
                .task(id: attachment.url) { await load(force: false) }
        }
    }

    private func load(force: Bool) async {
        guard let url = URL(string: attachment.url) else {
            state = .failed
            return
        }
        // Already cached → always show (no network involved).
        if let cached = await RemoteImageStore.shared.cachedImage(for: url) {
            state = .loaded(cached)
            return
        }
        guard force || AutoDownloadPrefs.allowedNow(.photos) else {
            state = .blocked
            return
        }
        state = .loading
        guard let image = await RemoteImageStore.shared.image(for: url) else {
            state = .failed
            return
        }
        state = .loaded(image)
        // "Save to Photos: Always" — incoming photos save when their bytes arrive.
        if !conversationId.isEmpty {
            MediaAutoSaver.autoSave(
                image: image, attachmentId: attachment.id,
                conversationId: conversationId, isMine: isMine
            )
        }
    }

    private func durationText(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Voice

private struct VoiceAttachmentView: View {
    let attachment: Attachment
    let isMine: Bool
    var time: String? = nil
    var status: String? = nil
    var starred: Bool = false

    @ObservedObject private var player = AudioPlaybackManager.shared

    private var playing: Bool { player.playingId == attachment.id }
    private var tint: Color { isMine ? KlicColor.onPrimary : KlicColor.primary }

    private var waveformAmplitudes: [Float] {
        guard let base64 = attachment.waveform, let data = Data(base64Encoded: base64) else { return [] }
        return unpackWaveform(data)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 10) {
                Button { play() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isMine ? KlicColor.primary : KlicColor.onPrimary)
                        .frame(width: 34, height: 34)
                        .background(tint, in: Circle())
                }

                WaveformBarsView(
                    amplitudes: waveformAmplitudes,
                    progress: playing ? player.progress : 0,
                    isOutgoing: isMine
                )
                .frame(width: 110)

                Text(durationText)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(isMine ? KlicColor.onPrimary.opacity(0.85) : KlicColor.textMuted)
                    .monospacedDigit()
            }

            if let time {
                HStack(spacing: 3) {
                    if starred { StarIndicator(onPrimary: isMine) }
                    Text(time)
                        .font(KlicFont.caption(11))
                        .foregroundStyle(isMine ? KlicColor.onPrimary.opacity(0.65) : KlicColor.textMuted)
                    if isMine, let status {
                        MessageTicks(status: status, onPrimary: isMine)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isMine ? KlicColor.primary : KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
        .onAppear {
            // Auto-download matrix (§8.3): pre-cache voice notes when allowed on this network.
            if AutoDownloadPrefs.allowedNow(.audio), !AttachmentFileStore.shared.isCached(attachment) {
                Task { _ = try? await AttachmentFileStore.shared.download(attachment) }
            }
        }
    }

    /// Prefer the cached local file (offline playback) and fall back to streaming —
    /// tapping play is a manual action, so it works even when auto-download is off.
    private func play() {
        let local = AttachmentFileStore.shared.cachedURL(for: attachment)
        player.toggle(id: attachment.id, url: local?.absoluteString ?? attachment.url)
    }

    private var durationText: String {
        let seconds = (attachment.durationMs ?? 0) / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Files (in-app viewing — the media URL never leaves the app)

/// FILE attachment row: tapping downloads the file into the app's cache (progress shown
/// in the bubble) and previews it in-app with Quick Look. Files Quick Look can't render
/// fall back to a share sheet with the LOCAL file only — the presigned https URL is
/// never handed to a browser or another app.
private struct FileAttachmentView: View {
    let attachment: Attachment
    let isMine: Bool
    var time: String? = nil
    var status: String? = nil
    var starred: Bool = false

    @ObservedObject private var store = AttachmentFileStore.shared
    @State private var previewFile: LocalFile?
    @State private var shareFile: LocalFile?

    private struct LocalFile: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var downloadProgress: Double? { store.progress[attachment.id] }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 10) {
                    ZStack {
                        if let downloadProgress {
                            DownloadProgressRing(
                                progress: downloadProgress,
                                tint: isMine ? KlicColor.onPrimary : KlicColor.primary
                            )
                        } else {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(isMine ? KlicColor.onPrimary : KlicColor.primary)
                        }
                    }
                    .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName ?? "File")
                            .font(KlicFont.body())
                            .lineLimit(1)
                            .foregroundStyle(isMine ? KlicColor.onPrimary : KlicColor.textPrimary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file))
                            .font(KlicFont.caption(11))
                            .foregroundStyle(isMine ? KlicColor.onPrimary.opacity(0.8) : KlicColor.textMuted)
                    }
                }
                if let time {
                    HStack(spacing: 3) {
                        if starred { StarIndicator(onPrimary: isMine) }
                        Text(time)
                            .font(KlicFont.caption(11))
                            .foregroundStyle(isMine ? KlicColor.onPrimary.opacity(0.65) : KlicColor.textMuted)
                        if isMine, let status {
                            MessageTicks(status: status, onPrimary: isMine)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 240, alignment: .leading)
            .background(isMine ? KlicColor.primary : KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(downloadProgress != nil)
        .onAppear {
            // Auto-download matrix (§8.3): pre-cache documents when allowed on this network.
            if AutoDownloadPrefs.allowedNow(.documents), !store.isCached(attachment) {
                Task { _ = try? await AttachmentFileStore.shared.download(attachment) }
            }
        }
        .fullScreenCover(item: $previewFile) { file in
            QuickLookPreview(url: file.url)
                .ignoresSafeArea()
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(activityItems: [file.url])
        }
    }

    private func open() {
        Task {
            guard let local = try? await AttachmentFileStore.shared.download(attachment) else { return }
            if QLPreviewController.canPreview(local as NSURL) {
                previewFile = LocalFile(url: local)
            } else {
                shareFile = LocalFile(url: local)
            }
        }
    }
}

private struct DownloadProgressRing: View {
    let progress: Double
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.3), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(progress, 0.03))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.linear(duration: 0.15), value: progress)
    }
}

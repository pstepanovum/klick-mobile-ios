import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

// MARK: - Upload helper

enum Media {
    /// Uploads bytes (presign → PUT) and returns a draft ready to attach to a message.
    static func upload(
        conversationId: String, kind: String, contentType: String, data: Data,
        width: Int? = nil, height: Int? = nil, durationMs: Int? = nil, fileName: String? = nil
    ) async throws -> AttachmentDraft {
        let ticket = try await APIClient.shared.requestUpload(
            conversationId: conversationId, kind: kind, contentType: contentType, byteSize: data.count)
        try await APIClient.shared.uploadData(data, to: ticket.uploadUrl, contentType: contentType)
        return AttachmentDraft(
            key: ticket.key, kind: kind, contentType: contentType, byteSize: data.count,
            width: width, height: height, durationMs: durationMs, fileName: fileName)
    }

    /// Downscale + JPEG-encode an image. Returns (data, pixelWidth, pixelHeight).
    static func encodeImage(_ image: UIImage, maxDimension: CGFloat = 2048, quality: CGFloat = 0.85) -> (Data, Int, Int)? {
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let maxSide = max(px.width, px.height)
        let s = maxSide > maxDimension ? maxDimension / maxSide : 1
        let target = CGSize(width: max(px.width * s, 1), height: max(px.height * s, 1))
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = scaled.jpegData(compressionQuality: quality) else { return nil }
        return (data, Int(target.width), Int(target.height))
    }

    static func mime(for url: URL, fallback: String) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? fallback
    }
}

/// Lets PhotosPicker hand us a video as a temp file URL.
struct Movie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("vid-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Movie(url: copy)
        }
    }
}

// MARK: - Voice recording

@MainActor
final class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    func start() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            guard granted else { return }
            Task { @MainActor in self?.begin() }
        }
    }

    private func begin() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return }
        recorder = rec; fileURL = url
        rec.record()
        isRecording = true; elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in if let r = self?.recorder { self?.elapsed = r.currentTime } }
        }
    }

    /// Stop and return (data, durationMs); nil if too short or failed.
    func stop() -> (data: Data, durationMs: Int)? {
        timer?.invalidate(); timer = nil
        guard let rec = recorder, let url = fileURL else { isRecording = false; return nil }
        let duration = rec.currentTime
        rec.stop(); recorder = nil; isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        guard duration > 0.4, let data = try? Data(contentsOf: url) else { return nil }
        return (data, Int(duration * 1000))
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil; isRecording = false
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Voice playback (one at a time, app-wide)

@MainActor
final class AudioPlaybackManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlaybackManager()
    @Published var playingId: String?
    @Published var progress: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(id: String, url: String) {
        if playingId == id { stop(); return }
        Task { await play(id: id, url: url) }
    }

    private func play(id: String, url: String) async {
        stop()
        guard let u = URL(string: url),
              let (data, _) = try? await URLSession.shared.data(from: u),
              let p = try? AVAudioPlayer(data: data) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        p.delegate = self
        player = p; playingId = id
        p.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.progress = p.duration > 0 ? p.currentTime / p.duration : 0
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        playingId = nil; progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - Camera capture

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}

// MARK: - Attachment rendering

struct MessageAttachmentsView: View {
    let attachments: [Attachment]
    let isMine: Bool

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
            ForEach(attachments) { att in
                switch att.kind {
                case "IMAGE": ImageAttachmentView(att: att)
                case "VOICE": VoiceAttachmentView(att: att, isMine: isMine)
                case "VIDEO": VideoAttachmentView(att: att)
                default:      FileAttachmentView(att: att, isMine: isMine)
                }
            }
        }
    }
}

private struct ImageAttachmentView: View {
    let att: Attachment
    @State private var fullscreen = false

    private var size: CGSize {
        let w: CGFloat = 220
        guard let aw = att.width, let ah = att.height, aw > 0, ah > 0 else { return CGSize(width: w, height: w) }
        return CGSize(width: w, height: min(max(w * CGFloat(ah) / CGFloat(aw), 120), 320))
    }

    var body: some View {
        AsyncImage(url: URL(string: att.url)) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            case .failure: KlicColor.surfaceRaised.overlay(Image(systemName: "photo").foregroundStyle(KlicColor.textMuted))
            default: KlicColor.surfaceRaised.overlay(ProgressView())
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { fullscreen = true }
        .fullScreenCover(isPresented: $fullscreen) { MediaViewer(url: att.url, isVideo: false) }
    }
}

private struct VoiceAttachmentView: View {
    let att: Attachment
    let isMine: Bool
    @ObservedObject private var player = AudioPlaybackManager.shared

    private var playing: Bool { player.playingId == att.id }
    private var tint: Color { isMine ? KlicColor.onPrimary : KlicColor.primary }

    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle(id: att.id, url: att.url) } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isMine ? KlicColor.primary : KlicColor.onPrimary)
                    .frame(width: 34, height: 34)
                    .background(tint, in: Circle())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.25)).frame(height: 4)
                    Capsule().fill(tint).frame(width: geo.size.width * (playing ? player.progress : 0), height: 4)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: 110, height: 34)
            Text(durationText)
                .font(KlicFont.caption(12))
                .foregroundStyle(isMine ? KlicColor.onPrimary.opacity(0.85) : KlicColor.textMuted)
                .monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isMine ? KlicColor.primary : KlicColor.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: 18))
    }

    private var durationText: String {
        let s = (att.durationMs ?? 0) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct VideoAttachmentView: View {
    let att: Attachment
    @State private var playing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.85))
            Image(systemName: "play.circle.fill").font(.system(size: 46)).foregroundStyle(.white.opacity(0.95))
            if let ms = att.durationMs, ms > 0 {
                Text(durationText).font(KlicFont.caption(11)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
            }
        }
        .frame(width: 220, height: 150)
        .onTapGesture { playing = true }
        .fullScreenCover(isPresented: $playing) { MediaViewer(url: att.url, isVideo: true) }
    }

    private var durationText: String {
        let s = (att.durationMs ?? 0) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct FileAttachmentView: View {
    let att: Attachment
    let isMine: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { if let u = URL(string: att.url) { openURL(u) } } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(isMine ? KlicColor.onPrimary : KlicColor.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(att.fileName ?? "File")
                        .font(KlicFont.body()).lineLimit(1)
                        .foregroundStyle(isMine ? KlicColor.onPrimary : KlicColor.textPrimary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(att.byteSize), countStyle: .file))
                        .font(KlicFont.caption(11))
                        .foregroundStyle(isMine ? KlicColor.onPrimary.opacity(0.8) : KlicColor.textMuted)
                }
            }
            .padding(12)
            .frame(maxWidth: 240, alignment: .leading)
            .background(isMine ? KlicColor.primary : KlicColor.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// Full-screen image / video viewer.
struct MediaViewer: View {
    let url: String
    let isVideo: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let u = URL(string: url) {
                if isVideo {
                    VideoPlayer(player: AVPlayer(url: u)).ignoresSafeArea()
                } else {
                    AsyncImage(url: u) { image in
                        image.resizable().scaledToFit()
                    } placeholder: { ProgressView().tint(.white) }
                    .ignoresSafeArea()
                }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.white.opacity(0.9))
                    .padding()
            }
        }
    }
}

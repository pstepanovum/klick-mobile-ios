import SwiftUI
import PhotosUI
import AVFoundation

/// Staging (preview-before-send) and uploading of photo/video/voice/file attachments.
extension ChatView {
    func stagePickedMedia(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let movie = try? await item.loadTransferable(type: Movie.self) {
                await stageVideo(movie.url)
            } else if let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) {
                await stageImage(image)
            }
        }
    }

    @MainActor
    func stageImage(_ image: UIImage) async {
        // Upload quality (§8.3): HD keeps more pixels + lighter compression.
        let quality = UploadQuality.current
        guard let (data, w, h) = Media.encodeImage(
            image, maxDimension: quality.imageMaxDimension, quality: quality.imageJpegQuality
        ) else { return }
        pendingMedia.append(
            PendingMediaDraft(
                kind: "IMAGE",
                contentType: "image/jpeg",
                data: data,
                previewImage: image,
                width: w,
                height: h
            )
        )
    }

    @MainActor
    func stageVideo(_ url: URL) async {
        guard let data = try? Data(contentsOf: url) else { return }
        let asset = AVURLAsset(url: url)
        var durationMs = 0
        if let duration = try? await asset.load(.duration) {
            durationMs = Int(CMTimeGetSeconds(duration) * 1000)
        }
        var width: Int?
        var height: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let naturalSize = try? await track.load(.naturalSize) {
            width = Int(abs(naturalSize.width))
            height = Int(abs(naturalSize.height))
        }
        guard let previewImage = videoThumbnail(for: asset) else { return }
        pendingMedia.append(
            PendingMediaDraft(
                kind: "VIDEO",
                contentType: Media.mime(for: url, fallback: "video/quicktime"),
                data: data,
                previewImage: previewImage,
                width: width,
                height: height,
                durationMs: durationMs,
                fileName: url.lastPathComponent
            )
        )
    }

    private func sendImage(_ image: UIImage) async {
        let quality = UploadQuality.current
        guard let (data, w, h) = Media.encodeImage(
            image, maxDimension: quality.imageMaxDimension, quality: quality.imageJpegQuality
        ) else { return }
        await sendAttachment(kind: "IMAGE", contentType: "image/jpeg", data: data, width: w, height: h)
    }

    private func sendVideo(_ url: URL) async {
        guard let data = try? Data(contentsOf: url) else { return }
        let asset = AVURLAsset(url: url)
        var durationMs = 0
        if let d = try? await asset.load(.duration) { durationMs = Int(CMTimeGetSeconds(d) * 1000) }
        var w: Int?, h: Int?
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            w = Int(abs(size.width)); h = Int(abs(size.height))
        }
        await sendAttachment(kind: "VIDEO", contentType: Media.mime(for: url, fallback: "video/quicktime"),
                             data: data, width: w, height: h, durationMs: durationMs)
    }

    private func videoThumbnail(for asset: AVURLAsset) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    func sendFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        await sendAttachment(kind: "FILE", contentType: Media.mime(for: url, fallback: "application/octet-stream"),
                             data: data, fileName: url.lastPathComponent)
    }

    func stopAndSendVoice() async {
        guard let (data, durationMs, waveform) = recorder.stop() else { return }
        await sendAttachment(kind: "VOICE", contentType: "audio/m4a", data: data, durationMs: durationMs, waveform: waveform)
    }

    func sendComposerPayload() async {
        if pendingMedia.isEmpty {
            await send()
            return
        }

        uploading = true
        defer { uploading = false }
        let body = draft.trimmingCharacters(in: .whitespaces)
        let replyId = replyingTo?.id
        do {
            var drafts: [AttachmentDraft] = []
            for item in pendingMedia {
                let draft = try await Media.upload(
                    conversationId: conversation.id,
                    kind: item.kind,
                    contentType: item.contentType,
                    data: item.data,
                    width: item.width,
                    height: item.height,
                    durationMs: item.durationMs,
                    waveform: item.waveform,
                    fileName: item.fileName
                )
                drafts.append(draft)
            }
            let msg = try await APIClient.shared.sendMessage(
                conversationId: conversation.id,
                body: body.isEmpty ? nil : body,
                attachments: drafts,
                replyToId: replyId
            )
            draft = ""
            pendingMedia.removeAll()
            withAnimation { replyingTo = nil }
            upsert(msg)
            scrollToBottom()
        } catch {
            // Keep the staged media + caption in place so the user can retry.
        }
    }

    private func sendAttachment(kind: String, contentType: String, data: Data,
                                width: Int? = nil, height: Int? = nil,
                                durationMs: Int? = nil, waveform: Data? = nil, fileName: String? = nil) async {
        uploading = true
        defer { uploading = false }
        let replyId = replyingTo?.id
        do {
            let draft = try await Media.upload(
                conversationId: conversation.id, kind: kind, contentType: contentType, data: data,
                width: width, height: height, durationMs: durationMs, waveform: waveform, fileName: fileName)
            let msg = try await APIClient.shared.sendMessage(
                conversationId: conversation.id, body: nil, attachments: [draft], replyToId: replyId)
            withAnimation { replyingTo = nil }
            upsert(msg)
            scrollToBottom()
        } catch {
            // Upload/send failed — silently ignored for now (matches existing send() behavior).
        }
    }
}

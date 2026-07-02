import UIKit
import AVFoundation
import UniformTypeIdentifiers

/// One media item extracted from the share sheet, ready for the attachment pipeline.
struct SharePayloadItem: Identifiable {
    let id = UUID()
    let kind: String            // "IMAGE" | "VIDEO" | "FILE"
    let contentType: String
    let data: Data
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var fileName: String?
    var previewImage: UIImage?
}

/// Everything the user shared: media items plus any text/URL (prefills the message field).
struct SharePayload {
    var media: [SharePayloadItem] = []
    var text: String = ""

    var isEmpty: Bool { media.isEmpty && text.isEmpty }
}

/// Resolves the share sheet's NSItemProviders into upload-ready payload items. Images are
/// re-encoded to JPEG (max 2048px) to match the app's attachment pipeline; movies are read
/// from the provided file; text and web URLs land in the message text.
enum SharePayloadLoader {
    static func load(from items: [NSExtensionItem]) async -> SharePayload {
        var payload = SharePayload()
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                if let item = await loadMovie(provider) { payload.media.append(item) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let item = await loadImage(provider) { payload.media.append(item) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = await loadObject(provider, of: NSURL.self) {
                    if url.isFileURL {
                        if let item = loadFile(url as URL) { payload.media.append(item) }
                    } else {
                        appendText(url.absoluteString ?? "", to: &payload)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await loadObject(provider, of: NSString.self) {
                    appendText(text as String, to: &payload)
                }
            }
        }
        return payload
    }

    private static func appendText(_ text: String, to payload: inout SharePayload) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        payload.text = payload.text.isEmpty ? trimmed : payload.text + "\n" + trimmed
    }

    // MARK: - Per-type loaders

    private static func loadImage(_ provider: NSItemProvider) async -> SharePayloadItem? {
        // Prefer the file representation (photos come as HEIC/JPEG files), falling back to
        // an in-memory UIImage (e.g. screenshots shared straight from the markup UI).
        var image: UIImage?
        if let url = await loadFileCopy(provider, type: UTType.image),
           let data = try? Data(contentsOf: url) {
            image = UIImage(data: data)
            try? FileManager.default.removeItem(at: url)
        }
        if image == nil, provider.canLoadObject(ofClass: UIImage.self) {
            image = await loadObject(provider, of: UIImage.self)
        }
        guard let image, let (data, w, h) = encodeImage(image) else { return nil }
        return SharePayloadItem(
            kind: "IMAGE", contentType: "image/jpeg", data: data,
            width: w, height: h, previewImage: image
        )
    }

    private static func loadMovie(_ provider: NSItemProvider) async -> SharePayloadItem? {
        guard let url = await loadFileCopy(provider, type: UTType.movie),
              let data = try? Data(contentsOf: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
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
        return SharePayloadItem(
            kind: "VIDEO",
            contentType: mime(for: url, fallback: "video/quicktime"),
            data: data,
            width: width, height: height, durationMs: durationMs,
            fileName: url.lastPathComponent,
            previewImage: thumbnail(for: asset)
        )
    }

    private static func loadFile(_ url: URL) -> SharePayloadItem? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SharePayloadItem(
            kind: "FILE",
            contentType: mime(for: url, fallback: "application/octet-stream"),
            data: data,
            fileName: url.lastPathComponent
        )
    }

    // MARK: - Plumbing

    /// loadFileRepresentation deletes its file when the handler returns, so copy it into
    /// our tmp dir first and hand back the copy (caller removes it when done).
    private static func loadFileCopy(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("share-\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func loadObject<T: NSItemProviderReading>(
        _ provider: NSItemProvider, of cls: T.Type
    ) async -> T? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: cls) { object, _ in
                continuation.resume(returning: object as? T)
            }
        }
    }

    /// Same encoding as the app's chat pipeline (Media.encodeImage): ≤2048px JPEG.
    private static func encodeImage(
        _ image: UIImage, maxDimension: CGFloat = 2048, quality: CGFloat = 0.85
    ) -> (Data, Int, Int)? {
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let maxSide = max(px.width, px.height)
        let scale = maxSide > maxDimension ? maxDimension / maxSide : 1
        let target = CGSize(width: max(px.width * scale, 1), height: max(px.height * scale, 1))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = scaled.jpegData(compressionQuality: quality) else { return nil }
        return (data, Int(target.width), Int(target.height))
    }

    private static func mime(for url: URL, fallback: String) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? fallback
    }

    private static func thumbnail(for asset: AVURLAsset) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

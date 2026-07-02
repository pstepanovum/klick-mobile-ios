import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ChatMediaGalleryItem: Identifiable, Hashable {
    let id: String
    let attachmentId: String
    let messageId: String
    let url: String
    let isVideo: Bool
    let caption: String
    let senderName: String
    let createdAt: String
    let reactions: [Reaction]
    let isMine: Bool
    let durationMs: Int?
    let thumbnailURL: String?
}

enum Media {
    static func upload(
        conversationId: String, kind: String, contentType: String, data: Data,
        width: Int? = nil, height: Int? = nil, durationMs: Int? = nil,
        waveform: Data? = nil, fileName: String? = nil
    ) async throws -> AttachmentDraft {
        let ticket = try await APIClient.shared.requestUpload(
            conversationId: conversationId, kind: kind, contentType: contentType, byteSize: data.count)
        try await APIClient.shared.uploadData(data, to: ticket.uploadUrl, contentType: contentType)
        return AttachmentDraft(
            key: ticket.key, kind: kind, contentType: contentType, byteSize: data.count,
            width: width, height: height, durationMs: durationMs, waveform: waveform, fileName: fileName)
    }

    static func encodeImage(_ image: UIImage, maxDimension: CGFloat = 2048, quality: CGFloat = 0.85) -> (Data, Int, Int)? {
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

    static func mime(for url: URL, fallback: String) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? fallback
    }
}

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

struct CameraPicker: UIViewControllerRepresentable {
    enum Mode {
        case photo
        case video
    }

    let mode: Mode
    var onImage: ((UIImage) -> Void)? = nil
    var onVideo: ((URL) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        switch mode {
        case .photo:
            picker.cameraCaptureMode = .photo
        case .video:
            picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video
            // Upload quality (§8.3): HD records/exports at high quality; Standard
            // keeps the previous medium-quality pipeline.
            let hd = UploadQuality.current == .hd
            picker.videoQuality = hd ? .typeHigh : .typeMedium
            picker.videoExportPreset = hd ? AVAssetExportPresetHighestQuality : AVAssetExportPresetMediumQuality
            picker.videoMaximumDuration = 60
        }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.mediaURL] as? URL {
                parent.onVideo?(url)
            } else if let image = info[.originalImage] as? UIImage {
                parent.onImage?(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

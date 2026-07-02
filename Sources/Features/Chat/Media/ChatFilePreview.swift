import SwiftUI
import QuickLook

/// Downloads FILE attachments into the app's caches directory (keyed by attachment id)
/// so they can be viewed in-app. Publishes per-attachment progress for the bubble UI.
/// The presigned media URL is only ever fetched here — it is never opened externally.
@MainActor
final class AttachmentFileStore: ObservableObject {
    static let shared = AttachmentFileStore()

    /// attachmentId → 0…1 while a download is in flight.
    @Published private(set) var progress: [String: Double] = [:]

    private var inFlight: [String: Task<URL, Error>] = [:]

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Local cache location for an attachment. The original file name is kept as the
    /// path's last component (inside a per-attachment folder) so Quick Look and the
    /// share sheet show the real name and pick the right renderer by extension.
    private func localURL(for attachment: Attachment) -> URL {
        let name = (attachment.fileName?.isEmpty == false ? attachment.fileName! : "file")
            .replacingOccurrences(of: "/", with: "_")
        return Self.directory
            .appendingPathComponent(attachment.id, isDirectory: true)
            .appendingPathComponent(name)
    }

    /// Returns the cached file immediately when present, otherwise downloads it,
    /// reporting progress along the way. Concurrent calls for the same attachment
    /// share one download.
    func download(_ attachment: Attachment) async throws -> URL {
        let destination = localURL(for: attachment)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        if let task = inFlight[attachment.id] {
            return try await task.value
        }
        guard let remote = URL(string: attachment.url) else { throw URLError(.badURL) }
        let expectedBytes = attachment.byteSize
        let attachmentId = attachment.id
        progress[attachmentId] = 0
        let task = Task<URL, Error> {
            let (bytes, response) = try await URLSession.shared.bytes(from: remote)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let total = http.expectedContentLength > 0 ? Int(http.expectedContentLength) : expectedBytes
            var data = Data()
            data.reserveCapacity(max(total, 0))
            var lastReported = 0.0
            for try await byte in bytes {
                data.append(byte)
                if total > 0 {
                    let fraction = Double(data.count) / Double(total)
                    if fraction - lastReported >= 0.02 {
                        lastReported = fraction
                        let value = min(fraction, 1)
                        await MainActor.run { AttachmentFileStore.shared.progress[attachmentId] = value }
                    }
                }
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            return destination
        }
        inFlight[attachment.id] = task
        defer {
            inFlight[attachment.id] = nil
            progress[attachment.id] = nil
        }
        do {
            return try await task.value
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

/// Quick Look preview of a single LOCAL file (pdf, audio, docs, …) — covers everything
/// §7.3 needs without ever exposing the remote URL.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { _ in context.coordinator.dismiss() }
        )
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        context.coordinator.url = url
        context.coordinator.onDismiss = { dismiss() }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onDismiss: { dismiss() })
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        var onDismiss: () -> Void

        init(url: URL, onDismiss: @escaping () -> Void) {
            self.url = url
            self.onDismiss = onDismiss
        }

        func dismiss() { onDismiss() }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

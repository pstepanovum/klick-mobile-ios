import SwiftUI
import CryptoKit

enum RemoteImagePhase {
    case empty
    case success(Image)
    case failure
}

struct RemoteImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (RemoteImagePhase) -> Content

    @State private var phase: RemoteImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else {
            phase = .failure
            return
        }
        phase = .empty
        guard let uiImage = await RemoteImageStore.shared.image(for: url) else {
            phase = .failure
            return
        }
        phase = .success(Image(uiImage: uiImage))
    }
}

actor RemoteImageStore {
    static let shared = RemoteImageStore()

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let maxDiskEntryBytes = 16 * 1024 * 1024

    init() {
        memory.totalCostLimit = 64 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        directory = (caches ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("klic-remote-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString
        if let cached = memory.object(forKey: key as NSString) {
            return cached
        }
        if let cached = try? Data(contentsOf: fileURL(for: key)),
           let image = UIImage(data: cached) {
            remember(image, for: key)
            return image
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never> { await self.fetch(url, key: key) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    /// Cached-only lookup (memory/disk, no network) — used by the auto-download
    /// gate so already-fetched photos still render when auto-download is off.
    func cachedImage(for url: URL) -> UIImage? {
        let key = url.absoluteString
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let cached = try? Data(contentsOf: fileURL(for: key)),
           let image = UIImage(data: cached) {
            remember(image, for: key)
            return image
        }
        return nil
    }

    private func fetch(_ url: URL, key: String) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode),
                  let image = UIImage(data: data) else { return nil }
            DataUsageTracker.shared.record(type: .photos, sent: 0, received: data.count)
            remember(image, for: key)
            if data.count <= maxDiskEntryBytes {
                try? data.write(to: fileURL(for: key), options: .atomic)
            }
            return image
        } catch {
            return nil
        }
    }

    /// The on-disk image cache location ("Photos" in the Data & Storage scan).
    nonisolated static var diskDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return (caches ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("klic-remote-images", isDirectory: true)
    }

    /// Disk bytes cached for one specific remote URL (0 when absent).
    nonisolated static func cachedBytes(forURLString key: String) -> Int64 {
        let digest = SHA256.hash(data: Data(key.utf8))
        let file = digest.map { String(format: "%02x", $0) }.joined()
        let url = diskDirectory.appendingPathComponent(file)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }

    nonisolated static func removeCached(forURLString key: String) {
        let digest = SHA256.hash(data: Data(key.utf8))
        let file = digest.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(at: diskDirectory.appendingPathComponent(file))
    }

    /// Drop the in-memory cache (used right after the disk cache is cleared).
    func purgeMemory() {
        memory.removeAllObjects()
    }

    private func remember(_ image: UIImage, for key: String) {
        memory.setObject(image, forKey: key as NSString, cost: imageCost(image))
    }

    private func fileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let file = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(file)
    }

    private func imageCost(_ image: UIImage) -> Int {
        if let cg = image.cgImage { return cg.bytesPerRow * cg.height }
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        return width * height * 4
    }
}

/// Circular avatar that loads a remote image, falling back to the user's initials.
struct AvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url) {
                RemoteImage(url: parsed) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .empty: LoadingCircle()
                    default: initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: some View {
        ZStack {
            Circle().fill(KlicColor.primary.opacity(0.18))
            Text(initialsText)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(KlicColor.primary)
        }
    }

    private var initialsText: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

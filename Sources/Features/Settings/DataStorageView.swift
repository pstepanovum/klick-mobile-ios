import SwiftUI
import UniformTypeIdentifiers

// MARK: - Cache inventory (§8.3)

/// Scans the app's cache locations and buckets bytes per category.
///
/// Mapping (documented per CALLS.md §8.3):
/// - `Caches/Attachments/<id>/<file>` (§7.3 in-app file store) → by the cached file's
///   extension/UTType: image → Photos, movie → Videos, audio → Audio, rest → Documents.
/// - `Caches/klic-remote-images` (the image pipeline's disk cache) → Photos.
/// - Stickers ship bundled inside the app on iOS (no network cache) → always 0.
/// - Everything else in Caches + tmp (URLCache databases, staged uploads, …) → Misc.
enum CacheInventory {
    enum Category: String, CaseIterable, Identifiable {
        case photos, videos, audio, documents, stickers, misc

        var id: String { rawValue }
        var label: String {
            switch self {
            case .photos: return "Photos"
            case .videos: return "Videos"
            case .audio: return "Audio"
            case .documents: return "Documents"
            case .stickers: return "Stickers"
            case .misc: return "Misc"
            }
        }

        var color: Color {
            switch self {
            case .photos: return Color(red: 0.23, green: 0.51, blue: 0.96)
            case .videos: return Color(red: 0.61, green: 0.35, blue: 0.95)
            case .audio: return Color(red: 0.13, green: 0.77, blue: 0.34)
            case .documents: return Color(red: 0.97, green: 0.57, blue: 0.20)
            case .stickers: return Color(red: 0.95, green: 0.77, blue: 0.06)
            case .misc: return Color.gray
            }
        }
    }

    static func categorize(fileExtension ext: String) -> Category {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext.lowercased()) else { return .documents }
        if type.conforms(to: .image) { return .photos }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .videos }
        if type.conforms(to: .audio) { return .audio }
        return .documents
    }

    /// Full scan, off the main thread.
    static func scan() -> [Category: Int64] {
        var totals: [Category: Int64] = [:]
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]

        // 1. The §7.3 attachment store — categorize each cached file by extension.
        let attachments = AttachmentFileStore.directory
        if let ids = try? fm.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil) {
            for idDir in ids {
                guard let files = try? fm.contentsOfDirectory(
                    at: idDir, includingPropertiesForKeys: [.fileSizeKey]
                ) else { continue }
                for file in files {
                    let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    totals[categorize(fileExtension: file.pathExtension), default: 0] += size
                }
            }
        }

        // 2. Image pipeline disk cache → Photos.
        totals[.photos, default: 0] += AttachmentFileStore.directorySize(RemoteImageStore.diskDirectory)

        // 3. Stickers are bundled on iOS — nothing cached, category kept for parity.
        totals[.stickers, default: 0] += 0

        // 4. Everything else in Caches + tmp → Misc.
        let known = [attachments.lastPathComponent, RemoteImageStore.diskDirectory.lastPathComponent]
        if let entries = try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil) {
            for entry in entries where !known.contains(entry.lastPathComponent) {
                totals[.misc, default: 0] += AttachmentFileStore.directorySize(entry)
            }
        }
        totals[.misc, default: 0] += AttachmentFileStore.directorySize(fm.temporaryDirectory)

        return totals
    }

    /// Clear every cache location the scan covers.
    static func clearAll() async {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        for entry in (try? fm.contentsOfDirectory(at: caches, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: entry)
        }
        for entry in (try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: entry)
        }
        URLCache.shared.removeAllCachedResponses()
        await RemoteImageStore.shared.purgeMemory()
    }
}

// MARK: - Data & Storage page

struct DataStorageView: View {
    @State private var storage: [CacheInventory.Category: Int64] = [:]
    @State private var scanning = true
    @State private var showClearConfirm = false
    @State private var clearing = false

    @State private var usage = DataUsageTracker.shared.snapshot()
    @State private var usageTab: UsageTab = .all
    @State private var showResetStats = false

    @State private var uploadQuality = UploadQuality.current

    enum UsageTab: String, CaseIterable, Identifiable {
        case all = "All", mobile = "Mobile", wifi = "Wi-Fi"
        var id: String { rawValue }
        var network: DataUsageTracker.NetworkKind? {
            switch self {
            case .all: return nil
            case .mobile: return .mobile
            case .wifi: return .wifi
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                storageSection
                usageSection
                uploadQualitySection
                autoDownloadSection
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Data and Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await rescan() }
        .confirmationDialog("Clear entire cache?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear Entire Cache", role: .destructive) {
                Task { await clearAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cached media will be re-downloaded when needed. Your messages are not affected.")
        }
        .confirmationDialog("Reset usage statistics?", isPresented: $showResetStats, titleVisibility: .visible) {
            Button("Reset Statistics", role: .destructive) {
                DataUsageTracker.shared.reset()
                usage = DataUsageTracker.Snapshot(counters: [:])
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Storage usage

    private var totalStorage: Int64 { storage.values.reduce(0, +) }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Storage Usage")

            if scanning {
                HStack {
                    Spacer()
                    ProgressView().tint(KlicColor.primary)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                Text(Self.bytesText(totalStorage))
                    .font(KlicFont.headline(26))
                    .foregroundStyle(KlicColor.textPrimary)

                segmentedBar

                VStack(spacing: 0) {
                    ForEach(CacheInventory.Category.allCases) { category in
                        HStack(spacing: 10) {
                            Circle().fill(category.color).frame(width: 10, height: 10)
                            Text(category.label)
                                .font(KlicFont.body(15))
                                .foregroundStyle(KlicColor.textPrimary)
                            Spacer()
                            Text(Self.bytesText(storage[category] ?? 0))
                                .font(KlicFont.body(14))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        .padding(.vertical, 7)
                    }
                }

                Button {
                    showClearConfirm = true
                } label: {
                    Text(clearing ? "Clearing…" : "Clear Entire Cache")
                        .font(KlicFont.headline(15))
                        .foregroundStyle(KlicColor.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(KlicColor.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(clearing || totalStorage == 0)
            }
        }
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var segmentedBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                if totalStorage > 0 {
                    ForEach(CacheInventory.Category.allCases) { category in
                        let bytes = storage[category] ?? 0
                        if bytes > 0 {
                            category.color
                                .frame(width: max(4, geo.size.width * CGFloat(bytes) / CGFloat(totalStorage)))
                        }
                    }
                } else {
                    KlicColor.surfaceRaised
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 12)
    }

    // MARK: Data usage

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Data Usage")

            Picker("Network", selection: $usageTab) {
                ForEach(UsageTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            let network = usageTab.network
            let sent = usage.total(network: network, direction: .sent)
            let received = usage.total(network: network, direction: .received)

            VStack(alignment: .leading, spacing: 4) {
                Text("Total Network Usage")
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                Text(Self.bytesText(sent + received))
                    .font(KlicFont.headline(26))
                    .foregroundStyle(KlicColor.textPrimary)
                HStack(spacing: 14) {
                    Label(Self.bytesText(sent), systemImage: "arrow.up")
                    Label(Self.bytesText(received), systemImage: "arrow.down")
                }
                .font(KlicFont.caption(12))
                .foregroundStyle(KlicColor.textMuted)
            }

            VStack(spacing: 0) {
                ForEach(DataUsageTracker.MediaType.allCases, id: \.rawValue) { type in
                    let typeSent = usage.bytes(network: network, type: type, direction: .sent)
                    let typeReceived = usage.bytes(network: network, type: type, direction: .received)
                    HStack {
                        Text(type.label)
                            .font(KlicFont.body(15))
                            .foregroundStyle(KlicColor.textPrimary)
                        Spacer()
                        Text(Self.bytesText(typeSent + typeReceived))
                            .font(KlicFont.body(14))
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    .padding(.vertical, 7)
                }
            }

            Button {
                showResetStats = true
            } label: {
                Text("Reset Statistics")
                    .font(KlicFont.headline(15))
                    .foregroundStyle(KlicColor.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(KlicColor.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
        .onAppear { usage = DataUsageTracker.shared.snapshot() }
    }

    // MARK: Upload quality

    private var uploadQualitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Upload Quality")
            ForEach(UploadQuality.allCases) { quality in
                Button {
                    uploadQuality = quality
                    UploadQuality.current = quality
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quality.label)
                                .font(KlicFont.body())
                                .foregroundStyle(KlicColor.textPrimary)
                            Text(quality.subtitle)
                                .font(KlicFont.caption(12))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        Spacer()
                        if uploadQuality == quality {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(KlicColor.primary)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Auto-download matrix

    private var autoDownloadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Media Auto-Download")
            Text("When off for the current network, media shows a download button instead of fetching automatically.")
                .font(KlicFont.caption(12))
                .foregroundStyle(KlicColor.textMuted)

            ForEach(AutoDownloadPrefs.Kind.allCases) { kind in
                AutoDownloadRow(kind: kind)
                if kind != AutoDownloadPrefs.Kind.allCases.last {
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(18)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(KlicFont.headline(17))
            .foregroundStyle(KlicColor.textPrimary)
    }

    private func rescan() async {
        scanning = true
        let totals = await Task.detached(priority: .utility) { CacheInventory.scan() }.value
        storage = totals
        scanning = false
    }

    private func clearAll() async {
        clearing = true
        await CacheInventory.clearAll()
        clearing = false
        await rescan()
    }

    static func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct AutoDownloadRow: View {
    let kind: AutoDownloadPrefs.Kind

    @State private var wifi: Bool
    @State private var cellular: Bool

    init(kind: AutoDownloadPrefs.Kind) {
        self.kind = kind
        _wifi = State(initialValue: AutoDownloadPrefs.allowed(kind, cellular: false))
        _cellular = State(initialValue: AutoDownloadPrefs.allowed(kind, cellular: true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.label)
                .font(KlicFont.medium())
                .foregroundStyle(KlicColor.textPrimary)
            HStack(spacing: 18) {
                Toggle("Wi-Fi", isOn: $wifi)
                    .onChange(of: wifi) { _, on in AutoDownloadPrefs.set(kind, cellular: false, allowed: on) }
                Toggle("Cellular", isOn: $cellular)
                    .onChange(of: cellular) { _, on in AutoDownloadPrefs.set(kind, cellular: true, allowed: on) }
            }
            .font(KlicFont.body(14))
            .foregroundStyle(KlicColor.textMuted)
            .tint(KlicColor.primary)
        }
        .padding(.vertical, 8)
    }
}

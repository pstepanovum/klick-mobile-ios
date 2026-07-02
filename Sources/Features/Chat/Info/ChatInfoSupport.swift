import SwiftUI
import Photos

// MARK: - Save to Photos (§8.4)

/// Add-only saver for the per-chat "Save to Photos" pref. "Always" saves incoming
/// photos/videos to the OS gallery as they are downloaded (photos save when their
/// bytes arrive through the image pipeline; videos stream and are only saved when
/// their file is explicitly downloaded).
enum MediaAutoSaver {
    private static func savedKey(_ conversationId: String) -> String {
        "chat.savedAttachments.\(conversationId)"
    }

    private static func alreadySaved(_ attachmentId: String, _ conversationId: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: savedKey(conversationId)) ?? []).contains(attachmentId)
    }

    private static func markSaved(_ attachmentId: String, _ conversationId: String) {
        var ids = UserDefaults.standard.stringArray(forKey: savedKey(conversationId)) ?? []
        ids.append(attachmentId)
        if ids.count > 500 { ids.removeFirst(ids.count - 500) }
        UserDefaults.standard.set(ids, forKey: savedKey(conversationId))
    }

    /// Save an incoming downloaded image when this chat's pref is "Always".
    static func autoSave(image: UIImage, attachmentId: String, conversationId: String, isMine: Bool) {
        guard !isMine,
              ChatLocalPrefs.saveToPhotos(conversationId) == .always,
              !alreadySaved(attachmentId, conversationId) else { return }
        markSaved(attachmentId, conversationId)   // optimistic — avoids double saves
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        }
    }

    /// Save an incoming downloaded video file when this chat's pref is "Always".
    static func autoSave(videoAt url: URL, attachmentId: String, conversationId: String, isMine: Bool) {
        guard !isMine,
              ChatLocalPrefs.saveToPhotos(conversationId) == .always,
              !alreadySaved(attachmentId, conversationId) else { return }
        markSaved(attachmentId, conversationId)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        }
    }
}

// MARK: - Shared info-page rows

/// The chat-info sections shared between the friend profile and the group info page:
/// "Media, links, docs", "Starred", "Manage storage" and the "Save to Photos" selector.
struct ChatInfoCommonRows: View {
    let conversationId: String
    let members: [ChatProfileTarget]

    @State private var saveMode: ChatLocalPrefs.SaveToPhotosMode
    @State private var showSaveDialog = false

    init(conversationId: String, members: [ChatProfileTarget]) {
        self.conversationId = conversationId
        self.members = members
        _saveMode = State(initialValue: ChatLocalPrefs.saveToPhotos(conversationId))
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                ChatMediaLinksDocsView(conversationId: conversationId, members: members)
            } label: {
                infoRow(icon: "photo.on.rectangle", title: "Media, links, docs")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            NavigationLink {
                StarredMessagesView(conversationId: conversationId, members: members)
            } label: {
                infoRow(icon: "star", title: "Starred")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            NavigationLink {
                ChatStorageManageView(conversationId: conversationId)
            } label: {
                infoRow(icon: "externaldrive", title: "Manage storage")
            }
            .buttonStyle(.plain)

            Divider().padding(.leading, 64).opacity(0.4)

            Button {
                showSaveDialog = true
            } label: {
                infoRow(icon: "square.and.arrow.down", title: "Save to Photos", value: saveMode.label)
            }
            .buttonStyle(.plain)
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
        .confirmationDialog("Save incoming media to Photos", isPresented: $showSaveDialog, titleVisibility: .visible) {
            ForEach(ChatLocalPrefs.SaveToPhotosMode.allCases) { mode in
                Button(mode.label) {
                    saveMode = mode
                    ChatLocalPrefs.setSaveToPhotos(mode, conversationId)
                    if mode == .always {
                        // Ask for add-only access up front so the first download can save.
                        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"Always\" saves incoming photos and downloaded videos from this chat to your photo library.")
        }
    }

    private func infoRow(icon: String, title: String, value: String? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KlicColor.primary)
                .frame(width: 32, height: 32)
                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
            Spacer()
            if let value {
                Text(value)
                    .font(KlicFont.body(14))
                    .foregroundStyle(KlicColor.textMuted)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KlicColor.textMuted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

// MARK: - Manage storage (§8.4)

/// This chat's cached bytes (from the §7.3 attachment store + the image pipeline's
/// entries for this conversation's media) with a clear button.
struct ChatStorageManageView: View {
    let conversationId: String

    @State private var loading = true
    @State private var unavailable = false
    @State private var attachments: [ConversationAttachment] = []
    @State private var totalBytes: Int64 = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 10) {
                    if loading {
                        ProgressView().tint(KlicColor.primary).padding(.vertical, 24)
                    } else {
                        Image(systemName: "externaldrive")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(KlicColor.primary)
                        Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                            .font(KlicFont.headline(28))
                            .foregroundStyle(KlicColor.textPrimary)
                        Text(unavailable
                             ? "Couldn't reach the server — showing nothing to clear."
                             : "Media from this chat stored on this device")
                            .font(KlicFont.caption(12))
                            .foregroundStyle(KlicColor.textMuted)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))

                if !loading, totalBytes > 0 {
                    Button {
                        clear()
                    } label: {
                        Text("Clear chat cache")
                            .font(KlicFont.headline(15))
                            .foregroundStyle(KlicColor.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .adaptiveWidth()
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Manage storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var all: [ConversationAttachment] = []
        var cursor: String?
        // Walk every page (capped) so cached bytes cover the whole history.
        for _ in 0..<20 {
            guard let page = try? await APIClient.shared.conversationAttachments(
                conversationId: conversationId, cursor: cursor, limit: 100
            ) else {
                unavailable = all.isEmpty
                break
            }
            all += page.items
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        attachments = all
        totalBytes = all.reduce(into: Int64(0)) { total, attachment in
            total += AttachmentFileStore.cachedBytes(attachmentId: attachment.id)
            total += RemoteImageStore.cachedBytes(forURLString: attachment.url)
        }
    }

    private func clear() {
        for attachment in attachments {
            AttachmentFileStore.removeCached(attachmentId: attachment.id)
            RemoteImageStore.removeCached(forURLString: attachment.url)
        }
        Task { await RemoteImageStore.shared.purgeMemory() }
        totalBytes = 0
    }
}

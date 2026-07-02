import SwiftUI
import QuickLook

/// Full-screen tabbed browser for a conversation's shared content (CALLS.md §8.4):
/// Media grid / Links list / Docs list. Media + docs come from the attachments
/// endpoint; links are a client-side URL scan over fetched message history with
/// fetch-back pagination.
struct ChatMediaLinksDocsView: View {
    let conversationId: String
    let members: [ChatProfileTarget]

    enum Tab: String, CaseIterable, Identifiable {
        case media = "Media", links = "Links", docs = "Docs"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .media

    // Media + docs (attachments endpoint, newest first).
    @State private var attachments: [ConversationAttachment] = []
    @State private var nextCursor: String?
    @State private var attachmentsLoaded = false
    @State private var loadingAttachments = false
    @State private var attachmentsUnavailable = false

    // Links (message-history scan).
    @State private var links: [ChatLink] = []
    @State private var oldestMessageAt: String?
    @State private var linksHaveMore = true
    @State private var loadingLinks = false

    @State private var viewerAttachmentId: String?

    struct ChatLink: Identifiable, Hashable {
        let id: String            // messageId + url
        let url: URL
        let messageBody: String
        let senderId: String
        let createdAt: String
    }

    private var media: [ConversationAttachment] {
        attachments.filter { $0.kind == "IMAGE" || $0.kind == "VIDEO" }
    }

    private var docs: [ConversationAttachment] {
        attachments.filter { $0.kind == "FILE" }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            switch tab {
            case .media: mediaGrid
            case .links: linksList
            case .docs: docsList
            }
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Media, links, docs")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !attachmentsLoaded { await loadMoreAttachments() }
            if links.isEmpty, linksHaveMore { await loadMoreLinks() }
        }
        .fullScreenCover(isPresented: Binding(
            get: { viewerAttachmentId != nil },
            set: { if !$0 { viewerAttachmentId = nil } }
        )) {
            if let viewerAttachmentId {
                MediaViewer(
                    items: galleryItems,
                    selectedAttachmentId: viewerAttachmentId,
                    onClose: { self.viewerAttachmentId = nil },
                    onReact: { _, _ in },
                    onDeleteForMe: { _ in },
                    onDeleteEveryone: { _ in }
                )
            }
        }
    }

    // MARK: Media

    private var galleryItems: [ChatMediaGalleryItem] {
        media.map { attachment in
            ChatMediaGalleryItem(
                id: attachment.id,
                attachmentId: attachment.id,
                messageId: attachment.messageId,
                url: attachment.url,
                isVideo: attachment.kind == "VIDEO",
                caption: "",
                senderName: senderName(attachment.senderId),
                createdAt: attachment.createdAt,
                reactions: [],
                isMine: false,
                durationMs: attachment.durationMs,
                thumbnailURL: attachment.kind == "IMAGE" ? attachment.url : nil
            )
        }
    }

    private var mediaGrid: some View {
        ScrollView {
            if attachmentsLoaded, media.isEmpty {
                emptyState(attachmentsUnavailable ? "Media browsing needs the latest server." : "No media shared yet.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)], spacing: 2) {
                    ForEach(media) { attachment in
                        MediaBrowserTile(attachment: attachment)
                            .onTapGesture { viewerAttachmentId = attachment.id }
                            .onAppear {
                                if attachment.id == attachments.last?.id {
                                    Task { await loadMoreAttachments() }
                                }
                            }
                    }
                }
                .padding(.horizontal, 2)
                if loadingAttachments { ProgressView().padding(.vertical, 14) }
            }
        }
    }

    // MARK: Links

    private var linksList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if !loadingLinks, links.isEmpty, !linksHaveMore {
                    emptyState("No links shared yet.")
                }
                ForEach(links) { link in
                    Link(destination: link.url) {
                        HStack(spacing: 12) {
                            Image(systemName: "link")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(KlicColor.primary)
                                .frame(width: 40, height: 40)
                                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.url.host() ?? link.url.absoluteString)
                                    .font(KlicFont.medium())
                                    .foregroundStyle(KlicColor.textPrimary)
                                    .lineLimit(1)
                                Text(link.url.absoluteString)
                                    .font(KlicFont.caption(12))
                                    .foregroundStyle(KlicColor.textMuted)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if link.id == links.last?.id, linksHaveMore {
                            Task { await loadMoreLinks() }
                        }
                    }
                }
                if linksHaveMore, links.isEmpty || loadingLinks {
                    ProgressView().padding(.vertical, 14)
                } else if linksHaveMore {
                    Button("Load older messages") { Task { await loadMoreLinks() } }
                        .font(KlicFont.body(14))
                        .foregroundStyle(KlicColor.primary)
                        .padding(.vertical, 10)
                }
            }
            .padding(16)
            .adaptiveWidth()
        }
    }

    // MARK: Docs

    private var docsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if attachmentsLoaded, docs.isEmpty {
                    emptyState(attachmentsUnavailable ? "Document browsing needs the latest server." : "No documents shared yet.")
                }
                ForEach(docs) { attachment in
                    DocBrowserRow(attachment: attachment, senderName: senderName(attachment.senderId))
                        .onAppear {
                            if attachment.id == attachments.last?.id {
                                Task { await loadMoreAttachments() }
                            }
                        }
                }
                if loadingAttachments { ProgressView().padding(.vertical, 14) }
            }
            .padding(16)
            .adaptiveWidth()
        }
    }

    // MARK: Loading

    private func loadMoreAttachments() async {
        guard !loadingAttachments else { return }
        if attachmentsLoaded, nextCursor == nil { return }
        loadingAttachments = true
        defer { loadingAttachments = false }
        // try? — tolerate a server without the endpoint (graceful empty state).
        guard let page = try? await APIClient.shared.conversationAttachments(
            conversationId: conversationId, cursor: nextCursor, limit: 60
        ) else {
            attachmentsUnavailable = !attachmentsLoaded
            attachmentsLoaded = true
            nextCursor = nil
            return
        }
        attachmentsLoaded = true
        attachments += page.items.filter { item in !attachments.contains(where: { $0.id == item.id }) }
        nextCursor = page.nextCursor
    }

    private func loadMoreLinks() async {
        guard !loadingLinks, linksHaveMore else { return }
        loadingLinks = true
        defer { loadingLinks = false }
        let batch = (try? await APIClient.shared.messages(
            conversationId: conversationId, before: oldestMessageAt, limit: 50
        )) ?? []
        guard !batch.isEmpty else {
            linksHaveMore = false
            return
        }
        // messages come newest-first from the API
        oldestMessageAt = batch.last?.createdAt
        linksHaveMore = batch.count >= 50
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for message in batch where !message.body.isEmpty && !message.isDeleted {
            let body = message.body
            let matches = detector?.matches(in: body, range: NSRange(body.startIndex..., in: body)) ?? []
            for match in matches {
                guard let url = match.url, url.scheme?.hasPrefix("http") == true else { continue }
                let link = ChatLink(
                    id: "\(message.id)|\(url.absoluteString)",
                    url: url,
                    messageBody: body,
                    senderId: message.senderId,
                    createdAt: message.createdAt
                )
                if !links.contains(where: { $0.id == link.id }) { links.append(link) }
            }
        }
        // Keep digging while nothing was found yet (fetch-back), without spinning forever.
        if links.isEmpty, linksHaveMore, batch.count >= 50, links.count < 200 {
            await loadMoreLinks()
        }
    }

    private func senderName(_ userId: String) -> String {
        members.first(where: { $0.id == userId })?.displayName ?? "User"
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(KlicFont.body(14))
            .foregroundStyle(KlicColor.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }
}

// MARK: - Tiles / rows

private struct MediaBrowserTile: View {
    let attachment: ConversationAttachment

    var body: some View {
        GeometryReader { geo in
            Group {
                if attachment.kind == "VIDEO" {
                    ZStack {
                        Color.black.opacity(0.85)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                } else {
                    RemoteImage(url: URL(string: attachment.url)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            KlicColor.surfaceRaised.overlay(
                                Image(systemName: "photo").foregroundStyle(KlicColor.textMuted)
                            )
                        default:
                            KlicColor.surfaceRaised.overlay(LoadingCircle())
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
    }
}

private struct DocBrowserRow: View {
    let attachment: ConversationAttachment
    let senderName: String

    @ObservedObject private var store = AttachmentFileStore.shared
    @State private var previewURL: IdentifiedURL?
    @State private var shareURL: IdentifiedURL?

    struct IdentifiedURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var body: some View {
        Button {
            open()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if let progress = store.progress[attachment.id] {
                        ProgressView(value: progress)
                            .progressViewStyle(.circular)
                            .tint(KlicColor.primary)
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(KlicColor.primary)
                    }
                }
                .frame(width: 40, height: 40)
                .background(KlicColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName ?? "File")
                        .font(KlicFont.medium())
                        .foregroundStyle(KlicColor.textPrimary)
                        .lineLimit(1)
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file)) · \(senderName)")
                        .font(KlicFont.caption(12))
                        .foregroundStyle(KlicColor.textMuted)
                }
                Spacer()
            }
            .padding(12)
            .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fullScreenCover(item: $previewURL) { file in
            QuickLookPreview(url: file.url).ignoresSafeArea()
        }
        .sheet(item: $shareURL) { file in
            ShareSheet(activityItems: [file.url])
        }
    }

    private func open() {
        Task {
            guard let local = try? await AttachmentFileStore.shared.download(attachment.asAttachment) else { return }
            if QLPreviewController.canPreview(local as NSURL) {
                previewURL = IdentifiedURL(url: local)
            } else {
                shareURL = IdentifiedURL(url: local)
            }
        }
    }
}

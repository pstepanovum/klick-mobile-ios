import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

struct ChatView: View {
    let conversation: Conversation
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var socket = SocketService.shared

    @State private var messages: [Message] = []
    @State private var hasMore = false
    @State private var isLoadingMore = false
    @State private var initialLoadDone = false
    @State private var draft = ""
    @State private var scrollProxy: ScrollViewProxy?
    @State private var atBottom = true

    @StateObject private var recorder = AudioRecorder()
    @FocusState private var isComposerFocused: Bool
    @State private var pickedItem: PhotosPickerItem?
    @State private var showAttachMenu = false
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var showStickers = false
    @State private var uploading = false

    // Reply / long-press menu / local-delete state.
    @State private var replyingTo: Message?
    @State private var menuTarget: Message?
    @State private var deleteTarget: Message?
    @State private var hiddenIds: Set<String> = []
    @State private var lastTypingSent = Date.distantPast
    @State private var isStartingCall = false
    @State private var selectedMember: ChatProfileTarget?
    @State private var openedConversation: Conversation?
    @State private var groupDetails: GroupConversationDetails?

    private enum AttachAction { case photos, camera, file }
    @State private var pendingAttach: AttachAction?

    private var isDirect: Bool { conversation.type == "DIRECT" }
    var title: String {
        if let groupTitle = groupDetails?.title?.trimmingCharacters(in: .whitespaces), !groupTitle.isEmpty {
            return groupTitle
        }
        if let groupTitle = conversation.title?.trimmingCharacters(in: .whitespaces), !groupTitle.isEmpty {
            return groupTitle
        }
        if isDirect { return conversation.members.first?.displayName ?? "Chat" }
        let members = memberTargets.map(\.displayName).joined(separator: ", ")
        return members.isEmpty ? "Group" : members
    }
    var myId: String? { session.currentUser?.id }
    private var memberCount: Int { memberTargets.count }
    private var memberTargets: [ChatProfileTarget] {
        if let groupDetails {
            return groupDetails.members.map {
                ChatProfileTarget(id: $0.id, username: $0.username, displayName: $0.displayName, avatarUrl: $0.avatarUrl)
            }
        }
        var ordered: [ChatProfileTarget] = conversation.members.map {
            ChatProfileTarget(id: $0.id, username: $0.username, displayName: $0.displayName, avatarUrl: $0.avatarUrl)
        }
        if let me = session.currentUser {
            ordered.append(ChatProfileTarget(id: me.id, username: me.username, displayName: me.displayName, avatarUrl: me.avatarUrl))
        }
        var seen = Set<String>()
        return ordered.filter { seen.insert($0.id).inserted }
    }
    private var groupAvatarUrl: String? { groupDetails?.avatarUrl ?? conversation.avatarUrl }

    /// Messages minus anything the user deleted just for themselves (local-only).
    private var visibleMessages: [Message] { messages.filter { !hiddenIds.contains($0.id) } }

    /// Whether the peer is currently typing in this conversation (auto-expires).
    private var peerIsTyping: Bool {
        guard let at = socket.typingByConversation[conversation.id] else { return false }
        return Date().timeIntervalSince(at) < 6
    }

    var body: some View {
        messageList
            // The composer floats over the chat as a bottom inset: transparent background so
            // messages scroll behind it, and the inset reserves space so the newest message
            // is never hidden/clipped behind it (incl. when the keyboard opens).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if let target = replyingTo {
                        ReplyComposerBar(
                            authorName: target.senderId == myId ? "yourself" : title,
                            preview: previewText(for: target),
                            onCancel: { withAnimation { replyingTo = nil } }
                        )
                    }
                    composer
                }
            }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KlicColor.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) { chatHeader }
            ToolbarItem(placement: .topBarTrailing) {
                if isDirect {
                    HStack(spacing: 20) {
                        Button { Task { await startCall(kind: "AUDIO") } } label: {
                            Image(systemName: "phone.fill").font(.system(size: 18))
                        }
                        .disabled(isStartingCall)
                        Button { Task { await startCall(kind: "VIDEO") } } label: {
                            Image(systemName: "video.fill").font(.system(size: 18))
                        }
                        .disabled(isStartingCall)
                    }
                }
            }
        }
        .overlay {
            if let target = menuTarget {
                MessageActionsOverlay(
                    message: target,
                    isMine: target.senderId == myId,
                    peerName: title,
                    onReact: { emoji in
                        Task { await react(target, emoji: emoji) }
                        withAnimation(.easeOut(duration: 0.15)) { menuTarget = nil }
                    },
                    onReply: { replyingTo = target; isComposerFocused = true },
                    onCopy: { UIPasteboard.general.string = target.body },
                    onDelete: { deleteTarget = target },
                    onDismiss: { withAnimation(.easeOut(duration: 0.15)) { menuTarget = nil } }
                )
                .transition(.opacity)
            }
        }
        .confirmationDialog("Delete message", isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button("Delete for me", role: .destructive) { if let m = deleteTarget { deleteForMe(m) }; dismissMenu() }
            if deleteTarget?.senderId == myId {
                Button("Delete for everyone", role: .destructive) {
                    if let m = deleteTarget { Task { await deleteEveryone(m) } }; dismissMenu()
                }
            }
            Button("Cancel", role: .cancel) { dismissMenu() }
        }
        .task {
            hiddenIds = Self.loadHidden(conversation.id)
            await load()
            if !isDirect { await loadGroupDetails() }
            scrollToBottom(animated: false)
            initialLoadDone = true
        }
        .onAppear { isComposerFocused = true }
        .onDisappear { emitTyping(false) }
        .onChange(of: draft) { _, value in emitTyping(!value.trimmingCharacters(in: .whitespaces).isEmpty) }
        .onReceive(socket.$lastMessage.compactMap { $0 }) { msg in
            guard msg.conversationId == conversation.id else { return }
            // Upsert by id — the server echoes our own sends back for multi-device sync.
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) { messages[idx] = msg }
            else { messages.append(msg) }
            markRead()
            scrollToBottom()
        }
        .onReceive(socket.$lastRead.compactMap { $0 }) { applyReceipt($0, status: "read") }
        .onReceive(socket.$lastDelivered.compactMap { $0 }) { applyReceipt($0, status: "delivered") }
        .onReceive(socket.$lastReaction.compactMap { $0 }) { update in
            guard update.conversationId == conversation.id,
                  let idx = messages.firstIndex(where: { $0.id == update.messageId }) else { return }
            messages[idx].reactions = update.reactions
        }
        .onReceive(socket.$lastDeleted.compactMap { $0 }) { update in
            guard update.conversationId == conversation.id,
                  let idx = messages.firstIndex(where: { $0.id == update.messageId }) else { return }
            messages[idx].deletedAt = ISO8601DateFormatter().string(from: Date())
            messages[idx].reactions = []
        }
        .navigationDestination(item: $openedConversation) { opened in
            ChatView(conversation: opened)
        }
        .navigationDestination(item: $selectedMember) { member in
            ProfileView(
                userId: member.id,
                username: member.username,
                displayName: member.displayName,
                avatarUrl: member.avatarUrl,
                onCall: { kind in Task { await startDirectCall(with: member, kind: kind) } },
                onMessage: { Task { await openDirectChat(with: member) } },
                onInvite: { Task { await sendInvite(to: member) } }
            )
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private func dismissMenu() {
        deleteTarget = nil
        withAnimation(.easeOut(duration: 0.15)) { menuTarget = nil }
    }

    // Tappable header → the peer's profile, with live presence underneath the name.
    @ViewBuilder private var chatHeader: some View {
        if isDirect, let peer = conversation.members.first {
            NavigationLink {
                ProfileView(
                    userId: peer.id, username: peer.username,
                    displayName: peer.displayName, avatarUrl: peer.avatarUrl
                ) { kind in Task { await startCall(kind: kind) } }
            } label: {
                HStack(spacing: 8) {
                    AvatarView(url: peer.avatarUrl, name: peer.displayName, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(peer.displayName)
                            .font(KlicFont.headline(16))
                            .foregroundStyle(KlicColor.textPrimary)
                        if let sub = headerSubtitle {
                            Text(sub)
                                .font(KlicFont.caption(11))
                                .foregroundStyle(isPeerOnline ? KlicColor.primary : KlicColor.textMuted)
                        }
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .background(KlicColor.surface, in: Capsule())
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                GroupInfoView(
                    conversationId: conversation.id,
                    title: title,
                    initialDetails: groupDetails,
                    fallbackMembers: memberTargets,
                    onSelectMember: { member in
                        selectedMember = member
                    },
                    onUpdated: { details in
                        groupDetails = details
                    },
                    onDeleted: {
                        dismiss()
                    }
                )
            } label: {
                HStack(spacing: 8) {
                    AvatarView(url: groupAvatarUrl, name: title, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(KlicFont.headline(16))
                            .foregroundStyle(KlicColor.textPrimary)
                        if let sub = headerSubtitle {
                            Text(sub)
                                .font(KlicFont.caption(11))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 12)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .background(KlicColor.surface, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var isPeerOnline: Bool {
        guard isDirect else { return false }
        guard let id = conversation.members.first?.id else { return false }
        return socket.presence[id]?.online == true
    }

    private var headerSubtitle: String? {
        if !isDirect {
            return "\(memberCount) members"
        }
        guard let id = conversation.members.first?.id else { return nil }
        if socket.presence[id]?.online == true { return "Online" }
        guard let date = socket.presence[id]?.lastSeen else { return nil }
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) { f.dateFormat = "HH:mm"; return "last seen \(f.string(from: date))" }
        if cal.isDateInYesterday(date) { return "last seen yesterday" }
        f.dateFormat = "MMM d"; return "last seen \(f.string(from: date))"
    }

    // Advance the ticks on the user's own messages when a receipt arrives.
    private func applyReceipt(_ receipt: SocketService.Receipt, status: String) {
        guard receipt.conversationId == conversation.id, receipt.userId != myId else { return }
        for i in messages.indices where messages[i].senderId == myId {
            guard let created = SocketService.parseDate(messages[i].createdAt), created <= receipt.at else { continue }
            if status == "read" { messages[i].status = "read" }
            else if messages[i].status != "read" { messages[i].status = "delivered" }
        }
    }

    // MARK: Message list

    private var messageList: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        } else if hasMore {
                            Color.clear.frame(height: 1)
                                .onAppear { Task { await loadMore() } }
                        }
                        let items = visibleMessages
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, msg in
                            let isMine = msg.senderId == myId
                            let isFirst = idx == 0 || items[idx - 1].senderId != msg.senderId
                            let isLast  = idx == items.count - 1 || items[idx + 1].senderId != msg.senderId

                            if idx == 0 || !sameDay(items[idx - 1].createdAt, msg.createdAt) {
                                DateSeparator(dateString: msg.createdAt)
                            }

                            MessageBubble(
                                message: msg,
                                isMine: isMine,
                                isFirst: isFirst,
                                isLast: isLast,
                                isGroupChat: !isDirect,
                                senderName: senderDisplayName(for: msg.senderId),
                                senderAvatarURL: senderAvatarURL(for: msg.senderId),
                                replyAuthorName: msg.replyTo.map { replyAuthorName(for: $0.senderId) } ?? "",
                                onCallBack: { kind in Task { await startCall(kind: kind) } },
                                onAvatarTap: isDirect ? nil : { openProfile(for: msg.senderId) },
                                onLongPress: { withAnimation(.easeIn(duration: 0.15)) { menuTarget = msg } },
                                onReactionTap: { emoji in Task { await react(msg, emoji: emoji) } }
                            )
                            .id(msg.id)
                        }
                        if peerIsTyping {
                            HStack { TypingDots(); Spacer(minLength: 56) }
                                .padding(.vertical, 1)
                                .id("typing-indicator")
                                .transition(.opacity)
                        }
                        // Bottom marker: reports whether it's within the viewport, so the
                        // scroll-down button reliably reflects the real scroll position.
                        Color.clear.frame(height: 1).id("bottom-sentinel")
                            .background(GeometryReader { g in
                                Color.clear.preference(
                                    key: AtBottomKey.self,
                                    value: g.frame(in: .named("chatScroll")).maxY <= outer.size.height + 60
                                )
                            })
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .coordinateSpace(.named("chatScroll"))
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.hidden)
                // Scrolling must NOT dismiss the keyboard; a single tap on the chat does.
                .scrollDismissesKeyboard(.never)
                .simultaneousGesture(TapGesture().onEnded { isComposerFocused = false })
                .onPreferenceChange(AtBottomKey.self) { atBottom = $0 }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom {
                        // Programmatic scroll keeps the keyboard open (unlike a user drag).
                        Button { scrollToBottom() } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(KlicColor.textPrimary)
                                .frame(width: 40, height: 40)
                                .background(KlicColor.surfaceRaised, in: Circle())
                                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 12)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: atBottom)
                .onAppear { scrollProxy = proxy }
                .onChange(of: peerIsTyping) { _, typing in if typing { scrollToBottom() } }
                .onChange(of: visibleMessages.count) { _, _ in
                    if atBottom { scrollToBottom(animated: false) }
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        MessageComposer(
            draft: $draft,
            focused: $isComposerFocused,
            recorder: recorder,
            uploading: uploading,
            onAttach: { showAttachMenu = true },
            onStickers: { showStickers = true },
            onSend: { Task { await send() } },
            onStartRecording: { recorder.start() },
            onCancelRecording: { recorder.cancel() },
            onSendVoice: { Task { await stopAndSendVoice() } }
        )
        .sheet(isPresented: $showAttachMenu) {
            AttachSheet(
                onPhotos: { pendingAttach = .photos; showAttachMenu = false },
                onCamera: { pendingAttach = .camera; showAttachMenu = false },
                onFile:   { pendingAttach = .file;   showAttachMenu = false }
            )
            .presentationDetents([.height(210)])
            .presentationDragIndicator(.visible)
            .presentationBackground(KlicColor.surface)
        }
        .onChange(of: showAttachMenu) { _, showing in
            if !showing, let action = pendingAttach {
                pendingAttach = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    switch action {
                    case .photos: showPhotos = true
                    case .camera: showCamera = true
                    case .file:   showFileImporter = true
                    }
                }
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $pickedItem, matching: .any(of: [.images, .videos]))
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await handlePicked(item); pickedItem = nil }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in Task { await sendImage(img) } }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { await sendFile(url) } }
        }
        .sheet(isPresented: $showStickers) {
            StickerPicker { id in
                showStickers = false
                Task { await sendSticker(id) }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: Helpers

    private func sameDay(_ a: String, _ b: String) -> Bool {
        String(a.prefix(10)) == String(b.prefix(10))
    }

    private func scrollToBottom(animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { scrollProxy?.scrollTo("bottom-sentinel", anchor: .bottom) }
        } else {
            scrollProxy?.scrollTo("bottom-sentinel", anchor: .bottom)
        }
    }

    private func upsert(_ msg: Message) {
        if let idx = messages.firstIndex(where: { $0.id == msg.id }) { messages[idx] = msg }
        else { messages.append(msg) }
    }

    // MARK: Reply / reactions / delete / typing

    private func react(_ message: Message, emoji: String) async {
        if let updated = try? await APIClient.shared.react(
            conversationId: conversation.id, messageId: message.id, emoji: emoji),
           let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx].reactions = updated
        }
    }

    private func deleteForMe(_ message: Message) {
        hiddenIds.insert(message.id)
        Self.saveHidden(hiddenIds, conversation.id)
    }

    private func deleteEveryone(_ message: Message) async {
        try? await APIClient.shared.deleteForEveryone(conversationId: conversation.id, messageId: message.id)
        if let idx = messages.firstIndex(where: { $0.id == message.id }) {
            messages[idx].deletedAt = ISO8601DateFormatter().string(from: Date())
            messages[idx].reactions = []
        }
    }

    /// Throttled typing signal — re-sent at most every 2s while typing, cleared on stop.
    private func emitTyping(_ isTyping: Bool) {
        if isTyping {
            let now = Date()
            guard now.timeIntervalSince(lastTypingSent) > 2 else { return }
            lastTypingSent = now
            socket.emit("typing", ["conversationId": conversation.id, "isTyping": true])
        } else {
            lastTypingSent = .distantPast
            socket.emit("typing", ["conversationId": conversation.id, "isTyping": false])
        }
    }

    private func previewText(for message: Message) -> String {
        if !message.body.isEmpty { return message.body }
        if message.isSticker { return "Sticker" }
        if let a = message.attachments.first {
            switch a.kind {
            case "IMAGE": return "Photo"
            case "VOICE": return "Voice message"
            case "VIDEO": return "Video"
            default:      return "File"
            }
        }
        if message.isCallEvent { return message.call?.isVideo == true ? "Video call" : "Voice call" }
        return "Message"
    }

    private static func hiddenKey(_ convId: String) -> String { "hiddenMessages.\(convId)" }
    private static func loadHidden(_ convId: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: hiddenKey(convId)) ?? [])
    }
    private static func saveHidden(_ ids: Set<String>, _ convId: String) {
        UserDefaults.standard.set(Array(ids), forKey: hiddenKey(convId))
    }

    private func load() async {
        let batch = (try? await APIClient.shared.messages(conversationId: conversation.id)) ?? []
        messages = batch.reversed()
        hasMore = batch.count >= 50
        markRead()
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore, initialLoadDone else { return }
        isLoadingMore = true
        let anchorId = messages.first?.id
        let before = messages.first?.createdAt
        let batch = (try? await APIClient.shared.messages(conversationId: conversation.id, before: before)) ?? []
        messages.insert(contentsOf: batch.reversed(), at: 0)
        hasMore = batch.count >= 50
        isLoadingMore = false
        if let anchorId {
            DispatchQueue.main.async { scrollProxy?.scrollTo(anchorId, anchor: .top) }
        }
    }

    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        let replyId = replyingTo?.id
        draft = ""
        withAnimation { replyingTo = nil }
        if let msg = try? await APIClient.shared.send(conversationId: conversation.id, body: body, replyToId: replyId) {
            upsert(msg)
            scrollToBottom()
        }
    }

    private func sendSticker(_ id: String) async {
        let replyId = replyingTo?.id
        withAnimation { replyingTo = nil }
        if let msg = try? await APIClient.shared.sendSticker(conversationId: conversation.id, stickerId: id, replyToId: replyId) {
            upsert(msg)
            scrollToBottom()
        }
    }

    // MARK: Media

    private func handlePicked(_ item: PhotosPickerItem) async {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        if isVideo {
            if let movie = try? await item.loadTransferable(type: Movie.self) { await sendVideo(movie.url) }
        } else if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
            await sendImage(img)
        }
    }

    private func sendImage(_ image: UIImage) async {
        guard let (data, w, h) = Media.encodeImage(image) else { return }
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

    private func sendFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        await sendAttachment(kind: "FILE", contentType: Media.mime(for: url, fallback: "application/octet-stream"),
                             data: data, fileName: url.lastPathComponent)
    }

    private func stopAndSendVoice() async {
        guard let (data, durationMs, waveform) = recorder.stop() else { return }
        await sendAttachment(kind: "VOICE", contentType: "audio/m4a", data: data, durationMs: durationMs, waveform: waveform)
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

    private func markRead() {
        socket.emit("message:read", ["conversationId": conversation.id])
    }

    private func startCall(kind: String) async {
        guard isDirect else { return }
        guard !isStartingCall else { return }
        isStartingCall = true
        defer { isStartingCall = false }
        guard let s = try? await APIClient.shared.startCall(conversationId: conversation.id, kind: kind)
        else { return }
        CallKitManager.shared.startOutgoing(
            s,
            peerName: title,
            peerId: conversation.members.first?.id,
            peerAvatarUrl: conversation.members.first?.avatarUrl
        )
    }

    private func senderDisplayName(for userId: String) -> String {
        if userId == myId {
            return session.currentUser?.displayName ?? "You"
        }
        return memberTargets.first(where: { $0.id == userId })?.displayName ?? "User"
    }

    private func senderAvatarURL(for userId: String) -> String? {
        if userId == myId {
            return session.currentUser?.avatarUrl
        }
        return memberTargets.first(where: { $0.id == userId })?.avatarUrl
    }

    private func replyAuthorName(for userId: String) -> String {
        userId == myId ? "You" : senderDisplayName(for: userId)
    }

    private func openProfile(for userId: String) {
        guard userId != myId else { return }
        guard let member = memberTargets.first(where: { $0.id == userId }) else { return }
        selectedMember = member
    }

    private func openDirectChat(with member: ChatProfileTarget) async {
        guard member.id != myId else { return }
        if let conversation = try? await APIClient.shared.openConversation(userId: member.id) {
            await MainActor.run {
                self.selectedMember = nil
                self.openedConversation = conversation
            }
        }
    }

    private func startDirectCall(with member: ChatProfileTarget, kind: String) async {
        guard member.id != myId else { return }
        guard let directConversation = try? await APIClient.shared.openConversation(userId: member.id),
              let session = try? await APIClient.shared.startCall(conversationId: directConversation.id, kind: kind)
        else { return }
        CallKitManager.shared.startOutgoing(
            session,
            peerName: member.displayName,
            peerId: member.id,
            peerAvatarUrl: member.avatarUrl
        )
    }

    private func sendInvite(to member: ChatProfileTarget) async {
        guard member.id != myId else { return }
        _ = try? await APIClient.shared.sendFriendRequest(userId: member.id)
    }

    private func loadGroupDetails() async {
        groupDetails = try? await APIClient.shared.conversationDetails(id: conversation.id)
    }
}

/// True when the chat's bottom marker is within the viewport (used to hide the scroll-down button).
private struct AtBottomKey: PreferenceKey {
    static var defaultValue: Bool = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

private struct ChatProfileTarget: Identifiable, Hashable {
    let id: String
    let username: String
    let displayName: String
    let avatarUrl: String?
}

private struct GroupInfoView: View {
    let conversationId: String
    let title: String
    let initialDetails: GroupConversationDetails?
    let fallbackMembers: [ChatProfileTarget]
    let onSelectMember: (ChatProfileTarget) -> Void
    let onUpdated: (GroupConversationDetails) -> Void
    let onDeleted: () -> Void

    var body: some View {
        GroupInfoContent(
            conversationId: conversationId,
            fallbackTitle: title,
            initialDetails: initialDetails,
            fallbackMembers: fallbackMembers,
            onSelectMember: onSelectMember,
            onUpdated: onUpdated,
            onDeleted: onDeleted
        )
    }
}

private struct GroupInfoContent: View {
    let conversationId: String
    let fallbackTitle: String
    let initialDetails: GroupConversationDetails?
    let fallbackMembers: [ChatProfileTarget]
    let onSelectMember: (ChatProfileTarget) -> Void
    let onUpdated: (GroupConversationDetails) -> Void
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var details: GroupConversationDetails?
    @State private var loading = false
    @State private var editing = false
    @State private var editTitle = ""
    @State private var editDescription = ""
    @State private var searchMembers = false
    @State private var memberQuery = ""
    @State private var addSheet = false
    @State private var pickedCover: PhotosPickerItem?
    @State private var savingCover = false
    @State private var leaving = false
    @State private var error: String?
    @State private var showDeleteDialog = false

    private var resolvedDetails: GroupConversationDetails? { details ?? initialDetails }
    private var resolvedTitle: String { resolvedDetails?.title?.trimmingCharacters(in: .whitespaces).isEmpty == false ? (resolvedDetails?.title ?? fallbackTitle) : fallbackTitle }
    private var resolvedDescription: String? {
        guard let text = resolvedDetails?.description?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
    private var isAdmin: Bool { resolvedDetails?.isAdmin == true }
    private var members: [GroupConversationDetails.Member] {
        if let loaded = resolvedDetails?.members, !loaded.isEmpty {
            return loaded
        }
        return fallbackMembers.map {
            GroupConversationDetails.Member(
                id: $0.id,
                username: $0.username,
                displayName: $0.displayName,
                avatarUrl: $0.avatarUrl,
                joinedAt: "",
                isMe: false
            )
        }
    }
    private var filteredMembers: [GroupConversationDetails.Member] {
        let q = memberQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter {
            $0.displayName.lowercased().contains(q) || $0.username.lowercased().contains(q)
        }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    coverPicker
                    VStack(spacing: 6) {
                        Text(resolvedTitle)
                            .font(KlicFont.headline(22))
                            .foregroundStyle(KlicColor.textPrimary)
                            .multilineTextAlignment(.center)
                        if let description = resolvedDescription {
                            Text(description)
                                .font(KlicFont.body(14))
                                .foregroundStyle(KlicColor.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        Text("\(members.count) members")
                            .font(KlicFont.caption())
                            .foregroundStyle(KlicColor.textMuted)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(KlicColor.background)
            }

            Section {
                HStack(spacing: 12) {
                    actionButton(title: "Audio", systemName: "phone.fill", disabled: true) {}
                    actionButton(title: "Video", systemName: "video.fill", disabled: true) {}
                    actionButton(title: "Add", systemName: "person.badge.plus.fill", disabled: !isAdmin) {
                        addSheet = true
                    }
                    actionButton(title: "Search", systemName: "magnifyingglass") {
                        withAnimation(.easeInOut(duration: 0.15)) { searchMembers.toggle() }
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(KlicColor.background)
            }

            if searchMembers {
                Section {
                    KlicTextField(placeholder: "Search members", text: $memberQuery)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(KlicColor.background)
                }
            }

            if editing {
                Section("Edit group") {
                    TextField("Group name", text: $editTitle)
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                    TextField("Description", text: $editDescription, axis: .vertical)
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                        .lineLimit(3, reservesSpace: true)
                    Button("Save changes") { Task { await saveEdits() } }
                        .foregroundStyle(KlicColor.primary)
                }
            } else {
                Section {
                    NavigationLink("View all members") {
                        GroupMemberListView(members: filteredMembers, onSelectMember: onSelectMember)
                    }
                    .foregroundStyle(KlicColor.textPrimary)

                    if isAdmin {
                        Button("Delete Group", role: .destructive) {
                            showDeleteDialog = true
                        }
                    } else {
                        Button("Exit Group", role: .destructive) {
                            Task { await leaveGroup() }
                        }
                        .disabled(leaving)
                    }
                }
            }

            if !filteredMembers.isEmpty {
                Section("Members") {
                    ForEach(filteredMembers.prefix(6)) { member in
                        memberRow(member)
                    }
                }
            }

            if let error {
                Section {
                    Text(error)
                        .font(KlicFont.caption())
                        .foregroundStyle(.red)
                        .listRowBackground(KlicColor.background)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Group Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isAdmin {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "Done" : "Edit") {
                        if editing {
                            editing = false
                        } else {
                            editTitle = resolvedDetails?.title ?? fallbackTitle
                            editDescription = resolvedDetails?.description ?? ""
                            editing = true
                        }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $addSheet) {
            AddGroupMembersSheet(conversationId: conversationId, currentMemberIds: Set(members.map(\.id))) { updated in
                apply(updated)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: pickedCover) { _, item in
            guard let item else { return }
            Task { await uploadCover(item) }
        }
        .confirmationDialog("Delete this group?", isPresented: $showDeleteDialog, titleVisibility: .visible) {
            Button("Delete Group", role: .destructive) {
                Task { await deleteGroup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the group chat and all of its messages for everyone.")
        }
    }

    @ViewBuilder
    private var coverPicker: some View {
        if isAdmin {
            PhotosPicker(selection: $pickedCover, matching: .images) {
                coverView.overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KlicColor.onPrimary)
                        .frame(width: 34, height: 34)
                        .background(KlicColor.primary, in: Circle())
                        .overlay(Circle().stroke(KlicColor.background, lineWidth: 3))
                        .padding(10)
                }
            }
            .buttonStyle(.plain)
        } else {
            coverView
        }
    }

    private var coverView: some View {
        AvatarView(url: resolvedDetails?.avatarUrl, name: resolvedTitle, size: 104)
            .overlay {
                if savingCover {
                    ProgressView()
                        .tint(KlicColor.primary)
                }
            }
    }

    private func actionButton(title: String, systemName: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(disabled ? KlicColor.textMuted : KlicColor.onPrimary)
                    .frame(width: 48, height: 48)
                    .background(disabled ? KlicColor.surfaceRaised : KlicColor.primary, in: Circle())
                Text(title)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func memberRow(_ member: GroupConversationDetails.Member) -> some View {
        Button {
            onSelectMember(ChatProfileTarget(id: member.id, username: member.username, displayName: member.displayName, avatarUrl: member.avatarUrl))
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: member.avatarUrl, name: member.displayName, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(member.displayName)
                            .font(KlicFont.medium())
                            .foregroundStyle(KlicColor.textPrimary)
                        if member.isMe {
                            Text("You")
                                .font(KlicFont.caption(11))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                    }
                    Text("@\(member.username)")
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KlicColor.textMuted)
            }
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let fetched = try? await APIClient.shared.conversationDetails(id: conversationId) {
            apply(fetched)
        }
    }

    private func saveEdits() async {
        guard let current = resolvedDetails else { return }
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let description = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated = try await APIClient.shared.updateGroupConversation(
                id: conversationId,
                title: title,
                description: description.isEmpty ? nil : description
            )
            editing = false
            apply(updated)
        } catch let e as APIError {
            self.error = e.userMessage
            apply(current)
        } catch {
            self.error = "Couldn't save the group right now."
        }
    }

    private func uploadCover(_ item: PhotosPickerItem) async {
        savingCover = true
        defer { savingCover = false }
        error = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let (jpeg, _, _) = Media.encodeImage(image) else { return }
            let ticket = try await APIClient.shared.requestGroupAvatarUpload(
                conversationId: conversationId,
                contentType: "image/jpeg",
                byteSize: jpeg.count
            )
            try await APIClient.shared.uploadData(jpeg, to: ticket.uploadUrl, contentType: "image/jpeg")
            let updated = try await APIClient.shared.updateGroupConversation(id: conversationId, avatarKey: ticket.key)
            apply(updated)
        } catch let e as APIError {
            self.error = e.userMessage
        } catch {
            self.error = "Couldn't upload the group cover."
        }
    }

    private func leaveGroup() async {
        leaving = true
        defer { leaving = false }
        do {
            _ = try await APIClient.shared.leaveGroup(conversationId: conversationId)
            dismiss()
        } catch let e as APIError {
            self.error = e.userMessage
        } catch {
            self.error = "Couldn't leave the group."
        }
    }

    private func deleteGroup() async {
        leaving = true
        defer { leaving = false }
        do {
            _ = try await APIClient.shared.deleteGroup(conversationId: conversationId)
            onDeleted()
            dismiss()
        } catch let e as APIError {
            self.error = e.userMessage
        } catch {
            self.error = "Couldn't delete the group."
        }
    }

    private func apply(_ updated: GroupConversationDetails) {
        details = updated
        onUpdated(updated)
        editTitle = updated.title ?? fallbackTitle
        editDescription = updated.description ?? ""
        error = nil
    }
}

private struct GroupMemberListView: View {
    let members: [GroupConversationDetails.Member]
    let onSelectMember: (ChatProfileTarget) -> Void

    var body: some View {
        List(members) { member in
            Button {
                onSelectMember(ChatProfileTarget(id: member.id, username: member.username, displayName: member.displayName, avatarUrl: member.avatarUrl))
            } label: {
                HStack(spacing: 12) {
                    AvatarView(url: member.avatarUrl, name: member.displayName, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName)
                            .font(KlicFont.medium())
                            .foregroundStyle(KlicColor.textPrimary)
                        Text("@\(member.username)")
                            .font(KlicFont.caption())
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(KlicColor.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AddGroupMembersSheet: View {
    let conversationId: String
    let currentMemberIds: Set<String>
    let onUpdated: (GroupConversationDetails) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var friends: [User] = []
    @State private var selectedIds: Set<String> = []
    @State private var loading = false
    @State private var saving = false

    private var availableFriends: [User] {
        friends.filter { !currentMemberIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(availableFriends) { friend in
                Button {
                    if selectedIds.contains(friend.id) { selectedIds.remove(friend.id) }
                    else { selectedIds.insert(friend.id) }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: friend.avatarUrl, name: friend.displayName, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.displayName)
                                .font(KlicFont.medium())
                                .foregroundStyle(KlicColor.textPrimary)
                            Text("@\(friend.username)")
                                .font(KlicFont.caption())
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        Spacer()
                        Image(systemName: selectedIds.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(selectedIds.contains(friend.id) ? KlicColor.primary : KlicColor.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(KlicColor.surface)
            }
            .overlay {
                if loading {
                    ProgressView()
                } else if availableFriends.isEmpty {
                    Text("No more friends to add.")
                        .font(KlicFont.body(14))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Add members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Adding…" : "Add") { Task { await addMembers() } }
                        .disabled(selectedIds.isEmpty || saving)
                }
            }
            .task { await loadFriends() }
        }
    }

    private func loadFriends() async {
        loading = true
        defer { loading = false }
        friends = (try? await APIClient.shared.friends()) ?? []
    }

    private func addMembers() async {
        saving = true
        defer { saving = false }
        guard let updated = try? await APIClient.shared.addGroupMembers(conversationId: conversationId, userIds: Array(selectedIds)) else { return }
        onUpdated(updated)
        dismiss()
    }
}

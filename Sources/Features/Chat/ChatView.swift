import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

struct ChatView: View {
    let conversation: Conversation
    @EnvironmentObject var session: AppSession
    @StateObject private var socket = SocketService.shared

    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var scrollProxy: ScrollViewProxy?

    @StateObject private var recorder = AudioRecorder()
    @FocusState private var isComposerFocused: Bool
    @State private var pickedItem: PhotosPickerItem?
    @State private var showAttachMenu = false
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var showStickers = false
    @State private var uploading = false

    private enum AttachAction { case photos, camera, file }
    @State private var pendingAttach: AttachAction?

    var title: String { conversation.members.first?.displayName ?? "Chat" }
    var myId: String? { session.currentUser?.id }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            composer
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KlicColor.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { chatHeader }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 20) {
                    Button { Task { await startCall(kind: "AUDIO") } } label: {
                        Icon(.phone, size: 20, style: .line)
                    }
                    Button { Task { await startCall(kind: "VIDEO") } } label: {
                        Icon(.video, size: 20, style: .line)
                    }
                }
            }
        }
        .task { await load(); scrollToBottom() }
        .onAppear { isComposerFocused = true }
        .onReceive(socket.$lastMessage.compactMap { $0 }) { msg in
            guard msg.conversationId == conversation.id else { return }
            messages.append(msg)
            markRead()
            scrollToBottom()
        }
        .onReceive(socket.$lastRead.compactMap { $0 }) { applyReceipt($0, status: "read") }
        .onReceive(socket.$lastDelivered.compactMap { $0 }) { applyReceipt($0, status: "delivered") }
    }

    // Tappable header → the peer's profile, with live presence underneath the name.
    @ViewBuilder private var chatHeader: some View {
        if let peer = conversation.members.first {
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
            }
            .buttonStyle(.plain)
        } else {
            Text(title).font(KlicFont.headline(16)).foregroundStyle(KlicColor.textPrimary)
        }
    }

    private var isPeerOnline: Bool {
        guard let id = conversation.members.first?.id else { return false }
        return socket.presence[id]?.online == true
    }

    private var headerSubtitle: String? {
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { idx, msg in
                        let isMine = msg.senderId == myId
                        let isFirst = idx == 0 || messages[idx - 1].senderId != msg.senderId
                        let isLast  = idx == messages.count - 1 || messages[idx + 1].senderId != msg.senderId

                        if showDateSeparator(at: idx) {
                            DateSeparator(dateString: msg.createdAt)
                        }

                        MessageBubble(
                            message: msg,
                            isMine: isMine,
                            isFirst: isFirst,
                            isLast: isLast,
                            onCallBack: { kind in Task { await startCall(kind: kind) } }
                        )
                        .id(msg.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .scrollDismissesKeyboard(.immediately)
            .onAppear { scrollProxy = proxy }
        }
    }

    // MARK: Composer

    private var composer: some View {
        Group {
            if recorder.isRecording {
                recordingBar
            } else {
                normalComposer
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

    private var normalComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { showAttachMenu = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(KlicColor.textMuted)
                    .frame(width: 44, height: 44)
                    .background(KlicColor.surfaceRaised, in: Circle())
            }
            .disabled(uploading)

            Button { isComposerFocused = false; showStickers = true } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(KlicColor.textMuted)
                    .frame(width: 44, height: 44)
                    .background(KlicColor.surfaceRaised, in: Circle())
            }
            .disabled(uploading)

            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
                .tint(KlicColor.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 22))
                .focused($isComposerFocused)

            let canSend = !draft.trimmingCharacters(in: .whitespaces).isEmpty
            if canSend {
                Button { Task { await send() } } label: {
                    Icon(.send, size: 18, color: KlicColor.onPrimary)
                        .frame(width: 44, height: 44)
                        .background(KlicColor.primary, in: Circle())
                }
            } else {
                Button { recorder.start() } label: {
                    Icon(.mic, size: 18, color: KlicColor.onPrimary)
                        .frame(width: 44, height: 44)
                        .background(KlicColor.primary, in: Circle())
                }
                .disabled(uploading)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: draft.isEmpty)
    }

    private var recordingBar: some View {
        HStack(spacing: 14) {
            Button { recorder.cancel() } label: {
                Image(systemName: "trash")
                    .font(.system(size: 18)).foregroundStyle(KlicColor.textMuted)
                    .frame(width: 40, height: 44)
            }
            Circle().fill(.red).frame(width: 10, height: 10)
            Text(elapsedText)
                .font(KlicFont.body()).foregroundStyle(KlicColor.textPrimary).monospacedDigit()
            Spacer()
            Text("Recording…").font(KlicFont.caption(12)).foregroundStyle(KlicColor.textMuted)
            Button { Task { await stopAndSendVoice() } } label: {
                Icon(.send, size: 18, color: KlicColor.onPrimary)
                    .frame(width: 44, height: 44)
                    .background(KlicColor.primary, in: Circle())
            }
        }
    }

    private var elapsedText: String {
        let s = Int(recorder.elapsed)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Helpers

    private func showDateSeparator(at idx: Int) -> Bool {
        guard idx > 0 else { return true }
        let prev = messages[idx - 1].createdAt
        let curr = messages[idx].createdAt
        return !sameDay(prev, curr)
    }

    private func sameDay(_ a: String, _ b: String) -> Bool {
        String(a.prefix(10)) == String(b.prefix(10))
    }

    private func scrollToBottom() {
        guard let last = messages.last else { return }
        withAnimation { scrollProxy?.scrollTo(last.id, anchor: .bottom) }
    }

    private func load() async {
        messages = ((try? await APIClient.shared.messages(conversationId: conversation.id)) ?? []).reversed()
        markRead()
    }

    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        draft = ""
        if let msg = try? await APIClient.shared.send(conversationId: conversation.id, body: body) {
            messages.append(msg)
            scrollToBottom()
        }
    }

    private func sendSticker(_ id: String) async {
        if let msg = try? await APIClient.shared.sendSticker(conversationId: conversation.id, stickerId: id) {
            messages.append(msg)
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
        do {
            let draft = try await Media.upload(
                conversationId: conversation.id, kind: kind, contentType: contentType, data: data,
                width: width, height: height, durationMs: durationMs, waveform: waveform, fileName: fileName)
            let msg = try await APIClient.shared.sendMessage(
                conversationId: conversation.id, body: nil, attachments: [draft])
            messages.append(msg)
            scrollToBottom()
        } catch {
            // Upload/send failed — silently ignored for now (matches existing send() behavior).
        }
    }

    private func markRead() {
        socket.emit("message:read", ["conversationId": conversation.id])
    }

    private func startCall(kind: String) async {
        guard let s = try? await APIClient.shared.startCall(conversationId: conversation.id, kind: kind)
        else { return }
        CallKitManager.shared.startOutgoing(s, peerName: title, peerId: conversation.members.first?.id)
    }
}

// MARK: - Attach sheet

private struct AttachSheet: View {
    let onPhotos: () -> Void
    let onCamera: () -> Void
    let onFile:   () -> Void

    var body: some View {
        HStack(spacing: 20) {
            AttachTile(icon: "photo.on.rectangle.fill", label: "Photos",
                       color: Color(red: 0.23, green: 0.51, blue: 0.96), action: onPhotos)
            AttachTile(icon: "camera.fill", label: "Camera",
                       color: Color(red: 0.13, green: 0.77, blue: 0.34), action: onCamera)
            AttachTile(icon: "doc.fill", label: "File",
                       color: Color(red: 0.97, green: 0.57, blue: 0.20), action: onFile)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }
}

private struct AttachTile: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .background(color, in: RoundedRectangle(cornerRadius: 20))
                Text(label)
                    .font(KlicFont.caption(13))
                    .foregroundStyle(KlicColor.textPrimary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: Message
    let isMine: Bool
    let isFirst: Bool
    let isLast: Bool
    var onCallBack: (String) -> Void = { _ in }

    private var topRadius:    CGFloat { isFirst ? 18 : (isMine ? 18 : 4) }
    private var bottomRadius: CGFloat { isLast  ? 18 : (isMine ? 4  : 18) }
    private var tailRadius:   CGFloat { isLast  ? 4  : 18 }

    var body: some View {
        if message.isCallEvent, let call = message.call {
            CallEventRow(call: call, outgoing: isMine, time: shortTime(message.createdAt), onCallBack: onCallBack)
        } else if message.isSticker, let stickerId = message.stickerId {
            StickerMessageView(stickerId: stickerId, isMine: isMine, time: isLast ? shortTime(message.createdAt) : nil)
        } else {
            standardBubble
        }
    }

    private var standardBubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine { Spacer(minLength: 56) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                if !message.attachments.isEmpty {
                    MessageAttachmentsView(attachments: message.attachments, isMine: isMine)
                }

                if !message.body.isEmpty {
                    Text(message.body)
                        .font(KlicFont.body())
                        .foregroundStyle(isMine ? KlicColor.onPrimary : KlicColor.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            isMine ? KlicColor.primary : KlicColor.surfaceRaised,
                            in: UnevenRoundedRectangle(
                                topLeadingRadius:     isMine ? 18 : topRadius,
                                bottomLeadingRadius:  isMine ? 18 : bottomRadius,
                                bottomTrailingRadius: isMine ? tailRadius : 18,
                                topTrailingRadius:    isMine ? topRadius : 18
                            )
                        )
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = message.body
                            } label: { Label("Copy", systemImage: "doc.on.doc") }
                        }
                }

                if isLast {
                    HStack(spacing: 3) {
                        Text(shortTime(message.createdAt))
                            .font(KlicFont.caption(11))
                            .foregroundStyle(KlicColor.textMuted)
                        if isMine, let status = message.status {
                            MessageTicks(status: status)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            if !isMine { Spacer(minLength: 56) }
        }
        .padding(.vertical, 1)
    }

    private func shortTime(_ iso: String) -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let df2 = ISO8601DateFormatter()
        df2.formatOptions = [.withInternetDateTime]
        guard let date = df.date(from: iso) ?? df2.date(from: iso) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// MARK: - Delivery ticks

private struct MessageTicks: View {
    let status: String   // "sent" | "delivered" | "read"

    var body: some View {
        let isRead = status == "read"
        let single = status == "sent"
        ZStack(alignment: .trailing) {
            if !single {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .offset(x: -3)
            }
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(isRead ? KlicColor.primary : KlicColor.textMuted)
    }
}

// MARK: - Date separator

private struct DateSeparator: View {
    let dateString: String

    var body: some View {
        HStack {
            line
            Text(label)
                .font(KlicFont.caption(12))
                .foregroundStyle(KlicColor.textMuted)
                .padding(.horizontal, 8)
            line
        }
        .padding(.vertical, 12)
    }

    private var line: some View {
        Rectangle().fill(KlicColor.surfaceRaised).frame(height: 1)
    }

    private var label: String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let df2 = ISO8601DateFormatter()
        df2.formatOptions = [.withInternetDateTime]
        guard let date = df.date(from: dateString) ?? df2.date(from: dateString) else { return dateString }
        let f = DateFormatter()
        if Calendar.current.isDateInToday(date)     { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        f.dateFormat = "MMMM d"
        return f.string(from: date)
    }
}

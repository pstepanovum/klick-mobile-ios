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
    @State private var pickedItem: PhotosPickerItem?
    @State private var showAttachMenu = false
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var uploading = false

    var title: String { conversation.members.first?.displayName ?? "Chat" }
    var myId: String? { session.currentUser?.id }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            composer
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .onReceive(socket.$lastMessage.compactMap { $0 }) { msg in
            guard msg.conversationId == conversation.id else { return }
            messages.append(msg)
            markRead()
            scrollToBottom()
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
                            isLast: isLast
                        )
                        .id(msg.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
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
        .background(KlicColor.surface)
        .confirmationDialog("Attach", isPresented: $showAttachMenu, titleVisibility: .visible) {
            Button("Photo or Video") { showPhotos = true }
            Button("Camera") { showCamera = true }
            Button("File") { showFileImporter = true }
            Button("Cancel", role: .cancel) {}
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
    }

    private var normalComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { showAttachMenu = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(KlicColor.textMuted)
                    .frame(width: 40, height: 44)
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
        guard let (data, durationMs) = recorder.stop() else { return }
        await sendAttachment(kind: "VOICE", contentType: "audio/m4a", data: data, durationMs: durationMs)
    }

    private func sendAttachment(kind: String, contentType: String, data: Data,
                                width: Int? = nil, height: Int? = nil,
                                durationMs: Int? = nil, fileName: String? = nil) async {
        uploading = true
        defer { uploading = false }
        do {
            let draft = try await Media.upload(
                conversationId: conversation.id, kind: kind, contentType: contentType, data: data,
                width: width, height: height, durationMs: durationMs, fileName: fileName)
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
        CallKitManager.shared.startOutgoing(s, peerName: title)
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: Message
    let isMine: Bool
    let isFirst: Bool
    let isLast: Bool

    private var topRadius:    CGFloat { isFirst ? 18 : (isMine ? 18 : 4) }
    private var bottomRadius: CGFloat { isLast  ? 18 : (isMine ? 4  : 18) }
    private var tailRadius:   CGFloat { isLast  ? 4  : 18 }

    var body: some View {
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
                }

                if isLast {
                    Text(shortTime(message.createdAt))
                        .font(KlicFont.caption(11))
                        .foregroundStyle(KlicColor.textMuted)
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

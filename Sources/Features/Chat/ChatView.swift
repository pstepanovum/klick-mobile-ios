import SwiftUI

struct ChatView: View {
    let conversation: Conversation
    @EnvironmentObject var session: AppSession
    @StateObject private var socket = SocketService.shared

    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var scrollProxy: ScrollViewProxy?

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
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(KlicFont.body())
                .foregroundStyle(KlicColor.textPrimary)
                .tint(KlicColor.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 22))

            let canSend = !draft.trimmingCharacters(in: .whitespaces).isEmpty
            Button { Task { await send() } } label: {
                Icon(.send, size: 18, color: canSend ? KlicColor.onPrimary : KlicColor.textMuted)
                    .frame(width: 44, height: 44)
                    .background(canSend ? KlicColor.primary : KlicColor.surfaceRaised, in: Circle())
            }
            .disabled(!canSend)
            .animation(.easeInOut(duration: 0.15), value: canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(KlicColor.surface)
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

            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
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

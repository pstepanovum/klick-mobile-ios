import SwiftUI

struct ChatView: View {
    let conversation: Conversation
    @EnvironmentObject var session: AppSession
    @StateObject private var socket = SocketService.shared

    @State private var messages: [Message] = []
    @State private var draft = ""

    var title: String { conversation.members.first?.displayName ?? "Chat" }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { msg in
                        MessageBubble(message: msg, isMine: msg.senderId == session.currentUser?.id)
                    }
                }
                .padding(16)
            }
            composer
        }
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 18) {
                    Button { Task { await startCall(kind: "AUDIO") } } label: { Icon(.phone) }
                    Button { Task { await startCall(kind: "VIDEO") } } label: { Icon(.video) }
                }
            }
        }
        .task { await load(); markRead() }
        .onReceive(socket.$lastMessage.compactMap { $0 }) { msg in
            if msg.conversationId == conversation.id { messages.append(msg); markRead() }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            KlicTextField(placeholder: "Message", text: $draft)
            Button { Task { await send() } } label: {
                Icon(.send, size: 22, color: KlicColor.onPrimary)
                    .frame(width: 50, height: 50)
                    .background(KlicColor.primary, in: Circle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(KlicColor.surface)
    }

    private func load() async {
        messages = ((try? await APIClient.shared.messages(conversationId: conversation.id)) ?? []).reversed()
    }

    private func send() async {
        let body = draft.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        draft = ""
        if let msg = try? await APIClient.shared.send(conversationId: conversation.id, body: body) {
            messages.append(msg)
        }
    }

    private func markRead() {
        socket.emit("message:read", ["conversationId": conversation.id])
    }

    private func startCall(kind: String) async {
        guard let session = try? await APIClient.shared.startCall(conversationId: conversation.id, kind: kind)
        else { return }
        CallKitManager.shared.startOutgoing(session, peerName: title)
    }
}

private struct MessageBubble: View {
    let message: Message
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            Text(message.body)
                .font(KlicFont.body())
                .foregroundStyle(isMine ? KlicColor.onPrimary : KlicColor.textPrimary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(isMine ? KlicColor.primary : KlicColor.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 22))
            if !isMine { Spacer(minLength: 40) }
        }
    }
}

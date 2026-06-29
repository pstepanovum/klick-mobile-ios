import SwiftUI

struct ConversationsView: View {
    @State private var conversations: [Conversation] = []
    @State private var searchText = ""

    private var filtered: [Conversation] {
        guard !searchText.isEmpty else { return conversations }
        let q = searchText.lowercased()
        return conversations.filter {
            ($0.members.first?.displayName.lowercased().contains(q) ?? false) ||
            ($0.members.first?.username.lowercased().contains(q) ?? false) ||
            ($0.lastMessage?.body.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { convo in
                        NavigationLink(value: convo) {
                            ConversationRow(conversation: convo)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .adaptiveWidth()
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Chats")
            .navigationDestination(for: Conversation.self) { ChatView(conversation: $0) }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search chats"
            )
            .task { await load() }
        }
        .tint(KlicColor.primary)
    }

    private func load() async {
        conversations = (try? await APIClient.shared.conversations()) ?? []
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    @ObservedObject private var socket = SocketService.shared

    var title: String { conversation.members.first?.displayName ?? "Direct" }
    private var isOnline: Bool {
        guard let id = conversation.members.first?.id else { return false }
        return socket.presence[id]?.online == true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AvatarView(url: conversation.members.first?.avatarUrl, name: title, size: 52)
                    .overlay(alignment: .bottomTrailing) {
                        if isOnline {
                            Circle().fill(.green).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(KlicColor.background, lineWidth: 2))
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(KlicFont.headline()).foregroundStyle(KlicColor.textPrimary)
                    Text(lastMessageText(conversation.lastMessage))
                        .font(KlicFont.body(14)).foregroundStyle(KlicColor.textMuted)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            // Divider inset to start under the text content, not under the avatar.
            Rectangle()
                .fill(KlicColor.textPrimary.opacity(0.08))
                .frame(height: 1)
                .padding(.leading, 66)
        }
    }
}

/// One-line summary of the last message for the chat list (no emoji, per the design system).
private func lastMessageText(_ m: Message?) -> String {
    guard let m else { return "Say hi" }
    if m.isDeleted { return "Message deleted" }
    if m.isCallEvent { return m.call?.isVideo == true ? "Video call" : "Voice call" }
    if m.isSticker { return "Sticker" }
    if !m.body.isEmpty { return m.body }
    switch m.attachments.first?.kind {
    case "IMAGE": return "Photo"
    case "VIDEO": return "Video"
    case "VOICE": return "Voice message"
    case .some:   return "File"
    default:      return "Say hi"
    }
}

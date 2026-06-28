import SwiftUI

struct ConversationsView: View {
    @State private var conversations: [Conversation] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(conversations) { convo in
                        NavigationLink(value: convo) {
                            ConversationRow(conversation: convo)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Chats")
            .navigationDestination(for: Conversation.self) { ChatView(conversation: $0) }
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

    var title: String { conversation.members.first?.displayName ?? "Direct" }

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(KlicColor.surfaceRaised).frame(width: 52, height: 52)
                .overlay(Icon(.user, size: 22, color: KlicColor.textMuted))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(KlicFont.headline()).foregroundStyle(KlicColor.textPrimary)
                Text(conversation.lastMessage?.body ?? "Say hi")
                    .font(KlicFont.body(14)).foregroundStyle(KlicColor.textMuted).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}

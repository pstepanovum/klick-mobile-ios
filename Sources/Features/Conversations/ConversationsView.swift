import SwiftUI

struct ConversationsView: View {
    @State private var conversations: [Conversation] = []
    @State private var searchText = ""

    private var filtered: [Conversation] {
        guard !searchText.isEmpty else { return conversations }
        let q = searchText.lowercased()
        return conversations.filter {
            conversationTitle($0).lowercased().contains(q) ||
            $0.members.contains {
                $0.displayName.lowercased().contains(q) ||
                $0.username.lowercased().contains(q)
            } ||
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

    var title: String { conversationTitle(conversation) }
    private var isOnline: Bool {
        guard conversation.type == "DIRECT" else { return false }
        guard let id = conversation.members.first?.id else { return false }
        return socket.presence[id]?.online == true
    }

    private var unread: Int { conversation.unreadCount ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AvatarView(
                    url: conversation.type == "GROUP" ? conversation.avatarUrl : conversation.members.first?.avatarUrl,
                    name: title,
                    size: 52
                )
                    .overlay(alignment: .bottomTrailing) {
                        if isOnline {
                            Circle().fill(.green).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(KlicColor.background, lineWidth: 2))
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(KlicFont.headline()).foregroundStyle(KlicColor.textPrimary)
                    if conversation.type == "GROUP" {
                        Text(groupMemberSummary(conversation))
                            .font(KlicFont.caption())
                            .foregroundStyle(KlicColor.textMuted)
                            .lineLimit(1)
                    }
                    Text(lastMessageText(conversation.lastMessage))
                        .font(KlicFont.body(14)).foregroundStyle(KlicColor.textMuted)
                        .lineLimit(2)
                }
                Spacer()
                // Date pinned top-right (with my read-status tick to its left); unread badge beneath.
                VStack(alignment: .trailing, spacing: 6) {
                    if let stamp = lastMessageStamp(conversation.lastMessage) {
                        HStack(spacing: 3) {
                            if let status = conversation.lastMessage?.status {
                                MessageTicks(status: status)
                            }
                            Text(stamp).font(KlicFont.caption(12)).foregroundStyle(KlicColor.textMuted)
                        }
                    }
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(KlicFont.caption(12).weight(.semibold))
                            .foregroundStyle(KlicColor.onPrimary)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(KlicColor.primary, in: Capsule())
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
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

private func conversationTitle(_ conversation: Conversation) -> String {
    if conversation.type == "GROUP" {
        if let title = conversation.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        let members = conversation.members.map(\.displayName).joined(separator: ", ")
        return members.isEmpty ? "Group" : members
    }
    return conversation.members.first?.displayName ?? "Direct"
}

private func groupMemberSummary(_ conversation: Conversation) -> String {
    let members = conversation.members.map(\.displayName).joined(separator: ", ")
    return members.isEmpty ? "No members yet" : members
}

/// Last-message stamp for the chat list: clock time today (e.g. "3:26 PM"), "MM/dd" earlier
/// this year, "MM/dd/yy" before that — or nil if unknown.
private func lastMessageStamp(_ m: Message?) -> String? {
    guard let iso = m?.createdAt, !iso.isEmpty else { return nil }
    let df = ISO8601DateFormatter(); df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let df2 = ISO8601DateFormatter(); df2.formatOptions = [.withInternetDateTime]
    guard let date = df.date(from: iso) ?? df2.date(from: iso) else { return nil }
    let cal = Calendar.current
    let f = DateFormatter()
    if cal.isDateInToday(date) {
        f.dateFormat = "h:mm a"
    } else if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
        f.dateFormat = "MM/dd"
    } else {
        f.dateFormat = "MM/dd/yy"
    }
    return f.string(from: date)
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

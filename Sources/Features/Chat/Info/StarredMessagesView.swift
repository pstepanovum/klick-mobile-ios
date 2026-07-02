import SwiftUI

/// Server-backed starred-messages list for one conversation (CALLS.md §8.4).
/// Swipe a row to unstar.
struct StarredMessagesView: View {
    let conversationId: String
    let members: [ChatProfileTarget]

    @State private var messages: [Message] = []
    @State private var nextCursor: String?
    @State private var loaded = false
    @State private var loading = false
    @State private var unavailable = false

    var body: some View {
        List {
            ForEach(messages) { message in
                StarredMessageRow(message: message, senderName: senderName(message.senderId))
                    .listRowBackground(KlicColor.surface)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await unstar(message) }
                        } label: {
                            Label("Unstar", systemImage: "star.slash")
                        }
                    }
                    .onAppear {
                        if message.id == messages.last?.id, nextCursor != nil {
                            Task { await loadMore() }
                        }
                    }
            }
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KlicColor.background.ignoresSafeArea())
        .overlay {
            if loaded, messages.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "star")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(KlicColor.textMuted)
                    Text(unavailable
                         ? "Starred messages need the latest server."
                         : "No starred messages yet.\nLong-press a message and tap Star.")
                        .font(KlicFont.body(14))
                        .foregroundStyle(KlicColor.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .navigationTitle("Starred")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await loadMore() } }
    }

    private func loadMore() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // try? — tolerate a server without the endpoint (graceful empty state).
        guard let page = try? await APIClient.shared.starredMessages(
            conversationId: conversationId, cursor: nextCursor
        ) else {
            unavailable = messages.isEmpty
            loaded = true
            nextCursor = nil
            return
        }
        loaded = true
        messages += page.items.filter { item in !messages.contains(where: { $0.id == item.id }) }
        nextCursor = page.nextCursor
    }

    private func unstar(_ message: Message) async {
        messages.removeAll { $0.id == message.id }
        try? await APIClient.shared.unstarMessage(id: message.id)
    }

    private func senderName(_ userId: String) -> String {
        members.first(where: { $0.id == userId })?.displayName ?? "User"
    }
}

private struct StarredMessageRow: View {
    let message: Message
    let senderName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(senderName)
                    .font(KlicFont.medium(14))
                    .foregroundStyle(KlicColor.primary)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                    Text(Self.stamp(message.createdAt))
                        .font(KlicFont.caption(11))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            Text(preview)
                .font(KlicFont.body(15))
                .foregroundStyle(KlicColor.textPrimary)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }

    private var preview: String {
        if !message.body.isEmpty { return message.body }
        if message.isSticker { return "Sticker" }
        switch message.attachments.first?.kind {
        case "IMAGE": return "📷 Photo"
        case "VIDEO": return "🎥 Video"
        case "VOICE": return "🎤 Voice message"
        case .some: return "📎 \(message.attachments.first?.fileName ?? "File")"
        default: return "Message"
        }
    }

    private static func stamp(_ iso: String) -> String {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = withFraction.date(from: iso) ?? plain.date(from: iso) else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

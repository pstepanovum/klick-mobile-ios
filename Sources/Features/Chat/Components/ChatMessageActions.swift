import SwiftUI

// Quick-reaction palette shown on the long-press menu (Telegram-style).
let quickReactions = ["❤️", "👍", "👎", "😂", "😮", "😢", "🔥"]

// MARK: - Long-press actions overlay

/// A dimmed full-screen menu shown when a bubble is long-pressed: a reaction bar on
/// top, a compact preview of the message, and the action list below.
struct MessageActionsOverlay: View {
    let message: Message
    let isMine: Bool
    let peerName: String
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    var onToggleStar: () -> Void = {}
    let onDelete: () -> Void
    let onDismiss: () -> Void

    private var mineEmojis: Set<String> { Set(message.reactions.filter { $0.mine }.map { $0.emoji }) }
    private var hasBody: Bool { !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: isMine ? .trailing : .leading, spacing: 12) {
                reactionBar
                previewBubble
                actionsCard
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 420)
        }
    }

    private var reactionBar: some View {
        HStack(spacing: 6) {
            ForEach(quickReactions, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 27))
                        .frame(width: 40, height: 40)
                        .background(mineEmojis.contains(emoji) ? KlicColor.primary.opacity(0.25) : .clear, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(KlicColor.surface, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    @ViewBuilder private var previewBubble: some View {
        Text(previewText)
            .font(KlicFont.body())
            .foregroundStyle(isMine ? KlicColor.onPrimary : KlicColor.textPrimary)
            .lineLimit(6)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isMine ? KlicColor.primary : KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
            .frame(maxWidth: 300, alignment: isMine ? .trailing : .leading)
    }

    private var previewText: String {
        if hasBody { return message.body }
        if message.isSticker { return "Sticker" }
        if let a = message.attachments.first {
            switch a.kind {
            case "IMAGE": return "📷 Photo"
            case "VOICE": return "🎤 Voice message"
            case "VIDEO": return "🎥 Video"
            default:      return "📎 File"
            }
        }
        return "Message"
    }

    private var actionsCard: some View {
        VStack(spacing: 0) {
            ActionRow(title: "Reply", systemImage: "arrowshape.turn.up.left") { onReply(); onDismiss() }
            if hasBody {
                Divider().overlay(KlicColor.surfaceRaised)
                ActionRow(title: "Copy", systemImage: "doc.on.doc") { onCopy(); onDismiss() }
            }
            Divider().overlay(KlicColor.surfaceRaised)
            ActionRow(
                title: message.starred == true ? "Unstar" : "Star",
                systemImage: message.starred == true ? "star.slash" : "star"
            ) { onToggleStar(); onDismiss() }
            Divider().overlay(KlicColor.surfaceRaised)
            ActionRow(title: "Delete", systemImage: "trash", destructive: true) { onDelete() }
        }
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 260)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
}

private struct ActionRow: View {
    let title: String
    let systemImage: String
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(KlicFont.body(15))
                Spacer()
                Image(systemName: systemImage)
                    .font(.system(size: 16))
            }
            .foregroundStyle(destructive ? KlicColor.danger : KlicColor.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reaction pills (under a bubble)

struct ReactionPills: View {
    let reactions: [Reaction]
    let onTap: (String) -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(reactions, id: \.emoji) { r in
                Button { onTap(r.emoji) } label: {
                    HStack(spacing: 3) {
                        Text(r.emoji).font(.system(size: 13))
                        if r.count > 1 {
                            Text("\(r.count)")
                                .font(KlicFont.caption(11))
                                .foregroundStyle(r.mine ? KlicColor.onPrimary : KlicColor.textMuted)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(r.mine ? KlicColor.primary : KlicColor.surfaceRaised, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Reply views

/// The quoted header rendered at the top of a bubble that is a reply.
struct ReplyQuoteView: View {
    let reply: ReplyPreview
    let authorName: String
    var onPrimary: Bool = false   // tint for when it sits inside the user's own (red) bubble

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(onPrimary ? KlicColor.onPrimary : KlicColor.primary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(authorName)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(onPrimary ? KlicColor.onPrimary : KlicColor.primary)
                Text(reply.preview)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(onPrimary ? KlicColor.onPrimary.opacity(0.85) : KlicColor.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

/// The "replying to …" bar shown above the composer.
struct ReplyComposerBar: View {
    let authorName: String
    let preview: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(KlicColor.primary).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reply to \(authorName)")
                    .font(KlicFont.caption(12)).foregroundStyle(KlicColor.primary)
                Text(preview)
                    .font(KlicFont.caption(12)).foregroundStyle(KlicColor.textMuted).lineLimit(1)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(KlicColor.textMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(KlicColor.surface)
    }
}

// MARK: - Tombstone

/// Placeholder shown in place of a message that was deleted for everyone.
struct DeletedBubble: View {
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 56) }
            HStack(spacing: 6) {
                Image(systemName: "nosign").font(.system(size: 12))
                Text("This message was deleted").font(KlicFont.body(14)).italic()
            }
            .foregroundStyle(KlicColor.textMuted)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
            if !isMine { Spacer(minLength: 56) }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Typing indicator

/// Three dots that pulse in sequence — shown while the peer is typing.
struct TypingDots: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(KlicColor.textMuted)
                    .frame(width: 7, height: 7)
                    .opacity(opacity(for: i))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(KlicColor.surfaceRaised, in: RoundedRectangle(cornerRadius: 18))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { phase = 1 }
        }
    }

    private func opacity(for index: Int) -> Double {
        let base = 0.3 + 0.7 * abs(sin((phase * .pi) + Double(index) * 0.6))
        return min(1, base)
    }
}

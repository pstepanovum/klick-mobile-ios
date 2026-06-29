import SwiftUI

// MARK: - Attach sheet

struct AttachSheet: View {
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

struct MessageBubble: View {
    let message: Message
    let isMine: Bool
    let isFirst: Bool
    let isLast: Bool
    var replyAuthorName: String = ""
    var onCallBack: (String) -> Void = { _ in }
    var onLongPress: () -> Void = {}
    var onReactionTap: (String) -> Void = { _ in }

    private var topRadius:    CGFloat { isFirst ? 18 : (isMine ? 18 : 4) }
    private var bottomRadius: CGFloat { isLast  ? 18 : (isMine ? 4  : 18) }
    private var tailRadius:   CGFloat { isLast  ? 4  : 18 }

    var body: some View {
        if message.isDeleted {
            DeletedBubble(isMine: isMine)
        } else if message.isCallEvent, let call = message.call {
            CallEventRow(call: call, outgoing: isMine, time: shortTime(message.createdAt), onCallBack: onCallBack)
        } else if message.isSticker, let stickerId = message.stickerId {
            stickerBubble(stickerId)
        } else {
            standardBubble
        }
    }

    private func stickerBubble(_ stickerId: String) -> some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            StickerMessageView(stickerId: stickerId, isMine: isMine, time: isLast ? shortTime(message.createdAt) : nil)
                .onLongPressGesture(minimumDuration: 0.3, perform: onLongPress)
            if !message.reactions.isEmpty {
                ReactionPills(reactions: message.reactions, onTap: onReactionTap)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }

    private var standardBubble: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine { Spacer(minLength: 56) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                if !message.attachments.isEmpty {
                    if let reply = message.replyTo {
                        ReplyQuoteView(reply: reply, authorName: replyAuthorName)
                    }
                    MessageAttachmentsView(attachments: message.attachments, isMine: isMine)
                }

                if !message.body.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        if let reply = message.replyTo, message.attachments.isEmpty {
                            ReplyQuoteView(reply: reply, authorName: replyAuthorName, onPrimary: isMine)
                        }
                        Text(message.body)
                            .font(KlicFont.body())
                            .foregroundStyle(isMine ? KlicColor.onPrimary : KlicColor.textPrimary)
                    }
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

                if !message.reactions.isEmpty {
                    ReactionPills(reactions: message.reactions, onTap: onReactionTap)
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
            .onLongPressGesture(minimumDuration: 0.3, perform: onLongPress)

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

struct DateSeparator: View {
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

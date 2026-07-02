import SwiftUI

/// Client-side message search with fetch-back pagination (CALLS.md §8.4, group info).
/// Searches the chat's loaded history; "Search older messages" pulls more pages in.
/// Tapping a result jumps the chat to that message.
struct MessageSearchSheet: View {
    let messages: [Message]
    let hasMore: Bool
    let isLoadingMore: Bool
    let senderName: (String) -> String
    let onLoadMore: () -> Void
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [Message] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return messages
            .filter { !$0.isDeleted && !$0.body.isEmpty && $0.body.lowercased().contains(q) }
            .reversed() // newest first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                KlicTextField(placeholder: "Search messages", text: $query)
                    .focused($focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                ScrollView {
                    LazyVStack(spacing: 6) {
                        if query.trimmingCharacters(in: .whitespaces).isEmpty {
                            hint("Type to search this chat's messages.")
                        } else if results.isEmpty && !hasMore {
                            hint("No matches.")
                        }

                        ForEach(results) { message in
                            Button {
                                onSelect(message.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(senderName(message.senderId))
                                            .font(KlicFont.medium(13))
                                            .foregroundStyle(KlicColor.primary)
                                        Spacer()
                                        Text(Self.stamp(message.createdAt))
                                            .font(KlicFont.caption(11))
                                            .foregroundStyle(KlicColor.textMuted)
                                    }
                                    Text(message.body)
                                        .font(KlicFont.body(15))
                                        .foregroundStyle(KlicColor.textPrimary)
                                        .lineLimit(2)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 12))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if !query.trimmingCharacters(in: .whitespaces).isEmpty, hasMore {
                            Button {
                                onLoadMore()
                            } label: {
                                HStack(spacing: 8) {
                                    if isLoadingMore { ProgressView().controlSize(.small) }
                                    Text(isLoadingMore ? "Searching older messages…" : "Search older messages")
                                        .font(KlicFont.body(14))
                                        .foregroundStyle(KlicColor.primary)
                                }
                                .padding(.vertical, 12)
                            }
                            .disabled(isLoadingMore)
                        }
                    }
                    .padding(16)
                    .adaptiveWidth()
                }
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { focused = true }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(KlicFont.body(14))
            .foregroundStyle(KlicColor.textMuted)
            .padding(.vertical, 32)
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

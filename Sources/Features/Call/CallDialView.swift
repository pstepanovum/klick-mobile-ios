import SwiftUI

struct CallDialView: View {
    @State private var friends: [User] = []
    @State private var recents: [RecentCall] = []
    @State private var searchText = ""

    private var filtered: [User] {
        guard !searchText.isEmpty else { return friends }
        let q = searchText.lowercased()
        return friends.filter {
            $0.displayName.lowercased().contains(q) || $0.username.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 4) {
                    if searchText.isEmpty && !recents.isEmpty {
                        SectionHeader("Recent")
                        ForEach(recents) { call in
                            RecentCallRow(call: call)
                        }
                        SectionHeader("Contacts")
                    }
                    if friends.isEmpty {
                        Text("No friends yet — add them in Friends.")
                            .font(KlicFont.body(14))
                            .foregroundStyle(KlicColor.textMuted)
                            .padding(.top, 32)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if filtered.isEmpty {
                        Text("No contacts match your search.")
                            .font(KlicFont.body(14))
                            .foregroundStyle(KlicColor.textMuted)
                            .padding(.top, 32)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(filtered) { friend in
                        FriendCallRow(friend: friend)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Call")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search contacts"
            )
            .task {
                friends = (try? await APIClient.shared.friends()) ?? []
                recents = (try? await APIClient.shared.recentCalls()) ?? []
            }
        }
        .tint(KlicColor.primary)
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(KlicFont.caption(12))
            .foregroundStyle(KlicColor.textMuted)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }
}

private struct RecentCallRow: View {
    let call: RecentCall

    private var missed: Bool { call.outcome != "completed" }
    private var subtitle: String {
        let dir = call.outgoing ? "Outgoing" : (missed ? "Missed" : "Incoming")
        let when = RecentCallRow.relativeTime(call.startedAt)
        if !missed, let ms = call.durationMs { return "\(dir) · \(CallEventRow.duration(ms)) · \(when)" }
        return "\(dir) · \(when)"
    }

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(url: call.peer?.avatarUrl, name: call.peer?.displayName ?? "?", size: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.peer?.displayName ?? "Unknown")
                    .font(KlicFont.headline())
                    .foregroundStyle(missed ? .red : KlicColor.textPrimary)
                HStack(spacing: 5) {
                    Image(systemName: call.outgoing ? "arrow.up.right" : "arrow.down.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(missed ? .red : KlicColor.textMuted)
                    Text(subtitle)
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            Spacer()
            Button { Task { await callBack() } } label: {
                Image(systemName: call.isVideo ? "video.fill" : "phone.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(KlicColor.onPrimary)
                    .frame(width: 40, height: 40)
                    .background(KlicColor.primary, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func callBack() async {
        guard let session = try? await APIClient.shared.startCall(conversationId: call.conversationId, kind: call.kind)
        else { return }
        await CallKitManager.shared.startOutgoing(session, peerName: call.peer?.displayName ?? "Call", peerId: call.peer?.id)
    }

    static func relativeTime(_ iso: String) -> String {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        guard let date = f1.date(from: iso) ?? f2.date(from: iso) else { return "" }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }
}

private struct FriendCallRow: View {
    let friend: User

    var body: some View {
        HStack(spacing: 14) {
            AvatarView(url: friend.avatarUrl, name: friend.displayName, size: 50)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName)
                    .font(KlicFont.headline())
                    .foregroundStyle(KlicColor.textPrimary)
                Text("@\(friend.username)")
                    .font(KlicFont.caption())
                    .foregroundStyle(KlicColor.textMuted)
            }
            Spacer()
            HStack(spacing: 10) {
                RoundCallButton(systemName: "phone.fill", fill: KlicColor.primary) {
                    Task { await initiateCall(kind: "AUDIO") }
                }
                RoundCallButton(systemName: "video.fill", fill: KlicColor.surfaceRaised) {
                    Task { await initiateCall(kind: "VIDEO") }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func initiateCall(kind: String) async {
        guard let convo = try? await APIClient.shared.openConversation(userId: friend.id),
              let session = try? await APIClient.shared.startCall(conversationId: convo.id, kind: kind)
        else { return }
        await CallKitManager.shared.startOutgoing(session, peerName: friend.displayName)
    }
}

private struct RoundCallButton: View {
    let systemName: String
    let fill: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(KlicColor.onPrimary)
                .frame(width: 40, height: 40)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

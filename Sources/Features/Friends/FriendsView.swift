import SwiftUI

struct FriendsView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var socket = SocketService.shared

    @State private var friends: [User] = []
    @State private var requests: [FriendRequest] = []
    @State private var showAddFriend = false
    @State private var openedConversation: Conversation?
    @State private var selectedFriend: User?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !requests.isEmpty { requestsSection }
                    friendsSection
                    VStack(spacing: 6) {
                        KlicLottieView(name: "01", height: 180)
                        Text("Your people, all in one place.")
                            .font(KlicFont.caption(13))
                            .foregroundStyle(KlicColor.textMuted)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 8)
                    .padding(.horizontal, 16)
                }
                .adaptiveWidth()
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Friends")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAddFriend = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
            }
            .sheet(isPresented: $showAddFriend) { AddFriendSheet() }
            .navigationDestination(item: $openedConversation) { ChatView(conversation: $0) }
            .navigationDestination(item: $selectedFriend) { friend in
                ProfileView(
                    userId: friend.id, username: friend.username,
                    displayName: friend.displayName, avatarUrl: friend.avatarUrl,
                    onCall: { kind in Task { await callFriend(friend, kind: kind) } },
                    onMessage: { Task { await openChat(with: friend) } }
                )
            }
            .task { await reload() }
            .refreshable { await reload() }
        }
        .tint(KlicColor.primary)
    }

    // MARK: Requests

    private var requestsSection: some View {
        Group {
            Text("Requests")
                .font(KlicFont.headline())
                .foregroundStyle(KlicColor.textPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 8)

            ForEach(requests) { req in
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        AvatarView(url: req.from.avatarUrl ?? APIClient.avatarURL(forUserId: req.from.id), name: req.from.displayName, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(req.from.displayName).font(KlicFont.medium()).foregroundStyle(KlicColor.textPrimary)
                            Text("@\(req.from.username)").font(KlicFont.caption()).foregroundStyle(KlicColor.textMuted)
                        }
                        Spacer()
                        Button { Task { await accept(req) } } label: {
                            Icon(.message, size: 18, color: KlicColor.onPrimary)
                                .frame(width: 40, height: 40).background(KlicColor.primary, in: Circle())
                        }
                        Button { Task { await decline(req) } } label: {
                            Icon(.close, size: 18, color: KlicColor.textMuted)
                                .frame(width: 40, height: 40).background(KlicColor.surfaceRaised, in: Circle())
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 16)

                    Rectangle()
                        .fill(KlicColor.textPrimary.opacity(0.08))
                        .frame(height: 1)
                        .padding(.leading, 82)
                }
            }
        }
    }

    // MARK: Friends list

    private var friendsSection: some View {
        Group {
            Text("Your friends")
                .font(KlicFont.headline())
                .foregroundStyle(KlicColor.textPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 8)

            if friends.isEmpty {
                Text("No friends yet — tap + to add someone.")
                    .font(KlicFont.body(14))
                    .foregroundStyle(KlicColor.textMuted)
                    .padding(.horizontal, 16)
            }

            ForEach(friends) { friend in
                Button { selectedFriend = friend } label: {
                    VStack(spacing: 0) {
                        HStack(spacing: 14) {
                            AvatarView(url: friend.avatarUrl, name: friend.displayName, size: 52)
                                .overlay(alignment: .bottomTrailing) {
                                    if socket.presence[friend.id]?.online == true {
                                        Circle().fill(.green).frame(width: 14, height: 14)
                                            .overlay(Circle().stroke(KlicColor.background, lineWidth: 2))
                                    }
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(friend.displayName).font(KlicFont.medium()).foregroundStyle(KlicColor.textPrimary)
                                Text("@\(friend.username)").font(KlicFont.caption()).foregroundStyle(KlicColor.textMuted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)

                        Rectangle()
                            .fill(KlicColor.textPrimary.opacity(0.08))
                            .frame(height: 1)
                            .padding(.leading, 82)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Actions

    private func reload() async {
        async let f = APIClient.shared.friends()
        async let r = APIClient.shared.friendRequests()
        friends = (try? await f) ?? []
        requests = (try? await r) ?? []
    }

    private func accept(_ req: FriendRequest) async {
        _ = try? await APIClient.shared.acceptFriendRequest(id: req.requestId)
        await reload()
    }

    private func decline(_ req: FriendRequest) async {
        _ = try? await APIClient.shared.declineFriendRequest(id: req.requestId)
        await reload()
    }

    private func openChat(with friend: User) async {
        openedConversation = try? await APIClient.shared.openConversation(userId: friend.id)
    }

    private func callFriend(_ friend: User, kind: String) async {
        guard let convo = try? await APIClient.shared.openConversation(userId: friend.id),
              let session = try? await APIClient.shared.startCall(conversationId: convo.id, kind: kind)
        else { return }
        CallKitManager.shared.startOutgoing(session, peerName: friend.displayName, peerId: friend.id, peerAvatarUrl: friend.avatarUrl)
    }
}

// MARK: - Add Friend Sheet

private struct AddFriendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var statusText: String?
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(KlicColor.textMuted)
                    TextField("Username", text: $username)
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                        .tint(KlicColor.primary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(KlicColor.surface, in: Capsule())
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                Divider().opacity(0.4)

                if let statusText {
                    Text(statusText)
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.textMuted)
                        .padding(.top, 20)
                }

                Spacer()

                PillButton(title: isSending ? "Sending…" : "Send Request") {
                    Task { await sendRequest() }
                }
                .opacity(username.trimmingCharacters(in: .whitespaces).isEmpty || isSending ? 0.4 : 1)
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || isSending)
                .padding(20)
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(KlicColor.textPrimary)
                    }
                }
            }
        }
        .tint(KlicColor.primary)
    }

    private func sendRequest() async {
        let name = username.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        guard let users = try? await APIClient.shared.findUser(username: name), let target = users.first else {
            statusText = "No user named \"\(name)\"."
            return
        }
        _ = try? await APIClient.shared.sendFriendRequest(userId: target.id)
        statusText = "Request sent to \(target.displayName)."
        username = ""
    }
}

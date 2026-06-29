import SwiftUI

struct FriendsView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var socket = SocketService.shared

    @State private var friends: [User] = []
    @State private var requests: [FriendRequest] = []
    @State private var searchUsername = ""
    @State private var statusText: String?
    @State private var openedConversation: Conversation?
    @State private var selectedFriend: User?
    @State private var isCreatingGroup = false
    @State private var groupTitle = ""
    @State private var selectedFriendIds: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    addFriendSection
                    createGroupSection
                    if !requests.isEmpty { requestsSection }
                    friendsSection
                    VStack(spacing: 6) {
                        KlicLottieView(name: "01", height: 180)
                        Text("Your people, all in one place.")
                            .font(KlicFont.caption(13))
                            .foregroundStyle(KlicColor.textMuted)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .padding(20)
                .adaptiveWidth()
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Friends")
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

    // MARK: Add friend

    private var addFriendSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add by username").font(KlicFont.headline()).foregroundStyle(KlicColor.textPrimary)
            HStack(spacing: 10) {
                KlicTextField(placeholder: "username", text: $searchUsername)
                Button { Task { await addFriend() } } label: {
                    Icon(.addUser, size: 22, color: KlicColor.onPrimary)
                        .frame(width: 50, height: 50)
                        .background(KlicColor.primary, in: Circle())
                }
                .disabled(searchUsername.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let statusText { Text(statusText).font(KlicFont.caption()).foregroundStyle(KlicColor.textMuted) }
        }
    }

    private var createGroupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create group").font(KlicFont.headline()).foregroundStyle(KlicColor.textPrimary)
            HStack(spacing: 10) {
                KlicTextField(placeholder: "Group name", text: $groupTitle)
                Button {
                    if isCreatingGroup, selectedFriendIds.count >= 2, !groupTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                        Task { await createGroup() }
                    } else {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isCreatingGroup.toggle()
                            if !isCreatingGroup { selectedFriendIds.removeAll() }
                        }
                    }
                } label: {
                    Icon(isCreatingGroup ? .message : .addUser, size: 22, color: KlicColor.onPrimary)
                        .frame(width: 50, height: 50)
                        .background(KlicColor.primary, in: Circle())
                }
            }
            Text(groupStatusText)
                .font(KlicFont.caption())
                .foregroundStyle(KlicColor.textMuted)
        }
    }

    // MARK: Requests

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Requests").font(KlicFont.headline()).foregroundStyle(KlicColor.textPrimary)
            ForEach(requests) { req in
                HStack(spacing: 12) {
                    AvatarView(url: APIClient.avatarURL(forUserId: req.from.id), name: req.from.displayName, size: 44)
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
                .padding(12).background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    // MARK: Friends list

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your friends").font(KlicFont.headline()).foregroundStyle(KlicColor.textPrimary)
            if friends.isEmpty {
                Text("No friends yet — add someone by username above.")
                    .font(KlicFont.body(14)).foregroundStyle(KlicColor.textMuted)
            }
            ForEach(friends) { friend in
                Button {
                    if isCreatingGroup {
                        toggleFriendSelection(friend.id)
                    } else {
                        selectedFriend = friend
                    }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: friend.avatarUrl, name: friend.displayName, size: 44)
                            .overlay(alignment: .bottomTrailing) {
                                if socket.presence[friend.id]?.online == true {
                                    Circle().fill(.green).frame(width: 12, height: 12)
                                        .overlay(Circle().stroke(KlicColor.surface, lineWidth: 2))
                                }
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.displayName).font(KlicFont.medium()).foregroundStyle(KlicColor.textPrimary)
                            Text("@\(friend.username)").font(KlicFont.caption()).foregroundStyle(KlicColor.textMuted)
                        }
                        Spacer()
                        if isCreatingGroup {
                            Image(systemName: selectedFriendIds.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(selectedFriendIds.contains(friend.id) ? KlicColor.primary : KlicColor.textMuted)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                    }
                    .padding(12).background(KlicColor.surface, in: RoundedRectangle(cornerRadius: 18))
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

    private func addFriend() async {
        let name = searchUsername.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return }
        guard let user = try? await APIClient.shared.findUser(username: name), let target = user.first else {
            statusText = "No user named “\(name)”."; return
        }
        _ = try? await APIClient.shared.sendFriendRequest(userId: target.id)
        statusText = "Request sent to \(target.displayName)."
        searchUsername = ""
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

    private func createGroup() async {
        let title = groupTitle.trimmingCharacters(in: .whitespaces)
        let ids = Array(selectedFriendIds)
        guard ids.count >= 2, !title.isEmpty else { return }
        openedConversation = try? await APIClient.shared.createGroupConversation(title: title, userIds: ids)
        if openedConversation != nil {
            withAnimation(.easeInOut(duration: 0.15)) {
                isCreatingGroup = false
                groupTitle = ""
                selectedFriendIds.removeAll()
            }
        }
    }

    private func toggleFriendSelection(_ id: String) {
        if selectedFriendIds.contains(id) { selectedFriendIds.remove(id) }
        else { selectedFriendIds.insert(id) }
    }

    private var groupStatusText: String {
        if !isCreatingGroup { return "Pick friends and create a shared chat." }
        switch selectedFriendIds.count {
        case 0: return "Select at least two friends below."
        case 1: return "Select one more friend."
        default: return "\(selectedFriendIds.count) selected"
        }
    }

    private func callFriend(_ friend: User, kind: String) async {
        guard let convo = try? await APIClient.shared.openConversation(userId: friend.id),
              let session = try? await APIClient.shared.startCall(conversationId: convo.id, kind: kind)
        else { return }
        CallKitManager.shared.startOutgoing(session, peerName: friend.displayName, peerId: friend.id)
    }
}

import SwiftUI

struct FriendsView: View {
    @EnvironmentObject var session: AppSession

    @State private var friends: [User] = []
    @State private var requests: [FriendRequest] = []
    @State private var searchUsername = ""
    @State private var statusText: String?
    @State private var openedConversation: Conversation?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    addFriendSection
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
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Friends")
            .navigationDestination(item: $openedConversation) { ChatView(conversation: $0) }
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

    // MARK: Requests

    private var requestsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Requests").font(KlicFont.headline()).foregroundStyle(KlicColor.textPrimary)
            ForEach(requests) { req in
                HStack(spacing: 12) {
                    Avatar()
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
                Button { Task { await openChat(with: friend) } } label: {
                    HStack(spacing: 12) {
                        Avatar()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.displayName).font(KlicFont.medium()).foregroundStyle(KlicColor.textPrimary)
                            Text("@\(friend.username)").font(KlicFont.caption()).foregroundStyle(KlicColor.textMuted)
                        }
                        Spacer()
                        Icon(.message, size: 20, color: KlicColor.textMuted)
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
}

private struct Avatar: View {
    var body: some View {
        Circle().fill(KlicColor.surfaceRaised).frame(width: 44, height: 44)
            .overlay(Icon(.user, size: 20, color: KlicColor.textMuted))
    }
}

import SwiftUI

struct CallDialView: View {
    @State private var friends: [User] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 4) {
                    if friends.isEmpty {
                        Text("No friends yet — add them in Friends.")
                            .font(KlicFont.body(14))
                            .foregroundStyle(KlicColor.textMuted)
                            .padding(.top, 32)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    ForEach(friends) { friend in
                        FriendCallRow(friend: friend)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Call")
            .task { friends = (try? await APIClient.shared.friends()) ?? [] }
        }
        .tint(KlicColor.primary)
    }
}

private struct FriendCallRow: View {
    let friend: User

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(KlicColor.surfaceRaised)
                .frame(width: 50, height: 50)
                .overlay(Icon(.user, size: 20, color: KlicColor.textMuted))
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
                RoundCallButton(icon: .phone, fill: KlicColor.primary) {
                    Task { await initiateCall(kind: "AUDIO") }
                }
                RoundCallButton(icon: .video, fill: KlicColor.surfaceRaised) {
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
    let icon: KlicIcon
    let fill: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 18, color: KlicColor.onPrimary)
                .frame(width: 40, height: 40)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

/// The share panel: search, multi-select friends list, optional message, Send.
/// Sending opens/reuses the direct conversation per selected friend, uploads the media via
/// the presigned flow, and posts one message per friend with all attachments + the text.
struct ShareView: View {
    let inputItems: [NSExtensionItem]
    let onComplete: () -> Void
    let onCancel: () -> Void

    private enum Stage: Equatable {
        case loading
        case needsSignIn
        case ready
        case sending(String)
        case done
        case failed(String)
    }

    @State private var stage: Stage = .loading
    @State private var payload = SharePayload()
    @State private var friends: [ShareAPI.Friend] = []
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var message = ""

    private var filteredFriends: [ShareAPI.Friend] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return friends }
        return friends.filter {
            $0.displayName.lowercased().contains(query) || $0.username.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Share to")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
        }
        .tint(KlicColor.primary)
        .task { await bootstrap() }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsSignIn:
            hint(icon: "person.crop.circle.badge.exclamationmark",
                 title: "Open Klic and sign in first",
                 subtitle: "Sharing needs your Klic account.")
        case .failed(let message):
            hint(icon: "exclamationmark.triangle", title: "Couldn’t share", subtitle: message)
        case .done:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                Text("Sent").font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .sending(let progress):
            VStack(spacing: 14) {
                ProgressView()
                Text(progress).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            picker
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search friends", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.top, 8)

            List(filteredFriends) { friend in
                Button {
                    if selected.contains(friend.id) {
                        selected.remove(friend.id)
                    } else {
                        selected.insert(friend.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        ShareAvatarView(friend: friend)
                        Text(friend.displayName)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: selected.contains(friend.id)
                              ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(selected.contains(friend.id)
                                             ? KlicColor.primary : Color(.tertiaryLabel))
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if friends.isEmpty {
                    Text("No friends yet")
                        .foregroundStyle(.secondary)
                } else if filteredFriends.isEmpty {
                    Text("No matches")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 10) {
                TextField("Add a message…", text: $message, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                Button(action: { Task { await send() } }) {
                    Text(selected.count > 1 ? "Send to \(selected.count) friends" : "Send")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            selected.isEmpty ? Color(.systemGray4) : KlicColor.primary,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .foregroundStyle(.white)
                }
                .disabled(selected.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func hint(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close", action: onCancel)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func bootstrap() async {
        guard TokenStore.hasSession else {
            stage = .needsSignIn
            return
        }
        payload = await SharePayloadLoader.load(from: inputItems)
        message = payload.text
        do {
            friends = try await ShareAPI.shared.friends()
            stage = .ready
        } catch ShareAPI.ShareAPIError.notSignedIn {
            stage = .needsSignIn
        } catch {
            stage = .failed((error as? LocalizedError)?.errorDescription
                            ?? "Something went wrong. Please try again.")
        }
    }

    private func send() async {
        let recipients = friends.filter { selected.contains($0.id) }
        guard !recipients.isEmpty else { return }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Text-only share with an emptied message field: nothing to send.
        guard !payload.media.isEmpty || !text.isEmpty else {
            onCancel()
            return
        }
        do {
            for (index, friend) in recipients.enumerated() {
                stage = .sending("Sending to \(friend.displayName) (\(index + 1)/\(recipients.count))…")
                let conversationId = try await ShareAPI.shared.openConversation(userId: friend.id)
                try await ShareAPI.shared.sendShare(
                    conversationId: conversationId,
                    text: text.isEmpty ? nil : text,
                    media: payload.media
                )
            }
            stage = .done
            try? await Task.sleep(nanoseconds: 900_000_000)
            onComplete()
        } catch ShareAPI.ShareAPIError.notSignedIn {
            stage = .needsSignIn
        } catch {
            stage = .failed((error as? LocalizedError)?.errorDescription
                            ?? "Something went wrong. Please try again.")
        }
    }
}

/// Circular avatar with an initials fallback (the extension has no image cache; AsyncImage
/// follows the avatar endpoint's 302 to the presigned image, or fails to the initials).
private struct ShareAvatarView: View {
    let friend: ShareAPI.Friend
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: URL(string: friend.avatarUrl ?? AppConfig.avatarURL(forUserId: friend.id))) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: some View {
        ZStack {
            Circle().fill(KlicColor.primary.opacity(0.18))
            Text(initialsText)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(KlicColor.primary)
        }
    }

    private var initialsText: String {
        let letters = friend.displayName.split(separator: " ")
            .prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

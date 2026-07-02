import SwiftUI
import PhotosUI
import Inject

struct GroupInfoView: View {
    @ObserveInjection var inject
    let conversationId: String
    let title: String
    let initialDetails: GroupConversationDetails?
    let fallbackMembers: [ChatProfileTarget]
    let onSelectMember: (ChatProfileTarget) -> Void
    let onUpdated: (GroupConversationDetails) -> Void
    let onDeleted: () -> Void
    /// Starts (or joins) the group call via the chat's existing flows. "AUDIO" | "VIDEO".
    var onStartCall: (String) -> Void = { _ in }
    /// Opens the chat's message-search sheet (the info page dismisses itself first).
    var onSearchMessages: () -> Void = {}

    var body: some View {
        GroupInfoContent(
            conversationId: conversationId,
            fallbackTitle: title,
            initialDetails: initialDetails,
            fallbackMembers: fallbackMembers,
            onSelectMember: onSelectMember,
            onUpdated: onUpdated,
            onDeleted: onDeleted,
            onStartCall: onStartCall,
            onSearchMessages: onSearchMessages
        )
        .enableInjection()
    }
}

private struct GroupInfoContent: View {
    @ObserveInjection var inject
    let conversationId: String
    let fallbackTitle: String
    let initialDetails: GroupConversationDetails?
    let fallbackMembers: [ChatProfileTarget]
    let onSelectMember: (ChatProfileTarget) -> Void
    let onUpdated: (GroupConversationDetails) -> Void
    let onDeleted: () -> Void
    let onStartCall: (String) -> Void
    let onSearchMessages: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var details: GroupConversationDetails?
    @State private var loading = false
    @State private var editing = false
    @State private var editTitle = ""
    @State private var editDescription = ""
    @State private var searchMembers = false
    @State private var memberQuery = ""
    @State private var addSheet = false
    @State private var pickedCover: PhotosPickerItem?
    @State private var savingCover = false
    @State private var leaving = false
    @State private var error: String?
    @State private var showDeleteDialog = false

    private var resolvedDetails: GroupConversationDetails? { details ?? initialDetails }
    private var resolvedTitle: String { resolvedDetails?.title?.trimmingCharacters(in: .whitespaces).isEmpty == false ? (resolvedDetails?.title ?? fallbackTitle) : fallbackTitle }
    private var resolvedDescription: String? {
        guard let text = resolvedDetails?.description?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        return text
    }
    private var isAdmin: Bool { resolvedDetails?.isAdmin == true }
    private var members: [GroupConversationDetails.Member] {
        if let loaded = resolvedDetails?.members, !loaded.isEmpty {
            return loaded
        }
        return fallbackMembers.map {
            GroupConversationDetails.Member(
                id: $0.id,
                username: $0.username,
                displayName: $0.displayName,
                avatarUrl: $0.avatarUrl,
                joinedAt: "",
                isMe: false
            )
        }
    }
    private var filteredMembers: [GroupConversationDetails.Member] {
        let q = memberQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return members }
        return members.filter {
            $0.displayName.lowercased().contains(q) || $0.username.lowercased().contains(q)
        }
    }

    private var createdByName: String? {
        guard let creatorId = resolvedDetails?.createdById else { return nil }
        if let member = members.first(where: { $0.id == creatorId }) {
            return member.isMe ? "you" : member.displayName
        }
        return fallbackMembers.first(where: { $0.id == creatorId })?.displayName
    }

    private var createdAtText: String? {
        guard let date = ChatLocalPrefs.parseISO(resolvedDetails?.createdAt) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 16) {
                    coverPicker
                    VStack(spacing: 6) {
                        Text(resolvedTitle)
                            .font(KlicFont.headline(22))
                            .foregroundStyle(KlicColor.textPrimary)
                            .multilineTextAlignment(.center)
                        if let description = resolvedDescription {
                            Text(description)
                                .font(KlicFont.body(14))
                                .foregroundStyle(KlicColor.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        Text("\(members.count) members")
                            .font(KlicFont.caption())
                            .foregroundStyle(KlicColor.textMuted)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(KlicColor.background)
            }

            Section {
                HStack(spacing: 12) {
                    actionButton(title: "Audio", systemName: "phone.fill") {
                        onStartCall("AUDIO")
                        dismiss()
                    }
                    actionButton(title: "Video", systemName: "video.fill") {
                        onStartCall("VIDEO")
                        dismiss()
                    }
                    actionButton(title: "Add", systemName: "person.badge.plus.fill", disabled: !isAdmin) {
                        addSheet = true
                    }
                    // Message search over the chat's history (CALLS.md §8.4).
                    actionButton(title: "Search", systemName: "magnifyingglass") {
                        onSearchMessages()
                        dismiss()
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(KlicColor.background)
            }

            if searchMembers {
                Section {
                    KlicTextField(placeholder: "Search members", text: $memberQuery)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(KlicColor.background)
                }
            }

            // Media / Starred / Manage storage / Save to Photos + Notifications (§8.4)
            Section {
                ChatInfoCommonRows(
                    conversationId: conversationId,
                    members: fallbackMembers.isEmpty
                        ? members.map { ChatProfileTarget(id: $0.id, username: $0.username, displayName: $0.displayName, avatarUrl: $0.avatarUrl) }
                        : fallbackMembers
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                ChatNotificationsCard(conversationId: conversationId, isGroup: true)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if editing {
                Section("Edit group") {
                    TextField("Group name", text: $editTitle)
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                    TextField("Description", text: $editDescription, axis: .vertical)
                        .font(KlicFont.body())
                        .foregroundStyle(KlicColor.textPrimary)
                        .lineLimit(3, reservesSpace: true)
                    Button("Save changes") { Task { await saveEdits() } }
                        .foregroundStyle(KlicColor.primary)
                }
            } else {
                Section {
                    NavigationLink("View all members") {
                        GroupMemberListView(members: filteredMembers, onSelectMember: onSelectMember)
                    }
                    .foregroundStyle(KlicColor.textPrimary)

                    if isAdmin {
                        Button("Delete Group", role: .destructive) {
                            showDeleteDialog = true
                        }
                    } else {
                        Button("Exit Group", role: .destructive) {
                            Task { await leaveGroup() }
                        }
                        .disabled(leaving)
                    }
                }
            }

            if !filteredMembers.isEmpty {
                Section("Members") {
                    ForEach(filteredMembers.prefix(6)) { member in
                        memberRow(member)
                    }
                }
            }

            if let error {
                Section {
                    Text(error)
                        .font(KlicFont.caption())
                        .foregroundStyle(.red)
                        .listRowBackground(KlicColor.background)
                }
            }

            // Footer: who created the group and when (§8.4).
            if createdByName != nil || createdAtText != nil {
                Section {
                    VStack(alignment: .center, spacing: 2) {
                        if let createdByName {
                            Text("Created by \(createdByName)")
                        }
                        if let createdAtText {
                            Text("Created \(createdAtText)")
                        }
                    }
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
                    .listRowBackground(KlicColor.background)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Group Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isAdmin {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "Done" : "Edit") {
                        if editing {
                            editing = false
                        } else {
                            editTitle = resolvedDetails?.title ?? fallbackTitle
                            editDescription = resolvedDetails?.description ?? ""
                            editing = true
                        }
                    }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $addSheet) {
            AddGroupMembersSheet(conversationId: conversationId, currentMemberIds: Set(members.map(\.id))) { updated in
                apply(updated)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: pickedCover) { _, item in
            guard let item else { return }
            Task {
                await uploadCover(item)
                // Reset the selection or picking the SAME photo again never fires
                // onChange — this is what made re-uploading a cover look broken.
                pickedCover = nil
            }
        }
        .confirmationDialog("Delete this group?", isPresented: $showDeleteDialog, titleVisibility: .visible) {
            Button("Delete Group", role: .destructive) {
                Task { await deleteGroup() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the group chat and all of its messages for everyone.")
        }
        .enableInjection()
    }

    @ViewBuilder
    private var coverPicker: some View {
        if isAdmin {
            PhotosPicker(selection: $pickedCover, matching: .images) {
                coverView.overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(KlicColor.onPrimary)
                        .frame(width: 34, height: 34)
                        .background(KlicColor.primary, in: Circle())
                        .overlay(Circle().stroke(KlicColor.background, lineWidth: 3))
                        .padding(10)
                }
            }
            .buttonStyle(.plain)
        } else {
            coverView
        }
    }

    private var coverView: some View {
        AvatarView(url: resolvedDetails?.avatarUrl, name: resolvedTitle, size: 104)
            .overlay {
                if savingCover {
                    ProgressView()
                        .tint(KlicColor.primary)
                }
            }
    }

    private func actionButton(title: String, systemName: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(disabled ? KlicColor.textMuted : KlicColor.onPrimary)
                    .frame(width: 48, height: 48)
                    .background(disabled ? KlicColor.surfaceRaised : KlicColor.primary, in: Circle())
                Text(title)
                    .font(KlicFont.caption(12))
                    .foregroundStyle(KlicColor.textMuted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func memberRow(_ member: GroupConversationDetails.Member) -> some View {
        Button {
            onSelectMember(ChatProfileTarget(id: member.id, username: member.username, displayName: member.displayName, avatarUrl: member.avatarUrl))
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: member.avatarUrl, name: member.displayName, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(member.displayName)
                            .font(KlicFont.medium())
                            .foregroundStyle(KlicColor.textPrimary)
                        if member.isMe {
                            Text("You")
                                .font(KlicFont.caption(11))
                                .foregroundStyle(KlicColor.textMuted)
                        }
                    }
                    Text("@\(member.username)")
                        .font(KlicFont.caption())
                        .foregroundStyle(KlicColor.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KlicColor.textMuted)
            }
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let fetched = try? await APIClient.shared.conversationDetails(id: conversationId) {
            apply(fetched)
        }
    }

    private func saveEdits() async {
        guard let current = resolvedDetails else { return }
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let description = editDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let updated = try await APIClient.shared.updateGroupConversation(
                id: conversationId,
                title: title,
                description: description.isEmpty ? nil : description
            )
            editing = false
            apply(updated)
        } catch let e as APIError {
            self.error = e.userMessage
            apply(current)
        } catch {
            self.error = "Couldn't save the group right now."
        }
    }

    private func uploadCover(_ item: PhotosPickerItem) async {
        savingCover = true
        defer { savingCover = false }
        error = nil
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let (jpeg, _, _) = Media.encodeImage(image) else { return }
            let ticket = try await APIClient.shared.requestGroupAvatarUpload(
                conversationId: conversationId,
                contentType: "image/jpeg",
                byteSize: jpeg.count
            )
            try await APIClient.shared.uploadData(jpeg, to: ticket.uploadUrl, contentType: "image/jpeg")
            let updated = try await APIClient.shared.updateGroupConversation(id: conversationId, avatarKey: ticket.key)
            apply(updated)
        } catch let e as APIError {
            self.error = e.userMessage
        } catch {
            self.error = "Couldn't upload the group cover."
        }
    }

    private func leaveGroup() async {
        leaving = true
        defer { leaving = false }
        do {
            _ = try await APIClient.shared.leaveGroup(conversationId: conversationId)
            dismiss()
        } catch let e as APIError {
            self.error = e.userMessage
        } catch {
            self.error = "Couldn't leave the group."
        }
    }

    private func deleteGroup() async {
        leaving = true
        defer { leaving = false }
        do {
            _ = try await APIClient.shared.deleteGroup(conversationId: conversationId)
            onDeleted()
            dismiss()
        } catch let e as APIError {
            self.error = e.userMessage
        } catch {
            self.error = "Couldn't delete the group."
        }
    }

    private func apply(_ updated: GroupConversationDetails) {
        details = updated
        onUpdated(updated)
        editTitle = updated.title ?? fallbackTitle
        editDescription = updated.description ?? ""
        error = nil
    }
}

private struct GroupMemberListView: View {
    let members: [GroupConversationDetails.Member]
    let onSelectMember: (ChatProfileTarget) -> Void

    var body: some View {
        List(members) { member in
            Button {
                onSelectMember(ChatProfileTarget(id: member.id, username: member.username, displayName: member.displayName, avatarUrl: member.avatarUrl))
            } label: {
                HStack(spacing: 12) {
                    AvatarView(url: member.avatarUrl, name: member.displayName, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName)
                            .font(KlicFont.medium())
                            .foregroundStyle(KlicColor.textPrimary)
                        Text("@\(member.username)")
                            .font(KlicFont.caption())
                            .foregroundStyle(KlicColor.textMuted)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .listRowBackground(KlicColor.surface)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(KlicColor.background.ignoresSafeArea())
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AddGroupMembersSheet: View {
    let conversationId: String
    let currentMemberIds: Set<String>
    let onUpdated: (GroupConversationDetails) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var friends: [User] = []
    @State private var selectedIds: Set<String> = []
    @State private var loading = false
    @State private var saving = false

    private var availableFriends: [User] {
        friends.filter { !currentMemberIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(availableFriends) { friend in
                Button {
                    if selectedIds.contains(friend.id) { selectedIds.remove(friend.id) }
                    else { selectedIds.insert(friend.id) }
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: friend.avatarUrl, name: friend.displayName, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.displayName)
                                .font(KlicFont.medium())
                                .foregroundStyle(KlicColor.textPrimary)
                            Text("@\(friend.username)")
                                .font(KlicFont.caption())
                                .foregroundStyle(KlicColor.textMuted)
                        }
                        Spacer()
                        Image(systemName: selectedIds.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(selectedIds.contains(friend.id) ? KlicColor.primary : KlicColor.textMuted)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(KlicColor.surface)
            }
            .overlay {
                if loading {
                    ProgressView()
                } else if availableFriends.isEmpty {
                    Text("No more friends to add.")
                        .font(KlicFont.body(14))
                        .foregroundStyle(KlicColor.textMuted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(KlicColor.background.ignoresSafeArea())
            .navigationTitle("Add members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Adding…" : "Add") { Task { await addMembers() } }
                        .disabled(selectedIds.isEmpty || saving)
                }
            }
            .task { await loadFriends() }
        }
    }

    private func loadFriends() async {
        loading = true
        defer { loading = false }
        friends = (try? await APIClient.shared.friends()) ?? []
    }

    private func addMembers() async {
        saving = true
        defer { saving = false }
        guard let updated = try? await APIClient.shared.addGroupMembers(conversationId: conversationId, userIds: Array(selectedIds)) else { return }
        onUpdated(updated)
        dismiss()
    }
}

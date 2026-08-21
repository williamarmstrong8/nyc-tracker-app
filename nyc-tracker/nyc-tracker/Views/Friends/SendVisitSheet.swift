import SwiftUI

/// Send one of your visits to friends in chat.
///
/// Same picker shape as `SendPlaceSheet` — multi-select friends, one note —
/// but the payload is a `send_message` with your visit attached, so the
/// recipient sees your write-up card in the thread rather than a wishlist row.
struct SendVisitSheet: View {
    let visit: Visit

    @Environment(SocialGraph.self) private var graph
    @Environment(ChatStore.self) private var chat
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selected: Set<UUID> = []
    @State private var message = ""
    @State private var isSending = false
    @State private var results: [SendVisitResult]?

    private var placeID: UUID? { visit.place?.remotePlaceID }
    private var visitID: UUID? { visit.remoteID }

    private var canSendVisit: Bool {
        placeID != nil && visitID != nil
    }

    private var filteredFriends: [FriendshipEdge] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return graph.friends }
        return graph.friends.filter { edge in
            edge.person.bestName.lowercased().contains(trimmed)
                || (edge.person.username?.lowercased().contains(trimmed) ?? false)
        }
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        canSendVisit && !selected.isEmpty && !trimmedMessage.isEmpty && !isSending
    }

    private var heroPhoto: PhotoView.Source? {
        guard let photo = visit.photos.sorted(by: { $0.order < $1.order }).first else {
            return nil
        }
        return PhotoView.Source(photo: photo, wantsThumbnail: true)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let results {
                    resultsList(results)
                } else if !canSendVisit {
                    syncingState
                } else if graph.friends.isEmpty {
                    noFriendsState
                } else {
                    picker
                }
            }
            .flatModalContentBackground()
            .navigationTitle(results == nil ? "Send to a friend" : "Sent")
            .navigationBarTitleDisplayMode(.inline)
            .flatModalToolbarBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(results == nil ? "Cancel" : "Done") { dismiss() }
                }
                if results == nil && canSendVisit && !graph.friends.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await send() }
                        } label: {
                            if isSending {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Send").fontWeight(.semibold)
                            }
                        }
                        .disabled(!canSubmit)
                        .tint(.blue)
                    }
                }
            }
        }
        .flatModalBackground()
    }

    // MARK: - Picker

    private var picker: some View {
        List {
            Section {
                visitHeader
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }

            if !selected.isEmpty {
                Section("Message") {
                    TextField("Say something about it…", text: $message, axis: .vertical)
                        .lineLimit(1...4)
                        .onChange(of: message) { _, new in
                            if new.count > 2000 { message = String(new.prefix(2000)) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Section {
                ForEach(filteredFriends) { edge in
                    friendRow(edge)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                if filteredFriends.isEmpty {
                    Text("No friends match \u{201C}\(query)\u{201D}.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } header: {
                HStack {
                    Text("Friends")
                    Spacer()
                    if !selected.isEmpty {
                        Text("\(selected.count) selected")
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listSectionSpacing(20)
        .flatModalContentBackground()
        .animation(.default, value: selected.isEmpty)
        .appSearchable(text: $query, prompt: "Search friends")
    }

    @ViewBuilder
    private var visitHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            visitThumbnail
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(visit.title.isEmpty ? (visit.place?.name ?? "Untitled") : visit.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let neighborhood = visit.place?.neighborhood, !neighborhood.isEmpty {
                    Text(neighborhood)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !visit.tags.isEmpty {
                    Text(visit.tags.prefix(3).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var visitThumbnail: some View {
        if let heroPhoto {
            PhotoView(source: heroPhoto, contentMode: .fill)
        } else if let place = visit.place {
            let category = place.category
            ZStack {
                categoryTint(category).opacity(0.18)
                Image(systemName: categorySymbol(category))
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(categoryTint(category))
            }
        } else {
            ZStack {
                Color(uiColor: .secondarySystemFill)
                Image(systemName: "photo")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func friendRow(_ edge: FriendshipEdge) -> some View {
        Button {
            Haptics.tap()
            if selected.contains(edge.userID) {
                selected.remove(edge.userID)
            } else {
                selected.insert(edge.userID)
            }
        } label: {
            FriendPersonRow(
                person: edge.person
            ) {
                Image(systemName: selected.contains(edge.userID)
                      ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected.contains(edge.userID) ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected.contains(edge.userID) ? [.isSelected] : [])
    }

    private var syncingState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Still uploading")
                .font(.headline)
            Text("This entry has to finish syncing before you can send it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noFriendsState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("No friends yet")
                .font(.headline)
            Text("Add friends to start sending them places.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private func resultsList(_ results: [SendVisitResult]) -> some View {
        List {
            ForEach(results) { result in
                let person = graph.friend(withID: result.recipientID)?.person
                    ?? PersonSummary(id: result.recipientID, username: nil, displayName: nil, avatarURL: nil)

                HStack(spacing: 12) {
                    PersonAvatar(person: person, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.bestName).font(.subheadline.weight(.semibold))
                        Text(result.succeeded ? "Sent in chat" : "Couldn't send")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(result.succeeded ? .green : .orange)
                }
                .padding(.vertical, 2)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .flatModalContentBackground()
    }

    // MARK: - Sending

    private func send() async {
        guard let placeID, let visitID else { return }

        isSending = true
        defer { isSending = false }

        var outcome: [SendVisitResult] = []
        for friendID in selected {
            guard let conversationID = await chat.openConversation(with: friendID) else {
                outcome.append(SendVisitResult(recipientID: friendID, succeeded: false))
                continue
            }
            let sent = await chat.send(
                in: conversationID,
                body: trimmedMessage,
                place: placeID,
                visit: visitID
            )
            outcome.append(SendVisitResult(recipientID: friendID, succeeded: sent))
        }

        results = outcome
        if outcome.contains(where: \.succeeded) {
            Haptics.success()
        } else if let error = chat.lastError {
            graph.lastError = error
            dismiss()
        }
    }

    private func categorySymbol(_ category: PlaceCategory) -> String {
        switch category {
        case .restaurant: "fork.knife"
        case .bar:        "wineglass.fill"
        case .cafe:       "cup.and.saucer.fill"
        case .bakery:     "birthday.cake.fill"
        case .other:      "mappin"
        }
    }

    private func categoryTint(_ category: PlaceCategory) -> Color {
        switch category {
        case .restaurant: .orange
        case .bar:        .purple
        case .cafe:       .brown
        case .bakery:     .pink
        case .other:      .gray
        }
    }
}

private struct SendVisitResult: Identifiable {
    let recipientID: UUID
    let succeeded: Bool
    var id: UUID { recipientID }
}

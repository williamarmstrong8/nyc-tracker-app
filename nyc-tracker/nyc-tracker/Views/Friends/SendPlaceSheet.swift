import SwiftUI

/// Send a place to friends: multi-select, searchable, one optional message.
///
/// Multi-select because the real gesture is "everyone who'd like this", not
/// "one person at a time" — recommending a great spot to five people should be
/// one action, and the RPC takes an array precisely so it can be.
///
/// The message is attached to every recipient rather than per-person. A
/// per-recipient note sounds better and is worse: it turns one send into five
/// composition steps, and the message people actually write ("you'd love this")
/// is the same for everyone.
struct SendPlaceSheet: View {
    let place: PlaceSummary

    @Environment(SocialGraph.self) private var graph
    @Environment(SocialStatsCache.self) private var stats
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selected: Set<UUID> = []
    @State private var message = ""
    @State private var isSending = false
    @State private var results: [RecommendationSendResult]?

    private var filteredFriends: [FriendshipEdge] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return graph.friends }
        return graph.friends.filter { edge in
            edge.person.bestName.lowercased().contains(trimmed)
                || (edge.person.username?.lowercased().contains(trimmed) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let results {
                    SendResultsList(results: results, graph: graph)
                } else if graph.friends.isEmpty {
                    noFriendsState
                } else {
                    picker
                }
            }
            .navigationTitle(results == nil ? "Send to friends" : "Sent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(results == nil ? "Cancel" : "Done") { dismiss() }
                }
                if results == nil && !graph.friends.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await send() }
                        } label: {
                            if isSending {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Send")
                            }
                        }
                        .disabled(selected.isEmpty || isSending)
                    }
                }
            }
        }
    }

    // MARK: - Picker

    private var picker: some View {
        List {
            Section {
                placeHeader
            }

            Section("Message (optional)") {
                TextField("Why they'd like it…", text: $message, axis: .vertical)
                    .lineLimit(1...4)
                    // Matches the `recommendations_message_length` CHECK. The DB
                    // is the guarantee; this stops the user writing 600
                    // characters and only finding out on submit.
                    .onChange(of: message) { _, new in
                        if new.count > 500 { message = String(new.prefix(500)) }
                    }
            }

            Section {
                ForEach(filteredFriends) { edge in
                    friendRow(edge)
                }
                if filteredFriends.isEmpty {
                    Text("No friends match \u{201C}\(query)\u{201D}.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search friends")
    }

    private var placeHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: categorySymbol(place.category))
                .font(.subheadline)
                .foregroundStyle(categoryTint(place.category))
                .frame(width: 40, height: 40)
                .background(Circle().fill(categoryTint(place.category).opacity(0.15)))

            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.headline).lineLimit(1)
                if let subtitle = place.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
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
            HStack(spacing: 12) {
                PersonAvatar(person: edge.person, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(edge.person.bestName).font(.body).lineLimit(1)
                    if let handle = edge.person.handle {
                        Text(handle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
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

    // MARK: - Sending

    private func send() async {
        isSending = true
        defer { isSending = false }

        do {
            let outcome = try await RecommendationService.send(
                place: place.id,
                to: Array(selected),
                message: message
            )
            results = outcome
            Haptics.success()
            // The sender's own place sheet shows "you recommended this", so the
            // cached aggregate for this place is now stale by their own action.
            stats.invalidate(placeID: place.id)
        } catch {
            // Only genuine failures land here — already-sent and already-visited
            // come back as outcomes, not errors.
            graph.lastError = SupabaseErrorPresenter.presentable(error, context: .general)
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

/// What happened, per recipient.
///
/// Shown as a result screen rather than a toast because a batch send has a batch
/// answer: three delivered, one already had it, one you'd already sent to. A
/// single "Sent!" would be a lie in exactly the cases the RPC works hardest to
/// get right.
private struct SendResultsList: View {
    let results: [RecommendationSendResult]
    let graph: SocialGraph

    var body: some View {
        List {
            ForEach(results) { result in
                let person = graph.friend(withID: result.recipientID)?.person
                    ?? PersonSummary(id: result.recipientID, username: nil, displayName: nil, avatarURL: nil)

                HStack(spacing: 12) {
                    PersonAvatar(person: person, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.bestName).font(.subheadline.weight(.semibold))
                        Text(caption(for: result.outcome, name: person.shortName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: symbol(for: result.outcome))
                        .foregroundStyle(tint(for: result.outcome))
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func caption(for outcome: RecommendationOutcome, name: String) -> String {
        switch outcome {
        case .sent:           "Added to their wishlist"
        case .alreadySent:    "You'd already sent them this"
        case .alreadyVisited: "\(name) has already been — saved to their been-there list"
        case .notFriends:     "Not a friend anymore"
        case .isSelf:         "That's you"
        }
    }

    private func symbol(for outcome: RecommendationOutcome) -> String {
        switch outcome {
        case .sent:           "checkmark.circle.fill"
        case .alreadyVisited: "mappin.circle.fill"
        case .alreadySent:    "clock.arrow.circlepath"
        case .notFriends, .isSelf: "exclamationmark.circle"
        }
    }

    private func tint(for outcome: RecommendationOutcome) -> Color {
        switch outcome {
        case .sent:                     .green
        case .alreadyVisited:           .blue
        case .alreadySent:              .secondary
        case .notFriends, .isSelf:      .orange
        }
    }
}

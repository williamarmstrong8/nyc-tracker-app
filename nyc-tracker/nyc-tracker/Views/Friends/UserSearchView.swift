import SwiftUI

/// Find people by handle or display name, or manage friend requests when the
/// search field is empty.
///
/// The relationship state on each search row comes back with the results in
/// one query — `search_profiles` LEFT JOINs the friendship pair index —
/// rather than one lookup per row. It is then kept live by deriving it from
/// `SocialGraph`, so tapping Add on a row updates that row (and every other
/// surface showing that person) off a single refetch of the edges.
///
/// The search field lives on the parent `AddFriendsView` nav bar (same
/// `appSearchable` as the map search sheet); this view owns the results
/// list. Rows here are identity + action only — no profile push, so
/// accept/decline stay unambiguous tap targets.
struct UserSearchView: View {
    @Binding var query: String

    @Environment(SocialGraph.self) private var graph

    @State private var results: [ProfileSearchResult] = []
    @State private var isSearching = false
    @State private var searchFailed = false
    /// Friends-of-friends shown in place of the old "No requests" empty
    /// state. `nil` means "haven't asked yet" — nothing shows either way,
    /// but keeping it distinct from `[]` avoids a one-frame flash of empty
    /// state before the request lands.
    @State private var recommended: [RecommendedFriend]?
    /// The person whose action button is mid-flight, so only that row spins.
    @State private var busyPersonID: UUID?
    @State private var searchTask: Task<Void, Never>?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var incoming: [FriendshipEdge] {
        graph.incoming.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    private var outgoing: [FriendshipEdge] {
        graph.outgoing.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    var body: some View {
        List {
            if trimmedQuery.isEmpty {
                requestsContent
            } else if results.isEmpty && !isSearching {
                noResultsSection
            } else {
                ForEach(results) { result in
                    row(for: result)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if isSearching && results.isEmpty && !trimmedQuery.isEmpty {
                ProgressView()
            }
        }
        // Debounced so a fast typist produces one query, not one per keystroke.
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .task { graph.refresh() }
        .task { await loadRecommended() }
        .refreshable {
            await graph.reload()
            await loadRecommended()
        }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - Requests (shown when the search field is empty)

    @ViewBuilder
    private var requestsContent: some View {
        if incoming.isEmpty && outgoing.isEmpty {
            recommendedContent
        } else {
            if !incoming.isEmpty {
                Section("Incoming") {
                    ForEach(incoming) { edge in
                        requestRow(edge: edge, relationship: .incoming)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
            }
            if !outgoing.isEmpty {
                Section("Sent") {
                    ForEach(outgoing) { edge in
                        requestRow(edge: edge, relationship: .outgoing)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                }
            }
        }
    }

    /// No custom subtitle — the section header already says "Incoming" or
    /// "Sent", so the row itself just shows who, via `FriendPersonRow`'s
    /// default fallback to the person's @handle.
    private func requestRow(
        edge: FriendshipEdge,
        relationship: RelationshipState
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            FriendPersonRow(person: edge.person)
                .frame(maxWidth: .infinity, alignment: .leading)

            RelationshipButton(
                person: edge.person,
                relationship: relationship,
                isBusy: busyPersonID == edge.userID
            ) { action in
                handle(action, person: edge.person, friendshipID: edge.friendshipID)
            }
        }
    }

    // MARK: - Recommended (shown when there are no pending requests)

    /// Friends-of-friends in place of the old "No requests" placeholder.
    /// Nothing at all when there's nothing to recommend — no icon, no
    /// copy, no `Section` — which is also what keeps this free of the
    /// separator lines a `Section` draws above and below itself even
    /// without a header.
    @ViewBuilder
    private var recommendedContent: some View {
        if let recommended, !recommended.isEmpty {
            Text("Recommended")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))

            ForEach(recommended) { candidate in
                recommendedRow(candidate)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
    }

    private func recommendedRow(_ candidate: RecommendedFriend) -> some View {
        HStack(alignment: .center, spacing: 12) {
            FriendPersonRow(person: candidate.person, subtitle: candidate.mutualFriendsLabel)
                .frame(maxWidth: .infinity, alignment: .leading)

            RelationshipButton(
                person: candidate.person,
                relationship: .none,
                isBusy: busyPersonID == candidate.id
            ) { action in
                handle(action, person: candidate.person, friendshipID: nil)
            }
        }
    }

    // MARK: - Search results

    private func row(for result: ProfileSearchResult) -> some View {
        let snapshot = graph.snapshot(
            for: result.id,
            fallback: result.relationship,
            fallbackFriendshipID: result.friendshipID
        )

        return HStack(alignment: .center, spacing: 12) {
            FriendPersonRow(person: result.person)
                .frame(maxWidth: .infinity, alignment: .leading)

            RelationshipButton(
                person: result.person,
                relationship: snapshot.state,
                isBusy: busyPersonID == result.id
            ) { action in
                handle(action, person: result.person, friendshipID: snapshot.friendshipID)
            }
        }
    }

    private var noResultsSection: some View {
        VStack(spacing: 6) {
            Text(searchFailed ? "Couldn't search" : "No one found")
                .font(.headline)
            Text(searchFailed
                 ? "Check your connection and try again."
                 : "No usernames or names match \u{201C}\(trimmedQuery)\u{201D}.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Search

    /// Best-effort — a failed fetch just keeps the section hidden rather
    /// than showing an error over what used to be a quiet empty state.
    private func loadRecommended() async {
        recommended = try? await FriendshipService.recommendedFriends()
    }

    private func scheduleSearch(for raw: String) {
        searchTask?.cancel()

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            searchFailed = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            isSearching = true
            defer { isSearching = false }

            do {
                let found = try await FriendshipService.search(trimmed)
                guard !Task.isCancelled else { return }
                results = found
                searchFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                searchFailed = true
            }
        }
    }

    // MARK: - Actions

    private func handle(_ action: RelationshipAction, person: PersonSummary, friendshipID: UUID?) {
        Task {
            busyPersonID = person.id
            defer { busyPersonID = nil }

            switch action {
            case .add:
                // The collision case earns a distinct haptic: the user tapped
                // "Add friend" and the result is a friendship, not a request.
                if await graph.sendRequest(to: person.id) == .becameFriends {
                    Haptics.success()
                }

            case .accept:
                guard let friendshipID else { return }
                if await graph.accept(friendshipID) { Haptics.success() }

            case .cancel, .decline, .unfriend:
                guard let friendshipID else { return }
                await graph.remove(friendshipID)
            }
        }
    }
}

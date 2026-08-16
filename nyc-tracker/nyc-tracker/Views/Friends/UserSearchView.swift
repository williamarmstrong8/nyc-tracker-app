import SwiftUI

/// Find people by handle or display name.
///
/// The relationship state on each row comes back with the search results in one
/// query — `search_profiles` LEFT JOINs the friendship pair index — rather than
/// one lookup per row. It is then kept live by deriving it from `SocialGraph`,
/// so tapping Add on a row updates that row (and every other surface showing
/// that person) off a single refetch of the edges.
///
/// Owns its own `NavigationStack` so it can be presented as a sheet from
/// anywhere without every caller remembering to wrap it.
struct UserSearchView: View {
    @Environment(SocialGraph.self) private var graph
    @Environment(\.dismiss) private var dismiss

    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var results: [ProfileSearchResult] = []
    @State private var isSearching = false
    @State private var searchFailed = false
    /// The person whose action button is mid-flight, so only that row spins.
    @State private var busyPersonID: UUID?
    @State private var searchTask: Task<Void, Never>?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if trimmedQuery.isEmpty {
                    promptSection
                } else if results.isEmpty && !isSearching {
                    noResultsSection
                } else {
                    ForEach(results) { result in
                        row(for: result)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Name or username")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Find people")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if isSearching && results.isEmpty {
                    ProgressView()
                }
            }
            .navigationDestination(for: PersonSummary.self) { person in
                FriendProfileView(person: person)
            }
        }
        // Debounced so a fast typist produces one query, not one per keystroke.
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - Rows

    /// Two independent controls rather than a `NavigationLink` wrapping the
    /// action button. A button inside a link's label fights the link's gesture
    /// and the wrong one usually wins; splitting them makes the tap targets
    /// unambiguous — the person opens their profile, the button acts on the
    /// relationship.
    private func row(for result: ProfileSearchResult) -> some View {
        let snapshot = graph.snapshot(
            for: result.id,
            fallback: result.relationship,
            fallbackFriendshipID: result.friendshipID
        )

        return HStack(spacing: 12) {
            Button {
                path.append(result.person)
            } label: {
                HStack(spacing: 12) {
                    PersonAvatar(person: result.person, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        PersonLabel(person: result.person)
                        if let bio = result.bio, !bio.isEmpty {
                            Text(bio)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(result.person.bestName)'s profile")

            RelationshipButton(
                person: result.person,
                relationship: snapshot.state,
                isBusy: busyPersonID == result.id
            ) { action in
                handle(action, person: result.person, friendshipID: snapshot.friendshipID)
            }
        }
        .padding(.vertical, 4)
    }

    private var promptSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Search for people")
                    .font(.headline)
                Text("Find friends by their username or name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .listRowBackground(Color.clear)
        }
    }

    private var noResultsSection: some View {
        Section {
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
        }
    }

    // MARK: - Search

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

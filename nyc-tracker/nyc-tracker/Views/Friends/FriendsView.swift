import SwiftUI

/// The friends page: your accepted friends, alphabetical and searchable, with
/// the inbox and user search one tap away.
///
/// Backed entirely by `SocialGraph`, which holds a single `friendship_edges()`
/// result. There is no separate "my friends" fetch — the list, the inbox, and
/// the badge are three views of one response.
struct FriendsView: View {
    @Environment(SocialGraph.self) private var graph

    @State private var path = NavigationPath()
    @State private var showUserSearch = false
    @State private var query = ""

    private var filteredFriends: [FriendshipEdge] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return graph.friends }
        return graph.friends.filter { edge in
            edge.person.bestName.lowercased().contains(trimmed)
                || (edge.person.username?.lowercased().contains(trimmed) ?? false)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !graph.hasLoaded && graph.friends.isEmpty {
                    // First load. Distinguished from "no friends" so a slow
                    // connection doesn't briefly accuse the user of having none.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if graph.friends.isEmpty {
                    noFriendsState
                } else {
                    friendsList
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.tap()
                        showUserSearch = true
                    } label: {
                        Label("Find people", systemImage: "person.badge.plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: FriendsDestination.inbox) {
                        Label("Inbox", systemImage: "tray")
                            .badgeOverlay(graph.inboxBadgeCount)
                    }
                }
            }
            .navigationDestination(for: FriendsDestination.self) { destination in
                switch destination {
                case .inbox: InboxView()
                }
            }
            .navigationDestination(for: PersonSummary.self) { person in
                FriendProfileView(person: person)
            }
            .sheet(isPresented: $showUserSearch) {
                UserSearchView()
            }
        }
        .task { graph.refresh() }
    }

    private enum FriendsDestination: Hashable {
        case inbox
    }

    // MARK: - List

    private var friendsList: some View {
        List {
            if !graph.incoming.isEmpty {
                Section {
                    NavigationLink(value: FriendsDestination.inbox) {
                        Label(
                            "^[\(graph.incoming.count) friend request](inflect: true)",
                            systemImage: "person.crop.circle.badge.questionmark"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                }
            }

            Section {
                ForEach(filteredFriends) { edge in
                    NavigationLink(value: edge.person) {
                        friendRow(edge)
                    }
                }
                if filteredFriends.isEmpty {
                    Text("No friends match \u{201C}\(query)\u{201D}.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("^[\(graph.friends.count) friend](inflect: true)")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Search friends")
        .refreshable { await graph.reload() }
        // Clear the floating bottom nav.
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 76) }
    }

    private func friendRow(_ edge: FriendshipEdge) -> some View {
        HStack(spacing: 12) {
            PersonAvatar(person: edge.person, size: 44, showsPaletteRing: true)
            VStack(alignment: .leading, spacing: 2) {
                PersonLabel(person: edge.person, nameFont: .subheadline.weight(.semibold))
                if let bio = edge.bio, !bio.isEmpty {
                    Text(bio)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Empty state

    /// Points at user search rather than sitting there blank — with no friends,
    /// finding one is the only useful action on this screen.
    private var noFriendsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("No friends yet")
                .font(.headline)
            Text("Find people by username to see their places on your map.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Haptics.tap()
                showUserSearch = true
            } label: {
                Label("Find people", systemImage: "person.badge.plus")
                    .frame(minWidth: 200, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 6)

            if !graph.incoming.isEmpty {
                Button {
                    Haptics.tap()
                    path.append(FriendsDestination.inbox)
                } label: {
                    Text("^[\(graph.incoming.count) pending request](inflect: true)")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Badge

extension View {
    /// Small count badge in the top-trailing corner. Hidden at zero — a badge
    /// showing "0" is a notification that nothing happened.
    func badgeOverlay(_ count: Int) -> some View {
        overlay(alignment: .topTrailing) {
            if count > 0 {
                Text(count > 99 ? "99+" : "\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
                    .offset(x: 10, y: -8)
                    .accessibilityLabel("^[\(count) pending item](inflect: true)")
            }
        }
    }
}

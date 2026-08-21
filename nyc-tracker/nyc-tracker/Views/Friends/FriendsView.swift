import SwiftUI

/// The friends page: your accepted friends, alphabetical and searchable.
/// Add friends (search + requests) is a full-screen cover, not a card on this list.
///
/// Backed entirely by `SocialGraph`, which holds a single `friendship_edges()`
/// result. There is no separate "my friends" fetch — the list and the badge
/// are two views of one response.
///
/// ## Same list, different destination
///
/// A row opens the conversation with that person, not their profile. The list
/// itself is unchanged — still the friend graph, still alphabetical, still
/// searchable by name or handle — because sorting by recent activity would make
/// the page reorder itself under the user's thumb and would bury everyone they
/// have never messaged. The only additions are the last-message line in place
/// of the handle and an unread dot. The profile is still reachable, one tap
/// further in, from the chat's header.
struct FriendsView: View {
    let userID: UUID

    var body: some View {
        FriendsNavigationStack(userID: userID)
    }
}

/// Friends-tab navigation destinations. One enum rather than separate
/// `ChatRoute` / `PersonSummary` pushes so the stack can be read when deciding
/// whether the bottom bar should show — `onDisappear` on a pushed page fires
/// after the pop animation, which is the delay users notice on the way back.
enum FriendsRoute: Hashable {
    case chat(PersonSummary)
    case profile(PersonSummary)
}

/// Owns the friends list navigation stack — shared by the bottom tab and any
/// full-screen presentation (e.g. from Profile).
struct FriendsNavigationStack: View {
    let userID: UUID
    var showsDismissButton = false

    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @Environment(SocialGraph.self) private var graph
    @Environment(ChatStore.self) private var chat

    @State private var path: [FriendsRoute] = []
    @State private var showAddFriends = false

    var body: some View {
        NavigationStack(path: $path) {
            FriendsListScreen(
                userID: userID,
                showsDismissButton: showsDismissButton,
                onDismiss: showsDismissButton ? { dismiss() } : nil,
                onAddFriends: { showAddFriends = true }
            )
            .navigationDestination(for: FriendsRoute.self) { route in
                switch route {
                case .chat(let person):
                    ChatView(userID: userID, person: person)
                case .profile(let person):
                    FriendProfileView(person: person)
                }
            }
        }
        .onAppear { syncBottomBar(with: path) }
        .onChange(of: path) { _, newPath in
            syncBottomBar(with: newPath)
        }
        .fullScreenCover(isPresented: $showAddFriends) {
            AddFriendsView()
        }
        .task {
            graph.refresh()
            chat.refreshThreads()
        }
    }

    private func syncBottomBar(with path: [FriendsRoute]) {
        router.hidesBottomBar = path.last.map {
            if case .chat = $0 { true } else { false }
        } ?? false
    }
}

/// The searchable friends list. Embedded in `FriendsNavigationStack` so the
/// same UI can live on the Friends tab or slide up full-screen from Profile.
struct FriendsListScreen: View {
    let userID: UUID
    var showsDismissButton = false
    var onDismiss: (() -> Void)?
    var onAddFriends: () -> Void

    @Environment(SocialGraph.self) private var graph
    @Environment(ChatStore.self) private var chat

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .appSearchable(text: $query, prompt: "Search friends")
        .toolbar {
            if showsDismissButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        Haptics.tap()
                        onDismiss?()
                    }
                }
            }
            ToolbarItem(placement: showsDismissButton ? .topBarTrailing : .topBarLeading) {
                Button {
                    Haptics.tap()
                    onAddFriends()
                } label: {
                    Label("Add friends", systemImage: "person.badge.plus")
                        .notificationDot(!graph.incoming.isEmpty)
                }
                .accessibilityLabel(
                    graph.incoming.isEmpty
                        ? "Add friends"
                        : "Add friends, pending friend requests"
                )
            }
        }
    }

    // MARK: - List

    private var friendsList: some View {
        List {
            Section {
                ForEach(filteredFriends) { edge in
                    NavigationLink(value: FriendsRoute.chat(edge.person)) {
                        friendRow(edge)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                }
                if filteredFriends.isEmpty {
                    Text("No friends match \u{201C}\(query)\u{201D}.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } header: {
                Text("^[\(graph.friends.count) friend](inflect: true)")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await graph.reload()
            await chat.reloadThreads()
        }
    }

    /// One friend, as a thread. Falls back to the plain people row — avatar,
    /// name, handle — until there is something to preview, so a friends list
    /// with no conversations in it looks exactly as it did before.
    private func friendRow(_ edge: FriendshipEdge) -> some View {
        let thread = chat.thread(with: edge.userID)

        return FriendPersonRow(
            person: edge.person,
            subtitle: thread?.preview
        ) {
            if let thread, let sentAt = thread.lastMessageAt {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(sentAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                        .font(.caption2)
                        .foregroundStyle(thread.hasUnread ? Color.accentColor : Color.secondary)
                    if thread.hasUnread {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 9, height: 9)
                            .accessibilityLabel("^[\(thread.unreadCount) unread message](inflect: true)")
                    }
                }
            }
        }
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
                onAddFriends()
            } label: {
                Label("Add friends", systemImage: "person.badge.plus")
                    .frame(minWidth: 200, minHeight: 44)
            }
            .buttonStyle(.glassProminent)
            .padding(.top, 6)
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

    /// Unnumbered red mark that something is waiting. Used on the add-friends
    /// toolbar button so a pending request is visible without crowding the icon.
    func notificationDot(_ show: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            if show {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .offset(x: 3, y: -2)
            }
        }
    }
}

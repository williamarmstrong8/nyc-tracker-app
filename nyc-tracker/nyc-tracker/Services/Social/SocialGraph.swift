import Foundation
import Observation

/// The signed-in user's friend graph, as observable state.
///
/// One source of truth for the friends list and both request queues,
/// which come from a single `friendship_edges()` call because they are
/// always displayed together and splitting them would be extra requests
/// over the same index.
///
/// ## What this deliberately is not
///
/// It is not a cache of other people's *content*. Friend visits live in
/// `FriendVisitCache`, which is ephemeral and separate. This holds the edges and
/// the people on the other end of them — the graph, not what's on it.
///
/// It never touches SwiftData. The local store is the user's own mirror, scoped
/// by user ID, and writing other people's rows into it would corrupt that
/// scoping and make sign-out cleanup ambiguous about whose data to delete.
///
/// App-lifetime, injected through the environment alongside `AuthManager` and
/// `SyncEngine`. Under this project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// the whole type is main-actor isolated, so no explicit annotation is needed.
/// A relationship plus the friendship row that backs it, if any.
///
/// The row id is what accept / decline / cancel / unfriend all operate on, so
/// carrying it alongside the state means no call site has to go looking for it.
struct RelationshipSnapshot: Equatable, Sendable {
    var state: RelationshipState
    var friendshipID: UUID?
}

@Observable
final class SocialGraph {

    // MARK: - Observable state

    /// Accepted friendships, alphabetical by the other party's best name — the
    /// order `friendship_edges()` already returns them in.
    private(set) var friends: [FriendshipEdge] = []
    /// Pending requests sent to me.
    private(set) var incoming: [FriendshipEdge] = []
    /// Pending requests I sent.
    private(set) var outgoing: [FriendshipEdge] = []

    /// Place recommendations sent to me, dismissed ones excluded.
    ///
    /// Lives here rather than in its own store so friend-profile shared counts
    /// and a full reload stay on one refresh.
    private(set) var recommendations: [InboxRecommendation] = []

    private(set) var isLoading = false
    /// False until the first successful load. Distinguishes "no friends" from
    /// "haven't looked yet", which are different empty states.
    private(set) var hasLoaded = false

    /// Set when a refresh or mutation fails in a way worth showing.
    var lastError: PresentableError?

    // MARK: - Private

    private var userID: UUID?
    private var refreshTask: Task<Void, Never>?

    init() {}

    // MARK: - Derived

    /// User IDs of accepted friends. This is what the map's "all friends" mode
    /// filters on, and what an unfriend has to remove.
    var friendIDs: [UUID] { friends.map(\.userID) }

    /// The signed-in user, once configured.
    var currentUserID: UUID? { userID }

    func friend(withID id: UUID) -> FriendshipEdge? {
        friends.first { $0.userID == id }
    }

    func isFriend(_ id: UUID) -> Bool {
        friends.contains { $0.userID == id }
    }

    /// The caller's relationship to `id` plus the row backing it.
    ///
    /// `search_profiles` returns this per row, but that answer is a snapshot: the
    /// moment the user taps Add on one row, every other surface showing that
    /// person is stale. Deriving it from the loaded edges instead means one
    /// `reload()` after a mutation updates the search list, the friends list and
    /// any open profile at once, with no extra round trips and no chance of two
    /// surfaces disagreeing.
    ///
    /// `fallback` covers the two things the edges cannot know: `blocked` rows are
    /// excluded from `friendship_edges()` by design, and before the first load
    /// there is nothing to derive from.
    func snapshot(
        for id: UUID,
        fallback: RelationshipState = .none,
        fallbackFriendshipID: UUID? = nil
    ) -> RelationshipSnapshot {
        if id == userID { return RelationshipSnapshot(state: .isSelf, friendshipID: nil) }

        // The server is the only authority on these two, so never override them.
        if fallback == .blocked || fallback == .isSelf {
            return RelationshipSnapshot(state: fallback, friendshipID: fallbackFriendshipID)
        }

        guard hasLoaded else {
            return RelationshipSnapshot(state: fallback, friendshipID: fallbackFriendshipID)
        }

        if let edge = friends.first(where: { $0.userID == id }) {
            return RelationshipSnapshot(state: .friends, friendshipID: edge.friendshipID)
        }
        if let edge = incoming.first(where: { $0.userID == id }) {
            return RelationshipSnapshot(state: .incoming, friendshipID: edge.friendshipID)
        }
        if let edge = outgoing.first(where: { $0.userID == id }) {
            return RelationshipSnapshot(state: .outgoing, friendshipID: edge.friendshipID)
        }
        return RelationshipSnapshot(state: .none, friendshipID: nil)
    }

    // MARK: - Lifecycle

    /// Point the graph at a signed-in user and load it.
    ///
    /// Idempotent for the same user so it can be called from `.task(id:)` without
    /// re-fetching on every view rebuild.
    func configure(userID: UUID) {
        guard self.userID != userID else { return }
        self.userID = userID
        clearState()
        refresh()
    }

    /// Drop everything. Called on sign-out, before the next account loads.
    func teardown() {
        refreshTask?.cancel()
        refreshTask = nil
        userID = nil
        clearState()
    }

    private func clearState() {
        friends = []
        incoming = []
        outgoing = []
        recommendations = []
        hasLoaded = false
        isLoading = false
        lastError = nil
    }

    // MARK: - Loading

    /// Fire-and-forget refresh, for `.task` and `onAppear`.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.reload()
        }
    }

    /// Awaitable refresh, for pull-to-refresh and for sequencing after a mutation.
    func reload() async {
        guard userID != nil else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            // Concurrent, not sequential: the badge is a sum of both, so showing
            // it a round trip early is showing it wrong.
            async let edgesTask = FriendshipService.edges()
            async let recsTask = RecommendationService.inboxRecommendations()

            let (edges, recs) = try await (edgesTask, recsTask)
            guard !Task.isCancelled else { return }

            apply(edges)
            recommendations = recs
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            // A failed refresh keeps whatever was already loaded. Blanking the
            // list on a network blip would read as "all my friends disappeared".
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
        }
    }

    private func apply(_ edges: [FriendshipEdge]) {
        friends = edges.filter(\.isAcceptedFriend)
        incoming = edges.filter(\.isIncomingRequest)
        outgoing = edges.filter(\.isOutgoingRequest)
    }

    // MARK: - Mutations

    /// What actually happened when a request was sent.
    ///
    /// `.becameFriends` is the simultaneous-request collision surfacing: the
    /// other person had already requested us, Postgres promoted the existing row,
    /// and the correct UI is "you're now friends" — not "requested".
    enum SendOutcome {
        case requested
        case becameFriends
        case failed
    }

    @discardableResult
    func sendRequest(to userID: UUID) async -> SendOutcome {
        do {
            try await FriendshipService.sendRequest(to: userID)
            await reload()
            // Read the outcome off the refreshed graph rather than guessing.
            if isFriend(userID) { return .becameFriends }
            return .requested
        } catch {
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
            return .failed
        }
    }

    @discardableResult
    func accept(_ friendshipID: UUID) async -> Bool {
        await mutate { try await FriendshipService.accept(friendshipID: friendshipID) }
    }

    /// Decline an incoming request, cancel one I sent, or unfriend. One DELETE
    /// covers all three on a mutual graph.
    @discardableResult
    func remove(_ friendshipID: UUID) async -> Bool {
        await mutate { try await FriendshipService.remove(friendshipID: friendshipID) }
    }

    /// Unfriend by person rather than by row, for call sites that only know who
    /// they're looking at (a profile screen, a map pin).
    @discardableResult
    func unfriend(userID: UUID) async -> Bool {
        guard let edge = friend(withID: userID) else { return false }
        return await remove(edge.friendshipID)
    }

    // MARK: - Recommendations

    /// Mark recommendations read.
    ///
    /// Called when a row becomes visible, not when it is tapped — the brief's
    /// rule, and the right one: seeing "Dev sent you Lucali" in the list IS
    /// receiving it, and requiring a tap leaves the badge lit for something the
    /// user has already read.
    ///
    /// Optimistic locally, because the badge should drop the instant the row is
    /// on screen rather than a round trip later. The server call only ever
    /// affects rows still unread, so a duplicate is harmless.
    func markRecommendationsRead(_ ids: [UUID]) {
        let unread = ids.filter { id in
            recommendations.contains { $0.id == id && $0.isUnread }
        }
        guard !unread.isEmpty else { return }

        for index in recommendations.indices where unread.contains(recommendations[index].id) {
            recommendations[index].status = .read
            recommendations[index].readAt = Date()
        }

        Task { [unread] in
            // A failure here is genuinely not worth surfacing: the cost is a
            // badge that reappears on next launch, and an alert over it would be
            // an interruption about nothing the user asked for.
            try? await RecommendationService.markRead(unread)
        }
    }

    /// Dismiss a recommendation: gone from the inbox, still on the wishlist.
    ///
    /// Two separate decisions — "stop showing me this notification" is not "I
    /// don't want to go" — so this deliberately does not touch `wishlist_items`.
    @discardableResult
    func dismissRecommendation(_ id: UUID) async -> Bool {
        let previous = recommendations
        // Optimistic removal: dismissing is a deliberate swipe and the row
        // lingering while a round trip completes reads as the tap not landing.
        recommendations.removeAll { $0.id == id }

        do {
            try await RecommendationService.dismiss(id)
            return true
        } catch {
            recommendations = previous
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
            return false
        }
    }

    /// Refresh only the recommendations half, after sending one to someone.
    func refreshRecommendations() async {
        guard userID != nil else { return }
        do {
            recommendations = try await RecommendationService.inboxRecommendations()
        } catch {
            // Keep what's on screen; the next full reload will correct it.
        }
    }

    private func mutate(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            await reload()
            return true
        } catch {
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
            // Refresh anyway: the most common failure is a row someone else
            // already resolved, and the truth is now on the server.
            await reload()
            return false
        }
    }
}

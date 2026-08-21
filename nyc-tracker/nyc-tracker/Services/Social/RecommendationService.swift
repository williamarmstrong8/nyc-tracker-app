import Foundation
import Supabase

/// Wire calls for recommendations, the wishlist, the explore feed, and social
/// stats.
///
/// Stateless, like `FriendshipService`. The observable stores
/// (`SocialGraph`, `WishlistStore`, `FeedStore`, `SocialStatsCache`) own
/// retry and caching policy; this owns the request shapes.
enum RecommendationService {

    private static var client: SupabaseClient { SupabaseManager.client }

    // MARK: - Sending

    /// Send a place to several friends at once, with one optional message.
    ///
    /// The recommendation rows and the recipients' wishlist rows are written in
    /// one Postgres function. Sequential client calls would leave half-sent
    /// state — an inbox row with no wishlist item, or a wishlist item nobody can
    /// trace — and that state is invisible until someone reports it as a bug.
    ///
    /// Never throws for the ordinary cases (already sent, already been there,
    /// not friends). Those come back as per-recipient outcomes so a batch of
    /// five succeeds for the three it can.
    static func send(
        place placeID: UUID,
        to recipients: [UUID],
        message: String?
    ) async throws -> [RecommendationSendResult] {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = RecommendPlaceParams(
            place: placeID,
            recipients: recipients,
            message: (trimmed?.isEmpty ?? true) ? nil : trimmed
        )

        return try await client
            .rpc("recommend_place", params: params)
            .execute()
            .value
    }

    // MARK: - Inbox

    static func inboxRecommendations() async throws -> [InboxRecommendation] {
        return try await client
            .rpc("inbox_recommendations")
            .execute()
            .value
    }

    /// Mark items read. Server sets `read_at` from its own clock — a device
    /// clock produces "read before it was sent" orderings that surface much
    /// later as an inexplicable sort.
    ///
    /// Only affects rows still unread, so re-reading doesn't keep bumping the
    /// timestamp.
    @discardableResult
    static func markRead(_ ids: [UUID]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try await client
            .rpc("mark_recommendations_read", params: ["p_ids": ids.map(\.uuidString)])
            .execute()
            .value
    }

    /// Dismiss: hide from the inbox, keep the row.
    ///
    /// A plain PostgREST update on purpose — it exercises the narrow
    /// `grant update (status, read_at)` from 0600_rls.sql, which is the only
    /// thing stopping a recipient from editing the sender's message. The row
    /// survives so the unique constraint keeps working as an anti-spam guard and
    /// the wishlist item keeps its provenance.
    static func dismiss(_ id: UUID) async throws {
        try await client
            .from("recommendations")
            .update(["status": "dismissed"])
            .eq("id", value: id.uuidString)
            .execute()
    }

    // MARK: - Wishlist

    static func wishlistEntries(includeResolved: Bool = true) async throws -> [WishlistEntry] {
        try await client
            .rpc("wishlist_entries", params: ["p_include_resolved": includeResolved])
            .execute()
            .value
    }

    /// Manual add from a place sheet. Returns the wishlist row id.
    ///
    /// Goes through `wishlist_add` so the conflict case is DO NOTHING. A
    /// client-side upsert would UPDATE the existing row instead, rewriting
    /// `source` to 'manual' and blanking the recommendation that put it there —
    /// so tapping Save on a place a friend already sent you would quietly erase
    /// their name from it.
    @discardableResult
    static func addToWishlist(placeID: UUID) async throws -> UUID? {
        try await client
            .rpc("wishlist_add", params: ["p_place": placeID.uuidString])
            .execute()
            .value
    }

    static func removeFromWishlist(itemID: UUID) async throws {
        try await client
            .from("wishlist_items")
            .delete()
            .eq("id", value: itemID.uuidString)
            .execute()
    }

    // MARK: - Feed

    /// One page of friend activity, newest first.
    ///
    /// Keyset pagination: pass the last item's `(visitedAt, id)` to get the next
    /// page. Not offset — friends create visits while the user scrolls, and an
    /// insert above the window makes offset pagination repeat rows and skip
    /// others.
    static func feed(
        after cursor: FeedCursor?,
        limit: Int = 20
    ) async throws -> [FeedItem] {
        let params = FriendFeedParams(
            cursorVisitedAt: cursor?.visitedAt,
            cursorID: cursor?.id,
            limit: limit
        )

        return try await client
            .rpc("friend_feed", params: params)
            .execute()
            .value
    }

    // MARK: - Social stats

    static func placeSocial(placeID: UUID) async throws -> PlaceSocial? {
        let rows: [PlaceSocial] = try await client
            .rpc("place_social", params: ["p_place": placeID.uuidString])
            .execute()
            .value
        return rows.first
    }

    static func friendOverlap(with userID: UUID) async throws -> FriendOverlap? {
        let rows: [FriendOverlap] = try await client
            .rpc("friend_overlap", params: ["p_user": userID.uuidString])
            .execute()
            .value
        return rows.first
    }

    static func ownSocialStats(gapLimit: Int = 10) async throws -> OwnSocialStats? {
        let rows: [OwnSocialStats] = try await client
            .rpc("own_social_stats", params: ["p_gap_limit": gapLimit])
            .execute()
            .value
        return rows.first
    }
}

/// Position in the feed. Composite because several visits can share a
/// `visited_at` — two places logged the same evening is routine — and a
/// timestamp-only cursor would silently drop one of them at a page boundary.
struct FeedCursor: Equatable, Sendable {
    var visitedAt: Date
    var id: UUID

    init(visitedAt: Date, id: UUID) {
        self.visitedAt = visitedAt
        self.id = id
    }

    init(_ item: FeedItem) {
        self.init(visitedAt: item.visit.visitedAt, id: item.visit.visitID)
    }
}

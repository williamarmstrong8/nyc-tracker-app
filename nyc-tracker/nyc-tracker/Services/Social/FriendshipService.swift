import Foundation
import Supabase

/// Every network call the friend graph makes.
///
/// Stateless on purpose — `SocialGraph` owns the observable state, this owns the
/// wire format. The split is the same one `ProfileService` / `AuthManager` uses,
/// and it keeps the retry/refresh policy in one place (the store) rather than
/// scattered through call sites.
///
/// ## Why the mutations return `Void`
///
/// Send / accept / decline / cancel / unfriend all return nothing, and the store
/// refetches `friendship_edges()` afterwards. That is one extra round trip on a
/// deliberate user action, and it buys correctness in the case that matters
/// most: `send_friend_request` can come back as *accepted* rather than *pending*
/// when two people requested each other simultaneously. Optimistically painting
/// "Requested" and trusting it would show the wrong state exactly when the
/// interesting thing happened.
enum FriendshipService {

    private static var client: SupabaseClient { SupabaseManager.client }

    // MARK: - Errors

    enum SocialError: LocalizedError {
        /// An accept that matched zero rows. Almost always means the caller is
        /// the requester (RLS refuses), or the row was already resolved on
        /// another device.
        case acceptNotPermitted
        /// The profile is gone — `friend_profile` returned no rows.
        case profileNotFound

        var errorDescription: String? {
            switch self {
            case .acceptNotPermitted:
                "That request can't be accepted. It may have already been handled."
            case .profileNotFound:
                "This account no longer exists."
            }
        }
    }

    // MARK: - Search

    /// Search by username or display name. Prefix matches rank above substring
    /// matches, and each row carries the caller's relationship to that person, so
    /// the list needs no follow-up query per row.
    static func search(_ query: String, limit: Int = 25) async throws -> [ProfileSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The SQL already returns nothing for a blank term; short-circuiting here
        // saves the round trip on every keystroke that clears the field.
        guard !trimmed.isEmpty else { return [] }

        return try await client
            .rpc("search_profiles", params: SearchProfilesParams(query: trimmed, limit: limit))
            .execute()
            .value
    }

    /// Friends-of-friends the caller isn't already connected to, ranked by
    /// shared friend count. Empty means there's genuinely nothing to
    /// recommend, not a loading state — the server excludes zero-mutual
    /// candidates rather than padding the list with strangers.
    static func recommendedFriends(limit: Int = 10) async throws -> [RecommendedFriend] {
        return try await client
            .rpc("recommended_friends", params: ["p_limit": limit])
            .execute()
            .value
    }

    // MARK: - Graph reads

    /// Every pending or accepted friendship the caller is party to.
    ///
    /// One call backs the friends list, both request queues, and the badge.
    static func edges() async throws -> [FriendshipEdge] {
        return try await client
            .rpc("friendship_edges")
            .execute()
            .value
    }

    /// Public profile header + stats. `nil` means the account is gone, which is
    /// what a viewer sees when someone deletes their account mid-session.
    static func profile(of userID: UUID) async throws -> FriendProfileSummary? {
        let rows: [FriendProfileSummary] = try await client
            .rpc("friend_profile", params: ["p_user": userID.uuidString])
            .execute()
            .value
        return rows.first
    }

    /// Accepted-friend count for a public profile. Accepted rows are world-readable,
    /// so this is the same number anyone else would see — not "friends in common".
    static func acceptedFriendCount(of userID: UUID) async throws -> Int {
        async let asRequester: [FriendshipIDRow] = client
            .from("friendships")
            .select("id")
            .eq("status", value: "accepted")
            .eq("requester_id", value: userID.uuidString)
            .execute()
            .value
        async let asAddressee: [FriendshipIDRow] = client
            .from("friendships")
            .select("id")
            .eq("status", value: "accepted")
            .eq("addressee_id", value: userID.uuidString)
            .execute()
            .value

        let requester = try await asRequester
        let addressee = try await asAddressee
        return requester.count + addressee.count
    }

    private struct FriendshipIDRow: Decodable, Sendable {
        let id: UUID
    }

    /// One person's visits, newest first.
    ///
    /// Goes through `user_visits` rather than a PostgREST embed so the soft-delete
    /// filter runs server-side and the rows decode into the same `FriendVisit`
    /// type the map and place sheet already use.
    static func visits(of userID: UUID, limit: Int = 100) async throws -> [FriendVisit] {
        return try await client
            .rpc("user_visits", params: UserVisitsParams(user: userID, limit: limit))
            .execute()
            .value
    }

    // MARK: - Map

    /// Visits inside a lat/lng box for a set of users.
    ///
    /// Pass `nil` for `userIDs` to mean "me and my friends" — the server resolves
    /// it with `friend_ids()`, so the client never sends back a friend list it
    /// just fetched.
    static func visitsInBounds(
        minLat: Double,
        maxLat: Double,
        minLng: Double,
        maxLng: Double,
        userIDs: [UUID]?,
        limit: Int
    ) async throws -> [FriendVisit] {
        let params = VisitsInBoundsParams(
            minLat: minLat,
            maxLat: maxLat,
            minLng: minLng,
            maxLng: maxLng,
            userIDs: userIDs,
            resultLimit: limit
        )

        return try await client
            .rpc("visits_in_bounds", params: params)
            .execute()
            .value
    }

    // MARK: - Mutations

    /// Send a friend request.
    ///
    /// Delegates the simultaneous-request collision to Postgres: if the addressee
    /// already has a pending request out to the caller, the function promotes it
    /// to accepted instead of failing on the pair index. The caller cannot tell
    /// the difference from here, which is the point — refetching the edges is what
    /// reveals the outcome.
    static func sendRequest(to userID: UUID) async throws {
        try await client
            .rpc("send_friend_request", params: ["p_addressee": userID.uuidString])
            .execute()
    }

    /// Accept an incoming request.
    ///
    /// Deliberately a plain UPDATE rather than an RPC, so the write goes through
    /// `friendships_accept_by_addressee` and exercises the policy directly. The
    /// extra `status = pending` filter is not redundant with the policy's USING
    /// clause — it makes a row that was resolved on another device return zero
    /// rows instead of silently re-accepting.
    ///
    /// `.select()` is what makes a refusal observable: without it PostgREST
    /// reports a zero-row UPDATE as success, and an accept blocked by RLS would
    /// look like it worked.
    static func accept(friendshipID: UUID) async throws {
        let updated: [Friendship] = try await client
            .from("friendships")
            .update(["status": "accepted"])
            .eq("id", value: friendshipID.uuidString)
            .eq("status", value: "pending")
            .select()
            .execute()
            .value

        guard !updated.isEmpty else { throw SocialError.acceptNotPermitted }
    }

    /// Decline an incoming request, cancel one you sent, or unfriend.
    ///
    /// All three are the same DELETE on a mutual graph, and `friendships_delete_by_party`
    /// permits it from either side at any status. Declining deletes rather than
    /// tombstoning — see the note at the foot of 20260816000200_social_graph.sql
    /// for why, and what would change if harassment became a concern.
    static func remove(friendshipID: UUID) async throws {
        try await client
            .from("friendships")
            .delete()
            .eq("id", value: friendshipID.uuidString)
            .execute()
    }
}

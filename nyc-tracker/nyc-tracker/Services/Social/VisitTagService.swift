import Foundation
import Supabase

/// Reads and writes for `visit_tags` — the people an author says were with them.
///
/// Separate from `FriendshipService` because it is not part of the friend graph:
/// it only *depends* on it. Who may be tagged is decided by the insert policy in
/// `20260818000100_visit_tags.sql` (accepted friends of the visit's author, and
/// never the author themselves), so nothing in this file re-checks it. A client
/// that thinks it can tag someone it cannot gets a 403, which is the correct
/// answer and the only one that survives a stale friend list.
enum VisitTagService {

    private static var client: SupabaseClient { SupabaseManager.client }

    /// Replace the tag set on one visit with exactly `userIDs`, in that order.
    ///
    /// Clear then write, rather than diffing: a tag row has no identity beyond
    /// its pair, the sets are single digits, and a diff would have to read the
    /// current rows first — one extra round trip to save nothing. The order the
    /// author picked rides along in `sort_order` rather than being inferred from
    /// insert time, so re-sending an unchanged set is genuinely idempotent.
    ///
    /// Called from the sync engine *after* the visit row is upserted. The insert
    /// policy is an `exists` against `visits`, so tagging a visit the server has
    /// never seen fails.
    static func replaceTags(on visitID: UUID, with userIDs: [UUID]) async throws {
        // Deduplicate, keeping the author's order. The composite primary key
        // would reject a repeat anyway — but as a 409 that fails the whole
        // statement rather than as a no-op.
        var seen = Set<UUID>()
        let unique = userIDs.filter { seen.insert($0).inserted }

        try await client
            .from("visit_tags")
            .delete()
            .eq("visit_id", value: visitID.uuidString)
            .execute()

        guard !unique.isEmpty else { return }

        let rows = unique.enumerated().map { index, userID in
            VisitTagUpsert(visitID: visitID, userID: userID, sortOrder: index)
        }
        // Upsert rather than insert so a retry that lands after a partially
        // applied attempt converges instead of colliding on the primary key.
        try await client
            .from("visit_tags")
            .upsert(rows, onConflict: "visit_id,user_id")
            .execute()
    }

    /// Visits somebody else logged in which `userID` was tagged, newest first.
    ///
    /// Same row shape as `user_visits`, so the profile's two tabs decode into
    /// one type and open the same write-up sheet.
    static func taggedVisits(of userID: UUID, limit: Int = 100) async throws -> [FriendVisit] {
        return try await client
            .rpc("tagged_visits", params: UserVisitsParams(user: userID, limit: limit))
            .execute()
            .value
    }

    /// Remove your own tag from someone else's visit.
    ///
    /// Permitted by the delete policy for the tagged person as well as the
    /// author — being named in someone else's entry is the one thing that
    /// reaches your profile without you writing it, so the exit belongs to you.
    static func untagSelf(from visitID: UUID, userID: UUID) async throws {
        try await client
            .from("visit_tags")
            .delete()
            .eq("visit_id", value: visitID.uuidString)
            .eq("user_id", value: userID.uuidString)
            .execute()
    }
}

/// Insert payload for `visit_tags`. `created_at` is defaulted server-side.
private struct VisitTagUpsert: Encodable, Sendable {
    var visitID: UUID
    var userID: UUID
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case visitID   = "visit_id"
        case userID    = "user_id"
        case sortOrder = "sort_order"
    }
}

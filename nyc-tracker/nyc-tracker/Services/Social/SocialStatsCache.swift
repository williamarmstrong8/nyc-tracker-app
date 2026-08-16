import Foundation
import Observation

/// Short-TTL cache for the server-side social aggregates.
///
/// These numbers — "3 friends have been here", places in common, the gap list —
/// cannot come from the local mirror, which only holds the signed-in user's own
/// rows. They also aren't worth a round trip on every render: a place sheet
/// opened, dismissed and reopened would ask three times for a count that changes
/// when a friend logs a visit, which is not a per-second event.
///
/// A minute of staleness is invisible to the user and removes most of the
/// traffic. Anything the user themselves changes — saving to their wishlist,
/// logging a visit — invalidates explicitly rather than waiting out the TTL,
/// because a stat that ignores your own action reads as broken in a way that a
/// slightly old friend count never does.
@Observable
final class SocialStatsCache {

    /// Long enough to collapse a burst of sheet opens, short enough that a
    /// friend's new visit shows up while the user is still browsing.
    private let ttl: TimeInterval = 60

    private struct Entry<Value> {
        var value: Value
        var fetchedAt: Date
    }

    private var places: [UUID: Entry<PlaceSocial>] = [:]
    private var overlaps: [UUID: Entry<FriendOverlap>] = [:]
    private var own: Entry<OwnSocialStats>?

    /// In-flight requests, so two views opening at once share one round trip
    /// instead of racing to fill the same cache slot.
    private var placeTasks: [UUID: Task<PlaceSocial?, Never>] = [:]
    private var overlapTasks: [UUID: Task<FriendOverlap?, Never>] = [:]
    private var ownTask: Task<OwnSocialStats?, Never>?

    init() {}

    private func isFresh(_ date: Date) -> Bool {
        Date().timeIntervalSince(date) < ttl
    }

    // MARK: - Place

    /// Cached value without fetching, so a view body can render immediately and
    /// fill in when the request lands.
    func cachedPlaceSocial(_ placeID: UUID) -> PlaceSocial? {
        guard let entry = places[placeID], isFresh(entry.fetchedAt) else { return nil }
        return entry.value
    }

    func placeSocial(_ placeID: UUID) async -> PlaceSocial? {
        if let cached = cachedPlaceSocial(placeID) { return cached }
        if let existing = placeTasks[placeID] { return await existing.value }

        let task = Task { [weak self] () -> PlaceSocial? in
            defer { self?.placeTasks[placeID] = nil }
            guard let value = try? await RecommendationService.placeSocial(placeID: placeID) else {
                return nil
            }
            self?.places[placeID] = Entry(value: value, fetchedAt: Date())
            return value
        }

        placeTasks[placeID] = task
        return await task.value
    }

    // MARK: - Friend overlap

    func cachedOverlap(with userID: UUID) -> FriendOverlap? {
        guard let entry = overlaps[userID], isFresh(entry.fetchedAt) else { return nil }
        return entry.value
    }

    func overlap(with userID: UUID) async -> FriendOverlap? {
        if let cached = cachedOverlap(with: userID) { return cached }
        if let existing = overlapTasks[userID] { return await existing.value }

        let task = Task { [weak self] () -> FriendOverlap? in
            defer { self?.overlapTasks[userID] = nil }
            guard let value = try? await RecommendationService.friendOverlap(with: userID) else {
                return nil
            }
            self?.overlaps[userID] = Entry(value: value, fetchedAt: Date())
            return value
        }

        overlapTasks[userID] = task
        return await task.value
    }

    // MARK: - Own stats

    func cachedOwnStats() -> OwnSocialStats? {
        guard let own, isFresh(own.fetchedAt) else { return nil }
        return own.value
    }

    func ownStats() async -> OwnSocialStats? {
        if let cached = cachedOwnStats() { return cached }
        if let ownTask { return await ownTask.value }

        let task = Task { [weak self] () -> OwnSocialStats? in
            defer { self?.ownTask = nil }
            guard let value = try? await RecommendationService.ownSocialStats() else { return nil }
            self?.own = Entry(value: value, fetchedAt: Date())
            return value
        }

        ownTask = task
        return await task.value
    }

    // MARK: - Invalidation

    /// After the user changes something about this place themselves — saving it,
    /// removing it, logging a visit. Their own action must be reflected at once;
    /// a friend's does not have to be.
    func invalidate(placeID: UUID) {
        places[placeID] = nil
        placeTasks[placeID]?.cancel()
        placeTasks[placeID] = nil
        // The gap list is "places friends went that I haven't", so a visit of
        // the user's own changes it too.
        own = nil
    }

    /// After a friendship changes. Every aggregate here is scoped to the friend
    /// set, so all of them are now suspect.
    func invalidateAll() {
        places.removeAll()
        overlaps.removeAll()
        own = nil
        for task in placeTasks.values { task.cancel() }
        for task in overlapTasks.values { task.cancel() }
        placeTasks.removeAll()
        overlapTasks.removeAll()
        ownTask?.cancel()
        ownTask = nil
    }

    func teardown() {
        invalidateAll()
    }
}

import Foundation
import Observation

/// Friend visits for the map, held in memory only.
///
/// ## Why this is not SwiftData
///
/// The SwiftData store is the user's own mirror, partitioned by `ownerUserID`,
/// and sign-out deletes exactly that partition. Writing friend visits into it
/// would break both halves of that: the scoping predicate would need a second
/// concept ("mine" vs "someone else's, cached"), and sign-out cleanup would have
/// to decide whether a row belongs to the departing user or is borrowed data
/// about someone else. Friend data is browsable, not owned — it should evaporate
/// when the session ends, and holding it only in memory makes that free rather
/// than a deletion pass that can half-fail.
///
/// Image bytes are the exception, and they already have a home: `PhotoCache`
/// writes them to `Caches/`, which is re-downloadable, never backed up, evicted
/// under pressure, and cleared on sign-out. So there is a modest disk layer for
/// images and none at all for rows, which is the right split — the rows are
/// cheap to refetch and the JPEGs are not.
///
/// ## Coverage rather than keys
///
/// Rather than keying results by bounding box, this keeps one result set plus the
/// rectangle it covers. A pan that stays inside the covered rectangle is served
/// from memory with no request at all; fetches deliberately over-fetch (see
/// `overfetchFraction`) so ordinary panning is mostly free.
///
/// A truncated result never establishes coverage. If the cap was hit, what came
/// back is "the most recent N in that box", not "everything in that box", and
/// treating it as coverage would silently hide pins as the user pans within it.
@Observable
final class FriendVisitCache {

    // MARK: - Observable state

    private(set) var visits: [FriendVisit] = []
    private(set) var isLoading = false

    /// True when the last fetch hit the row cap, so the map can say so instead of
    /// implying it is showing everything.
    private(set) var isTruncated = false

    /// Set when a fetch fails. The offline case is distinguished on purpose —
    /// the user's own map works offline and friend maps cannot, and an empty map
    /// with no explanation reads as a bug rather than a limitation.
    private(set) var failure: Failure?

    enum Failure: Equatable {
        case offline
        case other(String)

        var message: String {
            switch self {
            case .offline:
                "Friends' places need a connection. Your own map still works offline."
            case .other(let message):
                message
            }
        }
    }

    // MARK: - Tuning

    /// Debounce for map region changes. A naive `onChange` fires on every pan
    /// frame; at 350ms a flick-and-release produces one request, and a slow
    /// deliberate pan produces a handful rather than dozens.
    private let debounce: Duration = .milliseconds(350)

    /// Over-fetch margin. Fetching 40% wider than the visible map on each axis
    /// means small pans and pinches are answered from memory.
    private let overfetchFraction: Double = 0.4

    /// Row cap per fetch. Ordered by `visited_at desc` server-side, so a
    /// zoomed-out view returns the most recent rather than an arbitrary slice.
    private let resultLimit = 300

    // MARK: - Private

    private var coveredBounds: GeoBounds?
    private var coveredAudience: MapAudience?
    private var loadTask: Task<Void, Never>?

    /// Monotonic id for the fetch currently allowed to write state.
    ///
    /// Without it, a superseded fetch's cleanup lands after its replacement has
    /// already started: task A is cancelled, A's `isLoading = false` runs when it
    /// unwinds, and by then B has set `isLoading = true`. The spinner blinks off
    /// while a request is genuinely in flight. Every write below is gated on
    /// still being the newest fetch.
    private var currentFetchID = 0

    init() {}

    // MARK: - Loading

    /// Ask for the visits covering `bounds` under `audience`.
    ///
    /// Safe to call on every camera change: it debounces, it no-ops when the
    /// request is already covered, and it supersedes any in-flight fetch.
    func request(bounds: GeoBounds, audience: MapAudience) {
        guard audience.requiresNetwork else {
            // `.mine` is served entirely from SwiftData. Drop any friend rows so
            // switching back to "mine" cannot leave someone else's pins behind.
            clearResults()
            return
        }

        if isCovered(bounds: bounds, audience: audience) { return }

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            // The debounce lives inside the task so cancellation from the next
            // pan lands during the sleep, before any request is made.
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            await self.fetch(bounds: bounds, audience: audience)
        }
    }

    /// Force a refetch of the current view, ignoring coverage. For pull-to-refresh
    /// and for the retry button on the offline notice.
    func reload(bounds: GeoBounds, audience: MapAudience) async {
        guard audience.requiresNetwork else {
            clearResults()
            return
        }
        loadTask?.cancel()
        invalidateCoverage()
        await fetch(bounds: bounds, audience: audience)
    }

    private func isCovered(bounds: GeoBounds, audience: MapAudience) -> Bool {
        guard
            let coveredAudience,
            let coveredBounds,
            coveredAudience == audience,
            !isTruncated
        else { return false }
        return coveredBounds.contains(bounds)
    }

    private func fetch(bounds: GeoBounds, audience: MapAudience) async {
        // Fail fast and specifically rather than waiting out a URLSession
        // timeout to produce a vaguer message.
        guard NetworkMonitor.shared.isReachable else {
            failure = .offline
            isLoading = false
            return
        }

        let target = bounds.expanded(by: overfetchFraction)

        currentFetchID += 1
        let fetchID = currentFetchID
        isLoading = true
        defer { if fetchID == currentFetchID { isLoading = false } }

        do {
            let rows = try await FriendshipService.visitsInBounds(
                minLat: target.minLat,
                maxLat: target.maxLat,
                minLng: target.minLng,
                maxLng: target.maxLng,
                userIDs: audience.remoteUserIDs(),
                limit: resultLimit
            )

            guard fetchID == currentFetchID, !Task.isCancelled else { return }

            visits = rows
            failure = nil
            // Exactly `resultLimit` rows almost certainly means there were more.
            // Treating the boundary case (exactly N and no more) as truncated
            // costs one redundant fetch; the reverse would hide pins.
            isTruncated = rows.count >= resultLimit
            coveredBounds = isTruncated ? nil : target
            coveredAudience = isTruncated ? nil : audience
        } catch {
            guard fetchID == currentFetchID, !Task.isCancelled else { return }
            invalidateCoverage()
            failure = NetworkMonitor.shared.isReachable
                ? .other(SupabaseErrorPresenter.presentable(error, context: .general).message)
                : .offline
        }
    }

    // MARK: - Invalidation

    /// Throw away coverage but keep the rows on screen.
    ///
    /// Used when the underlying data may have changed but the pins are still the
    /// best thing to show until a refetch lands.
    func invalidateCoverage() {
        coveredBounds = nil
        coveredAudience = nil
        isTruncated = false
    }

    /// Throw away the rows too. Used when the audience stops being valid at all —
    /// switching to `.mine`, or unfriending the person being viewed.
    func clearResults() {
        loadTask?.cancel()
        loadTask = nil
        // Bumping the fetch id is what stops an in-flight request from
        // repopulating the map after the reason for clearing it (an unfriend, a
        // switch back to "mine") has already happened.
        currentFetchID += 1
        visits = []
        failure = nil
        isLoading = false
        invalidateCoverage()
    }

    /// Sign-out. Everything here is in memory, so this is the whole cleanup —
    /// image bytes are `PhotoCache`'s to clear, and `RootView` already does that.
    func teardown() {
        clearResults()
    }
}

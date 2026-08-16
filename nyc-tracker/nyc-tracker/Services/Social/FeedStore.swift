import Foundation
import Observation

/// The explore feed: friends' visits, newest first.
///
/// ## Chronological, deliberately
///
/// No ranking. There is no signal to rank on yet — no dwell time, no taps, no
/// engagement history — so any "algorithm" would be a hand-tuned weighting of
/// recency and friend count dressed up as relevance. Chronological is legible:
/// the user can tell what they are looking at and why it is in that order, and
/// they notice when something is missing. A ranked feed with no data behind it
/// is just a shuffled one.
///
/// ## Keyset pagination
///
/// Pages are requested "after this exact (visitedAt, id)", never "skip N".
/// Friends create visits while the user scrolls; with OFFSET, one insert above
/// the window shifts everything down and page 2 repeats page 1's last row while
/// dropping another. Keyset is stable under insertion — a row added above the
/// cursor simply isn't in the next page, and pull-to-refresh is how you get it.
@Observable
final class FeedStore {

    // MARK: - Observable state

    private(set) var items: [FeedItem] = []
    /// First load or pull-to-refresh.
    private(set) var isRefreshing = false
    /// Fetching the next page.
    private(set) var isLoadingMore = false
    private(set) var hasLoaded = false
    /// False once a page comes back short — there is nothing further back.
    private(set) var canLoadMore = true

    var lastError: PresentableError?

    // MARK: - Tuning

    private let pageSize = 20

    /// How close to the end triggers the next page. Three rows of lead time
    /// means the page is usually already there by the time the user reaches it.
    private let prefetchThreshold = 3

    // MARK: - Private

    private var userID: UUID?
    private var cursor: FeedCursor?
    private var loadTask: Task<Void, Never>?

    /// Guards against the same visit appearing twice.
    ///
    /// Keyset pagination shouldn't produce duplicates, but "shouldn't" is doing
    /// a lot of work across a clock skew or a page boundary landing on identical
    /// timestamps, and a duplicated `id` in a `ForEach` is a runtime warning and
    /// a visibly broken list. Cheap insurance.
    private var seenIDs: Set<UUID> = []

    init() {}

    // MARK: - Lifecycle

    func configure(userID: UUID) {
        guard self.userID != userID else { return }
        self.userID = userID
        resetState()
        refresh()
    }

    func teardown() {
        loadTask?.cancel()
        loadTask = nil
        userID = nil
        resetState()
    }

    private func resetState() {
        items = []
        seenIDs = []
        cursor = nil
        canLoadMore = true
        hasLoaded = false
        isRefreshing = false
        isLoadingMore = false
        lastError = nil
    }

    // MARK: - Loading

    func refresh() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.reload()
        }
    }

    /// Pull-to-refresh: throw away the cursor and start again from the top.
    ///
    /// Not "fetch newer than the newest I have" — that leaves a hole if the user
    /// was away long enough for more than a page of activity to accumulate, and
    /// the hole is invisible because the feed above and below it both look
    /// normal. Starting over costs one page.
    func reload() async {
        guard userID != nil else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let page = try await RecommendationService.feed(after: nil, limit: pageSize)
            guard !Task.isCancelled else { return }

            items = page
            seenIDs = Set(page.map(\.id))
            cursor = page.last.map(FeedCursor.init)
            canLoadMore = page.count == pageSize
            hasLoaded = true
            lastError = nil
        } catch {
            guard !Task.isCancelled else { return }
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
        }
    }

    /// Called as rows appear. Decides for itself whether a page is due, so the
    /// view can call it on every row without tracking indices.
    func loadMoreIfNeeded(currentItem item: FeedItem) {
        guard canLoadMore, !isLoadingMore, !isRefreshing else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard index >= items.count - prefetchThreshold else { return }

        Task { await loadMore() }
    }

    func loadMore() async {
        guard canLoadMore, !isLoadingMore, !isRefreshing, let cursor else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await RecommendationService.feed(after: cursor, limit: pageSize)
            guard !Task.isCancelled else { return }

            // A short page means we reached the end. Checked against the request
            // size before dedupe, because dedupe can shorten a full page and
            // would otherwise end the feed early.
            canLoadMore = page.count == pageSize

            let fresh = page.filter { seenIDs.insert($0.id).inserted }
            items.append(contentsOf: fresh)

            // Advance from the last row the SERVER returned, not the last one we
            // kept. If everything in a page was a duplicate, moving the cursor to
            // the last kept item would leave it where it was and the next request
            // would ask for the same page forever.
            if let last = page.last {
                self.cursor = FeedCursor(last)
            } else {
                canLoadMore = false
            }
            lastError = nil
        } catch {
            guard !Task.isCancelled else { return }
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
        }
    }
}

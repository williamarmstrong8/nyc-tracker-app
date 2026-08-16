import Foundation
import Observation

/// The user's wishlist: places they mean to go, however they got there.
///
/// ## Why this isn't in SwiftData
///
/// It is the user's own data, so the local store would be a legitimate home —
/// but a wishlist item is a *pointer*, not authorship. Its two properties are
/// that it can appear while the app is closed (a friend sends you somewhere) and
/// that it carries no content the user typed. Mirroring it would buy offline
/// access to a list of names while costing a second sync loop, a second conflict
/// policy, and a second sign-out cleanup path. A want-to-try entry the user
/// actually wrote — with photos and a voice note — is a `Visit` with
/// `kind == .wantToTry` and does live in SwiftData. Those two things share a
/// word and nothing else.
@Observable
final class WishlistStore {

    // MARK: - Observable state

    private(set) var entries: [WishlistEntry] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    var lastError: PresentableError?

    /// Whether wishlist pins are drawn on the map. Persisted per user.
    private(set) var showsOnMap = false

    // MARK: - Private

    private var userID: UUID?
    private var refreshTask: Task<Void, Never>?

    private static let mapLayerKeyPrefix = "nyc-tracker.wishlistOnMap.v1."

    init() {}

    // MARK: - Derived

    /// Places still to go. The list that matters.
    var active: [WishlistEntry] { entries.filter { !$0.isResolved } }

    /// Places they wanted to go and went. Kept visible rather than deleted —
    /// "someone recommended it, I went" is the entire arc of the feature, and an
    /// item that silently vanishes on arrival never shows the user it worked.
    var resolved: [WishlistEntry] { entries.filter(\.isResolved) }

    func entry(forPlace placeID: UUID) -> WishlistEntry? {
        entries.first { $0.place.id == placeID }
    }

    func contains(placeID: UUID) -> Bool {
        entry(forPlace: placeID) != nil
    }

    // MARK: - Lifecycle

    func configure(userID: UUID) {
        guard self.userID != userID else { return }
        self.userID = userID
        entries = []
        hasLoaded = false
        showsOnMap = UserDefaults.standard.bool(
            forKey: Self.mapLayerKeyPrefix + userID.uuidString
        )
        refresh()
    }

    func teardown() {
        refreshTask?.cancel()
        refreshTask = nil
        userID = nil
        entries = []
        hasLoaded = false
        isLoading = false
        lastError = nil
        showsOnMap = false
    }

    // MARK: - Map layer

    func setShowsOnMap(_ shows: Bool) {
        guard showsOnMap != shows else { return }
        showsOnMap = shows
        guard let userID else { return }
        UserDefaults.standard.set(shows, forKey: Self.mapLayerKeyPrefix + userID.uuidString)
    }

    // MARK: - Loading

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.reload()
        }
    }

    func reload() async {
        guard userID != nil else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let loaded = try await RecommendationService.wishlistEntries()
            guard !Task.isCancelled else { return }
            entries = loaded
            hasLoaded = true
        } catch {
            guard !Task.isCancelled else { return }
            // Keep what's on screen. A network blip shouldn't empty the list.
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
        }
    }

    // MARK: - Mutations

    /// Save a place. Idempotent — the RPC's ON CONFLICT DO NOTHING means saving
    /// something already saved leaves the original row, and its provenance,
    /// alone.
    @discardableResult
    func add(placeID: UUID) async -> Bool {
        do {
            _ = try await RecommendationService.addToWishlist(placeID: placeID)
            await reload()
            return true
        } catch {
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
            return false
        }
    }

    @discardableResult
    func remove(itemID: UUID) async -> Bool {
        let previous = entries
        entries.removeAll { $0.id == itemID }

        do {
            try await RecommendationService.removeFromWishlist(itemID: itemID)
            return true
        } catch {
            entries = previous
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
            return false
        }
    }

    /// Remove by place, for call sites that only know the venue.
    @discardableResult
    func remove(placeID: UUID) async -> Bool {
        guard let entry = entry(forPlace: placeID) else { return false }
        return await remove(itemID: entry.id)
    }
}

import SwiftUI
import Observation

/// Which top-level page is showing, and in which mode.
///
/// Lifted out of `ContentView`'s local state for one reason: "View on map" on a
/// friend's profile has to change the tab from several levels down a navigation
/// stack, sometimes from inside a sheet. Threading two bindings through every
/// intermediate view to do it would touch a dozen initialisers; an observable in
/// the environment touches one.
///
/// Scoped to `ContentView`'s subtree rather than the app, so it is recreated
/// when the signed-in user changes and cannot carry one account's navigation
/// into the next.
@Observable
final class AppRouter {
    var activeTab: AppTab = .home
    var homeMode: HomeMode = .map
    /// A conversation is a full-screen thread. The floating dock would sit on
    /// the composer and steal the bottom of the screen, so chat turns it off.
    var hidesBottomBar = false

    /// Wired once from `ContentView`, which owns both. `weak` because
    /// `AppRouter` doesn't own their lifetime — it just needs to reach them
    /// at the moment of a "view on map" jump, from views (chat, discover, a
    /// friend's profile) that were never handed the filter directly.
    private weak var filter: EntryFilter?
    private weak var mapAudience: MapAudienceStore?

    func configure(filter: EntryFilter, mapAudience: MapAudienceStore) {
        self.filter = filter
        self.mapAudience = mapAudience
    }

    /// Jump to the map. Used after picking a friend to view, or from any
    /// "View on map" action.
    ///
    /// Always clears the category/tag/kind filter first: it was set (or left
    /// over) in whatever screen the tap came from, and a stale filter can hide
    /// the very pin the caller is trying to show.
    func showMap() {
        filter?.reset()
        activeTab = .home
        homeMode = .map
    }

    /// Same as `showMap()`, but for jumps that originate from one of the
    /// signed-in user's own visits — a want-to-try save, a freshly confirmed
    /// capture, or "View on map" on one's own write-up. Also forces the map
    /// audience back to "my places", since leaving it on a friend or
    /// "all friends" would hide the very pin being shown.
    func showMyMap() {
        mapAudience?.select(.mine)
        showMap()
    }
}

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

    /// Jump to the map. Used after picking a friend to view.
    func showMap() {
        activeTab = .home
        homeMode = .map
    }
}

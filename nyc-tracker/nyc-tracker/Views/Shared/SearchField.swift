import SwiftUI

extension View {
    /// The app's one search field: a nav-bar drawer that is always shown, on a
    /// toolbar background that is already there when the page arrives.
    ///
    /// The "already there" part is the whole point. A plain `.searchable` leaves
    /// the nav bar transparent and lets the scroll edge effect decide what sits
    /// behind the field once content has been laid out and measured. Pinning the
    /// toolbar background to an opaque colour and dropping the top edge effect
    /// takes that decision away: the bar is opaque from the first frame.
    ///
    /// That still isn't enough on a *pushed* page. The search controller is
    /// installed after the navigation transition, so the field's glass fills in
    /// a beat late over whatever was sliding away. Sheets that own their
    /// `NavigationStack` (map search, Add friends) present the field on frame
    /// one, over a matching `.presentationBackground`.
    ///
    /// The colour is `systemBackground` rather than a material: every page
    /// behind a search field paints itself the same colour, and a material
    /// would sample the content and land somewhere else.
    func appSearchable(text: Binding<String>, prompt: String) -> some View {
        self
            .searchable(
                text: text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: prompt
            )
            // Keep the page's own toolbar items visible while the field is
            // focused instead of collapsing the bar down to the field.
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .scrollEdgeEffectHidden(true, for: .top)
            .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
    }
}

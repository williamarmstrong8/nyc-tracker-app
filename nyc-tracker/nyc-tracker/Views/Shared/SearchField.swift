import SwiftUI

/// A search field that lives in the page hierarchy instead of being installed
/// into `UINavigationItem` by `.searchable`.
///
/// Keep this for screens that push another destination. UIKit removes the
/// navigation item's search controller during the push and restores it after
/// the pop transition, which makes its glass surface appear a beat late.
/// Because this field is ordinary SwiftUI content, it transitions with the
/// page and its glass is present on the first returning frame.
struct AppInlineSearchField: View {
    @Binding var text: String
    let prompt: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .onTapGesture {
            isFocused = true
        }
        .accessibilityElement(children: .contain)
    }
}

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

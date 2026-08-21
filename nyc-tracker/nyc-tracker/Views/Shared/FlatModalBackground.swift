import SwiftUI

/// The literal black/white every visit write-up sheet uses instead of
/// `Color(uiColor: .systemBackground)`.
///
/// iOS resolves dynamic system colors against a `UIUserInterfaceLevel` that
/// it bumps to `.elevated` for anything presented modally, which makes
/// `.systemBackground` render as a shade lighter than true black in dark
/// mode — a mismatch that reads as gray next to the rest of the app's flat
/// black/white surfaces. Keying off `colorScheme` directly sidesteps that
/// elevation instead of fighting it.
private struct FlatModalToolbarBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .toolbarBackground(colorScheme == .dark ? Color.black : Color.white, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
    }
}

private struct FlatModalPresentationBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.presentationBackground(colorScheme == .dark ? Color.black : Color.white)
    }
}

private struct FlatModalContentBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(colorScheme == .dark ? Color.black : Color.white)
    }
}

extension View {
    /// Pairs with `.flatModalBackground()` on the sheet's outer
    /// `NavigationStack` — opaque, non-elevated nav bar chrome for content
    /// inside a visit write-up sheet.
    func flatModalToolbarBackground() -> some View {
        modifier(FlatModalToolbarBackground())
    }

    /// Applied to the outer `NavigationStack` passed to `.sheet`, or to
    /// `.sheet`'s own content when it doesn't need one — the flat backdrop
    /// for the sheet itself.
    func flatModalBackground() -> some View {
        modifier(FlatModalPresentationBackground())
    }

    /// Same flat color as `.flatModalBackground()`, as a plain content
    /// fill rather than a presentation backdrop — for sheets that paint
    /// their own `ScrollView` background instead of relying on
    /// `.presentationBackground`.
    func flatModalContentBackground() -> some View {
        modifier(FlatModalContentBackground())
    }
}

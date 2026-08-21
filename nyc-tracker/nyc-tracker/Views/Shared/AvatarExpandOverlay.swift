import SwiftUI

/// Dimmed full-screen layer with a larger avatar. Sits in a root `ZStack` (e.g. on
/// `NavigationStack`) so it covers the page while the thumbnail morphs into place.
///
/// ## Why not `matchedGeometryEffect`
///
/// The obvious tool for a "hero" transition, but it doesn't reconcile reliably
/// here: the thumbnail lives inside a `ScrollView`/`LazyVStack`, and this layer
/// is a `ZStack` sibling that `.ignoresSafeArea()`s past it. That combination
/// left the expand animation springing open from a zero-sized frame pinned to
/// the layer's own top-left corner instead of growing out of the thumbnail —
/// `matchedGeometryEffect` never resolved a sensible anchor across that
/// boundary. Tracking the thumbnail's actual window frame and animating this
/// layer's `.frame`/`.position` explicitly sidesteps that reconciliation
/// entirely: there is only ever one coordinate space in play (`.global`, i.e.
/// the window), and SwiftUI animates frame/position changes on its own once
/// they're inside `withAnimation`.
///
/// ## Why there are two flags, not one
///
/// `isExpanded` alone decides which frame to animate toward, and it has to
/// flip the instant a tap happens in both directions — that's what starts the
/// grow/shrink. But which of {thumbnail, this layer's own avatar} is the
/// opaque one can't just follow `isExpanded` directly, or its opacity change
/// (a continuous property) rides the same `withAnimation` transaction as the
/// frame and crossfades — the exact fade this exists to avoid. Opening can
/// swap instantly, because at that instant the two frames are identical (this
/// layer starts exactly on top of the thumbnail). Closing can't: the overlay
/// has to stay the opaque one, fully covering the thumbnail, for the whole
/// shrink — revealing the thumbnail before the shrink lands back on its exact
/// position would show it sitting there while the (still travelling) big
/// avatar hadn't arrived yet. `isOverlayOpaque` carries that second, delayed
/// signal: instant true on open, false only once the close animation settles.
struct ProfileAvatarExpandLayer<Fallback: View>: View {
    @Binding var isExpanded: Bool
    /// Whether this layer's avatar (rather than the thumbnail underneath) is
    /// the one currently opaque. See the type-level note above.
    @Binding var isOverlayOpaque: Bool
    /// The thumbnail's current frame in the window's coordinate space.
    /// Updated continuously by `profileAvatarExpandSource` (not captured just
    /// once) so a layout change while collapsed doesn't leave the next open
    /// animating from a stale position.
    let sourceFrame: CGRect
    let urlString: String?
    @ViewBuilder var fallback: () -> Fallback

    @State private var containerSize: CGSize = .zero

    var body: some View {
        ZStack {
            // Deliberately no `.animation(value:)` of its own: it needs to move
            // in lockstep with the avatar's frame below, which animates on the
            // ambient `withAnimation(.profileAvatarExpand)` transaction from
            // `dismiss()` / the tap that opens it. Giving this its own faster
            // curve made the backdrop clear out well before the avatar
            // finished shrinking.
            Color.black.opacity(isExpanded ? 0.72 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if isExpanded { dismiss() } }
                .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                    containerSize = newSize
                }

            AvatarImage(urlString: urlString) {
                fallback()
            }
            .frame(width: currentFrame.width, height: currentFrame.height)
            .clipShape(Circle())
            .shadow(color: .black.opacity(isExpanded ? 0.35 : 0), radius: 24, x: 0, y: 8)
            .position(x: currentFrame.midX, y: currentFrame.midY)
            // No `.animation(value:)` either: `isOverlayOpaque` is only ever
            // set outside of `withAnimation`, so it always snaps — the point
            // of keeping it separate from `isExpanded` in the first place.
            .opacity(isOverlayOpaque ? 1 : 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(isExpanded)
        .zIndex(isExpanded ? 1 : 0)
        .accessibilityHidden(!isExpanded)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Profile picture")
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { dismiss() }
    }

    /// Where the avatar is drawn right now: the thumbnail's own frame at
    /// rest, the centred full-size circle once expanded. A plain computed
    /// property rather than stored state — SwiftUI already animates
    /// `.frame`/`.position` smoothly when the values driving them change
    /// inside `withAnimation`, so there is nothing to hand-interpolate.
    private var currentFrame: CGRect {
        isExpanded ? expandedFrame : sourceFrame
    }

    private func dismiss() {
        guard isExpanded else { return }
        Haptics.tap()
        withAnimation(.profileAvatarExpand) {
            isExpanded = false
        } completion: {
            // Guard against a tap that reopened it before the shrink
            // finished settling — in that case `isExpanded` is back to
            // true by the time this fires, and the overlay needs to stay
            // the opaque one.
            if !isExpanded {
                isOverlayOpaque = false
            }
        }
    }

    /// Clamped to zero for the sliver of time before `containerSize` has its
    /// first real measurement, when `min(width, height) - 64` would go
    /// negative — an invalid frame dimension SwiftUI logs a runtime warning
    /// about every time it happens.
    private var expandedFrame: CGRect {
        let size = max(0, min(min(containerSize.width, containerSize.height) - 64, 320))
        return CGRect(
            x: (containerSize.width - size) / 2,
            y: (containerSize.height - size) / 2,
            width: size,
            height: size
        )
    }
}

private struct ProfileAvatarExpandSourceModifier: ViewModifier {
    @Binding var isExpanded: Bool
    @Binding var isOverlayOpaque: Bool
    @Binding var sourceFrame: CGRect

    func body(content: Content) -> some View {
        content
            .opacity(isOverlayOpaque ? 0 : 1)
            .contentShape(Circle())
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { newFrame in
                sourceFrame = newFrame
            }
            .onTapGesture {
                Haptics.tap()
                // Instant, not animated: at this exact moment the overlay's
                // starting frame equals this view's own frame, so the swap
                // to the overlay being the opaque one is invisible.
                isOverlayOpaque = true
                withAnimation(.profileAvatarExpand) {
                    isExpanded = true
                }
            }
            .accessibilityLabel("Profile picture")
            .accessibilityHint("Shows a larger profile picture")
    }
}

extension Animation {
    static let profileAvatarExpand = Animation.spring(response: 0.38, dampingFraction: 0.84)
}

extension View {
    /// Marks a profile-picture thumbnail as the source for `ProfileAvatarExpandLayer`.
    /// `sourceFrame` is written continuously with this view's frame in window
    /// coordinates, which `ProfileAvatarExpandLayer` reads to know where to
    /// grow from and shrink back to. `isOverlayOpaque` is shared with that
    /// same layer so exactly one of the two ever draws the picture.
    func profileAvatarExpandSource(
        isExpanded: Binding<Bool>,
        isOverlayOpaque: Binding<Bool>,
        sourceFrame: Binding<CGRect>
    ) -> some View {
        modifier(ProfileAvatarExpandSourceModifier(
            isExpanded: isExpanded,
            isOverlayOpaque: isOverlayOpaque,
            sourceFrame: sourceFrame
        ))
    }
}

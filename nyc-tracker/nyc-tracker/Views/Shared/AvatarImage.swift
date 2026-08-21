import SwiftUI
import UIKit

/// Someone's profile picture, drawn from `AvatarCache`, with a caller-supplied
/// fallback underneath it.
///
/// ## Why not `AsyncImage`
///
/// `AsyncImage` is backed by `URLSession.shared` and therefore by `URLCache.shared`,
/// which is a small allowance shared with every API call the app makes — so
/// avatars are evicted by ordinary Supabase traffic within minutes. It also
/// holds no decoded image at all: a `List` or `LazyVGrid` rebuilds its rows
/// constantly, and each rebuild restarts the whole phase machine, which is why
/// the old implementation flashed a `ProgressView` over a tinted circle every
/// time a friends list scrolled.
///
/// This draws the cached image synchronously in its first frame, so a face the
/// app has already seen never disappears again for the life of the install.
///
/// ## No spinner, ever
///
/// The fallback is initials on the person's palette colour (or the app logo on
/// the user's own profile) — a complete, legible avatar in its own right, not a
/// placeholder. Showing a spinner in front of something already worth looking at
/// buys nothing and costs a flicker. A first-ever network fetch still fades the
/// photo in; a cache hit (memory or disk) paints immediately with no animation,
/// which is what stops navigation from flashing initials over faces the app
/// already has on disk.
struct AvatarImage<Fallback: View>: View {

    let urlString: String?

    @ViewBuilder var fallback: Fallback

    @State private var image: UIImage?
    /// Which URL `image` came from.
    ///
    /// Needed because an avatar URL changes when the person uploads a new
    /// picture, and the correct behaviour then is to keep drawing the old one
    /// until the new one has loaded rather than dropping back to initials for a
    /// round trip. A plain `image == nil` check could not tell "nothing loaded"
    /// from "an older version loaded".
    @State private var loadedURL: String?

    init(urlString: String?, @ViewBuilder fallback: () -> Fallback) {
        self.urlString = urlString
        self.fallback = fallback()
        let cached = urlString.flatMap { AvatarCache.shared.cachedImage(for: $0) }
        _image = State(initialValue: cached)
        _loadedURL = State(initialValue: cached == nil ? nil : urlString)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .task(id: urlString) {
            await load()
        }
    }

    private func load() async {
        guard let urlString else {
            // The person removed their avatar. Drop to the fallback rather than
            // leaving a stale face behind.
            image = nil
            loadedURL = nil
            return
        }

        guard loadedURL != urlString else { return }

        // Sync path (pin / NSCache / disk). No animation — the face was already
        // local, and fading it in is exactly the flicker navigation produces.
        if let cached = AvatarCache.shared.cachedImage(for: urlString) {
            image = cached
            loadedURL = urlString
            return
        }

        guard let fetched = await AvatarCache.shared.image(for: urlString) else { return }
        // The view may have been handed a different person while this was in
        // flight; `.task(id:)` cancels but the result can still land first.
        guard urlString == self.urlString else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            image = fetched
            loadedURL = urlString
        }
    }
}

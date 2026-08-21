import SwiftUI
import SwiftData

/// The auth gate. Nothing reaches `ContentView` without a session and a username.
///
/// This is a hard gate by design: no guest mode, no "skip for now", no way to
/// dismiss the username screen. Since every table in the backend grants access
/// only to the `authenticated` role, an app without a session literally cannot
/// read or write anything — a guest mode would be a screen full of empty states.
struct RootView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(SyncEngine.self) private var sync
    @Environment(SocialGraph.self) private var social
    @Environment(ChatStore.self) private var chat
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                LaunchSplash()

            case .signedOut:
                AuthView()

            case .needsUsername:
                UsernameSetupView()

            case .signedIn(let profile):
                // `.id(profile.id)` is load-bearing, not a hint. Every scoped
                // `@Query` below builds its predicate in `init`, and SwiftUI will
                // happily reuse a view whose identity hasn't changed — so without
                // this, signing out and in as a different user could keep the
                // previous user's predicate alive and render their visits. The
                // explicit identity forces the whole subtree to be rebuilt.
                ContentView(userID: profile.id)
                    .id(profile.id)
                    .task(id: profile.id) {
                        sync.configure(container: modelContext.container, userID: profile.id)
                    }
            }
        }
        // A session that can't be refreshed mid-sync has to end at the gate.
        // The engine raises the flag; signing out here is what actually closes
        // it, and the queue survives on disk for when they sign back in.
        .onChange(of: sync.needsReauthentication) { _, needsReauth in
            guard needsReauth else { return }
            Task { await auth.signOut() }
        }
        .onChange(of: auth.state.isAuthenticated) { _, isAuthenticated in
            if !isAuthenticated {
                sync.teardown()
                // Social data evaporates on sign-out and leaves no trace. The
                // graph and the recommendations it holds are in memory here; the
                // wishlist, feed, friend-visit and stats caches are `@State` on
                // `ContentView` and die with its subtree when this view swaps
                // away. What social bytes reached the disk went to `Caches/` —
                // photos, avatars, and the launch snapshots — and all three are
                // cleared below. Nothing about another person, and nothing
                // server-only like the wishlist, was ever written to the
                // user-scoped SwiftData store, so there is nothing there to
                // clean up.
                social.teardown()
                // Messages are the one social surface with an open socket, so
                // this teardown does more than drop state: it unsubscribes. A
                // channel left running would keep delivering the previous
                // account's messages into the next one's session.
                chat.teardown()
                // Everything cached to disk goes with the session. `PhotoCache`
                // clears the decoded-image layer as part of its own teardown;
                // avatars and snapshots are separate directories with separate
                // owners, so each is asked directly.
                //
                // These are all `Caches/` — nothing here is user data, only
                // copies of things the server will resend. Signing back in costs
                // one round trip per surface and rebuilds all of it.
                PhotoCache.shared.clear()
                AvatarCache.shared.clear()
                SnapshotStore.shared.clear()
            }
        }
        // Cross-fade rather than a slide: the loading -> signed-in transition
        // happens in a few hundred ms and a push animation reads as a glitch.
        .animation(.easeInOut(duration: 0.25), value: auth.state)
        .alert(
            auth.lastError?.title ?? "Something went wrong",
            isPresented: Binding(
                get: { auth.lastError != nil },
                set: { if !$0 { auth.lastError = nil } }
            ),
            presenting: auth.lastError
        ) { error in
            if error.isRetryable {
                Button("Try again") {
                    auth.lastError = nil
                    Task { await auth.retry() }
                }
            }
            Button("OK", role: .cancel) { auth.lastError = nil }
        } message: { error in
            Text(error.message)
        }
    }
}

/// Shown while the persisted session is being restored.
///
/// Deliberately quiet and quick. The failure mode this avoids is flashing the
/// sign-in screen for a moment before the Keychain session loads — which reads to
/// a returning user as "it logged me out", every single launch.
private struct LaunchSplash: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityHidden(true)

                ProgressView()
                    .controlSize(.small)
            }
        }
        .accessibilityLabel("Loading")
    }
}

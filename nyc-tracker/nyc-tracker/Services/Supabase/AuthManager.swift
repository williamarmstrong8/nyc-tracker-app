import Foundation
import Observation
import SwiftUI
import Supabase
import AuthenticationServices

/// The four states the app can be in with respect to authentication.
///
/// `needsUsername` is a real state, not a flag on `signedIn`: a user with a
/// session but no username has an account but no identity, and must not reach the
/// app. Modelling it as its own case makes that unreachable-by-construction in
/// `RootView` rather than something enforced by a scattering of `if` checks.
enum AuthState: Equatable {
    /// Restoring a persisted session. Transient, usually a few hundred ms.
    case loading
    case signedOut
    /// Authenticated, but `profile.username` is nil.
    case needsUsername
    case signedIn(Profile)

    var profile: Profile? {
        if case .signedIn(let profile) = self { return profile }
        return nil
    }

    var isAuthenticated: Bool {
        switch self {
        case .needsUsername, .signedIn: true
        case .loading, .signedOut:      false
        }
    }
}

/// Owns authentication state for the whole app.
///
/// Created once in `nyc_trackerApp` and injected through the environment. Under
/// this project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, the whole type is
/// main-actor isolated, so state mutations are already on the right actor and no
/// explicit `@MainActor` annotation is needed (adding one would be redundant).
@Observable
final class AuthManager {

    // MARK: - Observable state

    private(set) var state: AuthState = .loading

    /// Set when an operation fails in a way worth showing. Views bind to it for
    /// an alert; the presenter decides the wording and whether Retry is offered.
    var lastError: PresentableError?

    /// True while a sign-in round trip is in flight, so the button can show a
    /// spinner and refuse a second tap.
    private(set) var isSigningIn = false

    /// Apple hands over the user's name exactly once, on first authorization. If
    /// that happens we stash it here so `UsernameSetupView` can prefill the
    /// display-name field even if the profile row hasn't picked it up yet.
    private(set) var pendingAppleDisplayName: String?

    // MARK: - Private

    private var client: SupabaseClient { SupabaseManager.client }
    private var authStateTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Lives for the lifetime of the app (created once in `nyc_trackerApp`), so
    /// the observation task is never torn down. No `deinit` on purpose: cancelling
    /// a main-actor-isolated task from a nonisolated `deinit` is exactly the kind
    /// of thing that breaks under stricter concurrency for no benefit here.
    init() {
        observeAuthChanges()
    }

    /// Subscribes to the SDK's auth event stream and derives `state` from it.
    ///
    /// This is the only writer of `state` for session-level transitions. The
    /// stream fires an `.initialSession` event on subscribe carrying whatever was
    /// restored from the Keychain, which is what resolves the `.loading` state on
    /// launch — no separate "check for a session" call is needed, and using one
    /// would race this stream.
    private func observeAuthChanges() {
        authStateTask = Task { [weak self] in
            guard let self else { return }

            // `authStateChanges` was an async-get property in earlier 2.x
            // releases and is a plain one now — hence no `await` on the
            // property itself, only on the sequence it hands back.
            for await (event, session) in client.auth.authStateChanges {
                if Task.isCancelled { return }

                switch event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    if let session {
                        // Deliberately no `session.isExpired` branch, despite
                        // the SDK's advice for `emitLocalSessionAsInitialSession`.
                        // That advice is aimed at apps that treat "a session
                        // exists" as "signed in" — this one doesn't. Nothing here
                        // enters `.signedIn` until the profile row has actually
                        // been read, and that read goes through
                        // `auth.session.accessToken`, which refreshes an expired
                        // token before the request leaves. So an expired session
                        // resolves exactly like a valid one, one refresh later,
                        // and a dead refresh token fails the read and then
                        // arrives here again as `.signedOut`.
                        await self.resolveProfile(for: session.user.id)
                    } else {
                        // `.initialSession` with a nil session means nothing was
                        // persisted — a genuinely signed-out cold launch.
                        self.state = .signedOut
                    }

                case .signedOut:
                    self.pendingAppleDisplayName = nil
                    self.state = .signedOut

                default:
                    break
                }
            }
        }
    }

    /// Fetches the profile row and decides between `needsUsername` and `signedIn`.
    ///
    /// The row is created by a Postgres trigger on `auth.users`, which commits in
    /// the same transaction as the signup. In practice it is always there by the
    /// time we ask, but a cold start against a slow connection can still race it,
    /// so a missing row is retried rather than treated as an error.
    private func resolveProfile(for userID: UUID, attempt: Int = 0) async {
        do {
            let profile: Profile = try await client
                .from("profiles")
                .select()
                .eq("id", value: userID.uuidString)
                .single()
                .execute()
                .value

            apply(profile)
        } catch {
            // PostgREST returns an error for `.single()` with zero rows. Retry a
            // couple of times before giving up.
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(400))
                await resolveProfile(for: userID, attempt: attempt + 1)
                return
            }

            // We have a valid session but can't read the profile — most likely
            // offline. Land on `needsUsername` rather than `signedOut`: signing
            // the user out would destroy a perfectly good session over a network
            // blip, and the username screen can retry.
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
            state = .needsUsername
        }
    }

    /// Routes a freshly loaded profile to the right state.
    func apply(_ profile: Profile) {
        if let username = profile.username, !username.isEmpty {
            state = .signedIn(profile)
            pendingAppleDisplayName = nil
        } else {
            state = .needsUsername
        }
    }

    /// Re-reads the current user's profile. Call after any profile mutation.
    @discardableResult
    func refreshProfile() async -> Profile? {
        guard let userID = try? await client.auth.session.user.id else { return nil }
        do {
            let profile: Profile = try await client
                .from("profiles")
                .select()
                .eq("id", value: userID.uuidString)
                .single()
                .execute()
                .value
            apply(profile)
            return profile
        } catch {
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
            return nil
        }
    }

    // MARK: - Sign in with Apple

    /// Builds the request Apple's button hands us, and remembers the nonce.
    ///
    /// The returned `AppleNonce` must be carried through to `completeSignIn` —
    /// Apple gets the hash, Supabase gets the raw value.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) -> AppleNonce {
        let nonce = AppleNonce()
        request.requestedScopes = [.fullName, .email]
        request.nonce = nonce.hashed
        return nonce
    }

    /// Exchanges an Apple authorization for a Supabase session.
    ///
    /// On success this returns without touching `state` — the auth event stream
    /// picks up `.signedIn` and drives the transition, so there is exactly one
    /// path into the signed-in state regardless of how it was reached.
    func completeSignIn(with result: Result<ASAuthorization, any Error>, nonce: AppleNonce) async {
        isSigningIn = true
        defer { isSigningIn = false }

        switch result {
        case .failure(let error):
            // Tapping Cancel on the Apple sheet reports as an error. Swallow it —
            // an alert here is the app scolding the user for changing their mind.
            guard !SupabaseErrorPresenter.isCancellation(error) else { return }
            lastError = SupabaseErrorPresenter.presentable(error, context: .signIn)

        case .success(let authorization):
            guard let credential = AppleCredential(authorization: authorization, rawNonce: nonce.raw) else {
                lastError = PresentableError(
                    title: "Couldn't sign in",
                    message: "Apple didn't return a usable identity token. Try again.",
                    isRetryable: true
                )
                return
            }

            // First-authorization-only data. Stash before the network call so it
            // survives even if the sign-in itself has to be retried.
            if let fullName = credential.fullName {
                pendingAppleDisplayName = fullName
            }

            do {
                try await client.auth.signInWithIdToken(
                    credentials: OpenIDConnectCredentials(
                        provider: .apple,
                        idToken: credential.identityToken,
                        // RAW nonce. Apple got the hash; sending the hash here is
                        // the single most common way this flow fails.
                        nonce: credential.rawNonce
                    )
                )

                // Forward the one-shot name into user metadata. The signup trigger
                // reads `raw_user_meta_data->>'full_name'`, but it runs on INSERT
                // into auth.users, which may already have happened by the time this
                // lands — so `ensureDisplayName` below covers the profile row too.
                if let fullName = credential.fullName {
                    _ = try? await client.auth.update(
                        user: UserAttributes(data: ["full_name": .string(fullName)])
                    )
                    await ensureDisplayName(fullName)
                }
            } catch {
                lastError = SupabaseErrorPresenter.presentable(error, context: .signIn)
            }
        }
    }

    /// Writes Apple's one-shot full name into the profile row if it's still blank.
    /// Read-then-write rather than a conditional UPDATE: the only writer of this
    /// row is the user themselves, so there is no one to race with, and it keeps
    /// the "never overwrite a name the user chose" rule obvious.
    private func ensureDisplayName(_ fullName: String) async {
        guard let userID = try? await client.auth.session.user.id else { return }
        do {
            let profile: Profile = try await client
                .from("profiles")
                .select()
                .eq("id", value: userID.uuidString)
                .single()
                .execute()
                .value

            guard profile.displayName?.isEmpty ?? true else { return }

            try await client
                .from("profiles")
                .update(ProfileUpdate(displayName: fullName))
                .eq("id", value: userID.uuidString)
                .execute()
        } catch {
            // Cosmetic prefill only — a failure here must not block sign-in.
        }
    }

    // MARK: - Session management

    func signOut() async {
        do {
            try await client.auth.signOut()
            // The `.signedOut` event drives the state change; setting it here too
            // makes the UI respond immediately rather than one round trip later.
            state = .signedOut
        } catch {
            lastError = SupabaseErrorPresenter.presentable(error, context: .general)
        }
    }

    /// Permanently deletes the account via the `delete-account` Edge Function.
    ///
    /// The publishable key cannot delete an `auth.users` row, so this cannot be done
    /// client-side. The function verifies the caller's JWT, clears both storage
    /// buckets, and deletes the auth user, letting ON DELETE CASCADE remove the
    /// profile, visits, photos, friendships, recommendations, and wishlist rows.
    func deleteAccount() async -> Bool {
        do {
            try await client.functions.invoke(
                "delete-account",
                options: FunctionInvokeOptions(method: .post)
            )
            // The session's user no longer exists; drop it locally so the gate
            // closes even though the server can't revoke a JWT that's already out.
            try? await client.auth.signOut()
            state = .signedOut
            return true
        } catch {
            lastError = SupabaseErrorPresenter.presentable(error, context: .accountDeletion)
            return false
        }
    }

    /// Re-runs profile resolution. Used by the Retry button on error alerts.
    func retry() async {
        guard let userID = try? await client.auth.session.user.id else {
            state = .signedOut
            return
        }
        await resolveProfile(for: userID)
    }
}

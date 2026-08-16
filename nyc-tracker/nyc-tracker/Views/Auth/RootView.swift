import SwiftUI

/// The auth gate. Nothing reaches `ContentView` without a session and a username.
///
/// This is a hard gate by design: no guest mode, no "skip for now", no way to
/// dismiss the username screen. Since every table in the backend grants access
/// only to the `authenticated` role, an app without a session literally cannot
/// read or write anything — a guest mode would be a screen full of empty states.
struct RootView: View {
    @Environment(AuthManager.self) private var auth

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                LaunchSplash()

            case .signedOut:
                AuthView()

            case .needsUsername:
                UsernameSetupView()

            case .signedIn:
                // The existing app, untouched.
                ContentView()
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

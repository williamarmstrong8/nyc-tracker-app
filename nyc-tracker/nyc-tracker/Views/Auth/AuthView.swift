import SwiftUI
import AuthenticationServices

/// Sign-in screen. Sign in with Apple is the only provider.
///
/// Uses the native `SignInWithAppleButton` + `signInWithIdToken` flow rather than
/// Supabase's web OAuth redirect: no Safari hand-off, no custom URL scheme, no
/// Services ID, and Face ID completes it in about a second.
struct AuthView: View {
    @Environment(AuthManager.self) private var auth
    @Environment(\.colorScheme) private var colorScheme

    /// The nonce for the in-flight request. Created in `onRequest` and read back
    /// in `onCompletion`, because Apple gets the hash and Supabase needs the raw
    /// value — they have to be the same pair.
    @State private var nonce: AppleNonce?

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                header

                Spacer()

                signInButton
                    .padding(.horizontal, 32)

                Text("We only use your Apple ID to create your account. Your name and email are never shared with other users.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 18) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("NYC Log")
                    .font(.largeTitle.weight(.bold))

                Text("Every place you've been, and everywhere your friends say to go.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    private var signInButton: some View {
        ZStack {
            SignInWithAppleButton(.signIn) { request in
                nonce = auth.prepareAppleRequest(request)
            } onCompletion: { result in
                // Cancellation is filtered inside completeSignIn — tapping Cancel
                // must not produce an alert.
                guard let nonce else { return }
                Task {
                    await auth.completeSignIn(with: result, nonce: nonce)
                    self.nonce = nil
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(auth.isSigningIn ? 0 : 1)
            .disabled(auth.isSigningIn)
            .accessibilityLabel("Sign in with Apple")

            if auth.isSigningIn {
                ProgressView()
                    .controlSize(.regular)
                    .frame(height: 52)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: auth.isSigningIn)
    }
}

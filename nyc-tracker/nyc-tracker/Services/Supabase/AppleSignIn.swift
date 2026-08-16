import Foundation
import CryptoKit
import AuthenticationServices

/// Nonce plumbing for the native Sign in with Apple flow.
///
/// ## The part that goes wrong
///
/// There are two nonces in play and they are not interchangeable:
///
/// * Apple's `ASAuthorizationAppleIDRequest.nonce` must be the **SHA256 hash** of
///   the random string. Apple embeds that hash in the identity token it returns.
/// * Supabase's `signInWithIdToken(nonce:)` must be the **raw** random string.
///   The server hashes it itself and compares against the claim in the token.
///
/// Send them the other way round and Apple accepts the sign-in, Supabase rejects
/// the token, and the error message says nothing about nonces. `AppleNonce` keeps
/// both halves in one value so a call site cannot mix them up.
struct AppleNonce: Sendable {
    /// Pass to Supabase.
    let raw: String
    /// Pass to Apple.
    let hashed: String

    init() {
        let raw = Self.randomNonceString()
        self.raw = raw
        self.hashed = Self.sha256(raw)
    }

    /// Cryptographically random, URL-safe. `SecRandomCopyBytes` rather than
    /// `Int.random` — this value is a replay-attack guard, so it has to come from
    /// the system CSPRNG.
    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length

        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            guard status == errSecSuccess else {
                fatalError("Unable to generate a secure nonce (SecRandomCopyBytes failed: \(status))")
            }
            for random in randoms where remaining > 0 {
                // Reject values that would bias the modulo; charset is 64 chars so
                // this discards very little.
                if random < charset.count * (255 / charset.count) {
                    result.append(charset[Int(random) % charset.count])
                    remaining -= 1
                }
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// What we managed to extract from an Apple credential.
struct AppleCredential: Sendable {
    /// JWT to hand to Supabase.
    let identityToken: String
    /// Raw nonce that matches the hash inside `identityToken`.
    let rawNonce: String
    /// Only present on the **first ever** authorization for this Apple ID + app
    /// pair. Apple never sends it again — not on the next sign-in, not after a
    /// reinstall. Captured here and forwarded as user metadata so the signup
    /// trigger can prefill `display_name`.
    let fullName: String?
    /// Same first-time-only caveat as `fullName`.
    let email: String?

    init?(authorization: ASAuthorization, rawNonce: String) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let token = String(data: tokenData, encoding: .utf8)
        else { return nil }

        self.identityToken = token
        self.rawNonce = rawNonce
        self.email = credential.email

        if let components = credential.fullName {
            let formatter = PersonNameComponentsFormatter()
            formatter.style = .default
            let name = formatter.string(from: components).trimmingCharacters(in: .whitespaces)
            self.fullName = name.isEmpty ? nil : name
        } else {
            self.fullName = nil
        }
    }
}

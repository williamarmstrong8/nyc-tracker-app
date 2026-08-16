import Foundation
// `Supabase` re-exports Auth / PostgREST / Storage / Functions with @_exported,
// so PostgrestError and AuthError are visible from this single import even with
// SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY enabled.
import Supabase

/// A backend failure translated into something a person can act on.
///
/// Supabase errors arrive as raw Postgres codes ("23505"), HTTP statuses, or
/// URLSession errors. Surfacing those directly is how an app ends up showing
/// `duplicate key value violates unique constraint "profiles_username_key"` in a
/// sheet. This type is the one place that mapping happens.
struct PresentableError: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// Short sheet/alert title.
    let title: String
    /// One sentence the user can act on.
    let message: String
    /// Whether offering a Retry button makes sense. False for "you typed something
    /// invalid" — retrying the same input fails the same way.
    let isRetryable: Bool

    static func == (lhs: PresentableError, rhs: PresentableError) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message && lhs.isRetryable == rhs.isRetryable
    }
}

enum SupabaseErrorPresenter {

    /// Postgres SQLSTATE for a unique-constraint violation. The username race lands here.
    static let uniqueViolation = "23505"
    /// Postgres SQLSTATE for a CHECK-constraint violation.
    static let checkViolation = "23514"
    /// Postgres SQLSTATE PostgREST returns when RLS blocks a write.
    static let insufficientPrivilege = "42501"

    static func presentable(_ error: any Error, context: Context = .general) -> PresentableError {
        // ---- User cancelled Sign in with Apple ------------------------------
        // Not an error. Callers should filter these out before ever calling here;
        // handled anyway so a stray one doesn't produce a scary alert.
        if isCancellation(error) {
            return PresentableError(
                title: "Cancelled",
                message: "Sign in was cancelled.",
                isRetryable: true
            )
        }

        // ---- Network ---------------------------------------------------------
        if let urlError = error as? URLError {
            return network(urlError, context: context)
        }

        // ---- Postgres / PostgREST -------------------------------------------
        if let postgrest = error as? PostgrestError {
            return self.postgrest(postgrest, context: context)
        }

        // ---- Auth ------------------------------------------------------------
        if let authError = error as? AuthError {
            return auth(authError, context: context)
        }

        return PresentableError(
            title: context.genericTitle,
            message: "Something went wrong. Please try again.",
            isRetryable: true
        )
    }

    /// Where the failure happened. Only changes the wording, never the logic.
    enum Context {
        case general
        case signIn
        case usernameSetup
        case profileUpdate
        case avatarUpload
        case accountDeletion

        var genericTitle: String {
            switch self {
            case .general:         "Something went wrong"
            case .signIn:          "Couldn't sign in"
            case .usernameSetup:   "Couldn't save username"
            case .profileUpdate:   "Couldn't save changes"
            case .avatarUpload:    "Couldn't upload photo"
            case .accountDeletion: "Couldn't delete account"
            }
        }
    }

    // MARK: - Mapping

    private static func network(_ error: URLError, context: Context) -> PresentableError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return PresentableError(
                title: "No connection",
                message: "You're offline. Check your connection and try again.",
                isRetryable: true
            )
        case .timedOut:
            return PresentableError(
                title: "Timed out",
                message: "The server took too long to respond. Try again.",
                isRetryable: true
            )
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return PresentableError(
                title: "Can't reach the server",
                message: "We couldn't reach the server. Try again in a moment.",
                isRetryable: true
            )
        case .cancelled:
            return PresentableError(title: "Cancelled", message: "The request was cancelled.", isRetryable: true)
        default:
            return PresentableError(
                title: context.genericTitle,
                message: "A network problem interrupted the request. Try again.",
                isRetryable: true
            )
        }
    }

    private static func postgrest(_ error: PostgrestError, context: Context) -> PresentableError {
        // `code` is optional on PostgrestError — coalesce so the SQLSTATE
        // constants above can be matched as plain String patterns.
        switch error.code ?? "" {
        case uniqueViolation:
            // The important one. Two users can pass the debounced availability
            // check at the same instant; the index decides, and this is what the
            // loser sees.
            if context == .usernameSetup || error.message.contains("username") {
                return PresentableError(
                    title: "Username taken",
                    message: "Someone just claimed that username. Try another one.",
                    isRetryable: false
                )
            }
            return PresentableError(
                title: "Already exists",
                message: "That already exists. Try a different value.",
                isRetryable: false
            )

        case checkViolation:
            if context == .usernameSetup {
                return PresentableError(
                    title: "Invalid username",
                    message: "Usernames must be 3–20 characters, using lowercase letters, numbers, or underscores.",
                    isRetryable: false
                )
            }
            return PresentableError(
                title: context.genericTitle,
                message: "That value isn't allowed. Check it and try again.",
                isRetryable: false
            )

        case insufficientPrivilege:
            return PresentableError(
                title: "Not allowed",
                message: "You don't have permission to do that.",
                isRetryable: false
            )

        default:
            return PresentableError(
                title: context.genericTitle,
                message: "The server rejected the request. Try again.",
                isRetryable: true
            )
        }
    }

    private static func auth(_ error: AuthError, context: Context) -> PresentableError {
        let text = error.localizedDescription.lowercased()

        if text.contains("network") || text.contains("connection") {
            return PresentableError(
                title: "No connection",
                message: "You're offline. Check your connection and try again.",
                isRetryable: true
            )
        }
        if text.contains("expired") || text.contains("invalid token") || text.contains("jwt") {
            return PresentableError(
                title: "Session expired",
                message: "Your session expired. Sign in again to continue.",
                isRetryable: true
            )
        }
        return PresentableError(
            title: context.genericTitle,
            message: "Authentication failed. Please try again.",
            isRetryable: true
        )
    }

    /// Sign in with Apple reports a user-initiated cancel as an error (code 1001).
    /// Showing an alert for it is the classic "user tapped Cancel, app yelled at
    /// them" bug, so it is detected here and everywhere it matters.
    static func isCancellation(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "com.apple.AuthenticationServices.AuthorizationError",
           nsError.code == 1001 {
            return true
        }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return true
        }
        return error is CancellationError
    }
}

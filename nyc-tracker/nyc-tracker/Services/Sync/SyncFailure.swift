import Foundation
import Supabase

/// What kind of failure the sync engine just hit, and therefore what to do next.
///
/// The distinction that matters is *retryable vs not*. Retrying a dropped
/// connection is right; retrying a 10 MB photo that the bucket will reject at
/// any size limit is an infinite loop that burns the user's battery and data to
/// arrive at the same rejection. Classifying once, here, keeps that judgement out
/// of the retry loop.
enum SyncFailure: Sendable {
    /// Offline, timeout, 5xx. Back off and try again — this is the common case.
    case transient
    /// The session is no longer valid. Refresh once, then surface the auth gate.
    case authExpired
    /// The server will reject this payload every time: too large, over quota, or
    /// a constraint violation. Stop retrying and tell the user.
    case permanent(String)

    var isRetryable: Bool {
        if case .permanent = self { return false }
        return true
    }

    /// Message stored on `Visit.syncError` and shown in the retry UI.
    var message: String {
        switch self {
        case .transient:
            "Couldn't reach the server. Will retry automatically."
        case .authExpired:
            "Your session expired. Sign in again to finish uploading."
        case .permanent(let reason):
            reason
        }
    }

    // MARK: - Classification

    static func classify(_ error: any Error) -> SyncFailure {
        if error is CancellationError { return .transient }

        // ---- Image preparation -------------------------------------------
        // A photo we can't decode will never decode. Retrying is pointless and
        // the row would sit in the failed list forever with a misleading
        // "will retry" message.
        if let prepare = error as? ImagePreparer.PrepareError {
            return .permanent(prepare.errorDescription ?? "That photo couldn't be processed.")
        }

        // ---- Network -----------------------------------------------------
        if let urlError = error as? URLError {
            switch urlError.code {
            case .dataLengthExceedsMaximum:
                return .permanent("That photo is too large to upload.")
            default:
                return .transient
            }
        }

        // ---- Auth --------------------------------------------------------
        if error is AuthError {
            let text = error.localizedDescription.lowercased()
            if text.contains("expired") || text.contains("jwt") || text.contains("invalid token") {
                return .authExpired
            }
            return .transient
        }

        // ---- PostgREST ---------------------------------------------------
        if let postgrest = error as? PostgrestError {
            return classify(postgrest)
        }

        // ---- Storage -----------------------------------------------------
        // supabase-swift surfaces storage failures as a distinct error type whose
        // shape has moved between releases, so this matches on the message rather
        // than binding to a struct whose fields may be renamed. Crude, but the
        // failure mode of a bad match is one extra retry, not lost data.
        let text = error.localizedDescription.lowercased()

        if text.contains("jwt") || text.contains("token is expired")
            || text.contains("unauthorized") || text.contains("401") {
            return .authExpired
        }
        if text.contains("exceeded the maximum allowed size")
            || text.contains("payload too large") || text.contains("413") {
            return .permanent("That photo is larger than the 10 MB upload limit.")
        }
        if text.contains("quota") || text.contains("storage limit")
            || text.contains("insufficient storage") {
            return .permanent("Your cloud storage is full. Free up space to keep syncing.")
        }
        if text.contains("mime type") || text.contains("invalid_mime_type") {
            return .permanent("That file type can't be uploaded.")
        }

        return .transient
    }

    private static func classify(_ error: PostgrestError) -> SyncFailure {
        switch error.code ?? "" {
        // RLS refused the write. Under normal operation this means the JWT no
        // longer matches the row's user_id — a stale session, not a code bug —
        // so treat it as an auth problem and let the refresh path decide.
        case SupabaseErrorPresenter.insufficientPrivilege:
            return .authExpired

        // JWT expired / not yet valid.
        case "PGRST301", "PGRST302":
            return .authExpired

        case SupabaseErrorPresenter.checkViolation:
            return .permanent("The server rejected part of this entry. Try editing and saving it again.")

        // FK violation: the place row this visit points at is gone. Re-resolving
        // the place is a code path we have, so let it retry — but it is worth
        // knowing this is the shape a corrupted place cache takes.
        case "23503":
            return .transient

        default:
            // 5xx and connection-level PostgREST errors have no SQLSTATE.
            return .transient
        }
    }
}

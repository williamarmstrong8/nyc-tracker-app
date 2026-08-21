import Foundation
import Supabase

/// Reads and writes for the `profiles` table plus the `avatars` bucket.
///
/// Kept separate from `AuthManager`: the manager owns *session* state, this owns
/// *profile* data. Views call this and then hand the fresh `Profile` back to the
/// manager, so there is still one owner of `AuthState`.
enum ProfileService {

    private static var client: SupabaseClient { SupabaseManager.client }

    // MARK: - Username

    /// Client-side format rules, matched exactly to the `profiles_username_format`
    /// CHECK constraint. Duplicated on purpose: the DB constraint is the guarantee,
    /// this is the instant feedback.
    enum UsernameValidation: Equatable {
        case empty
        case tooShort
        case tooLong
        case invalidCharacters
        case valid

        var message: String? {
            switch self {
            case .empty:             nil
            case .tooShort:          "At least 3 characters."
            case .tooLong:           "At most 20 characters."
            case .invalidCharacters: "Lowercase letters, numbers, and underscores only."
            case .valid:             nil
            }
        }

        var isValid: Bool { self == .valid }
    }

    static func validate(username raw: String) -> UsernameValidation {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .empty }
        if value.count < 3 { return .tooShort }
        if value.count > 20 { return .tooLong }
        guard value.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil else {
            return .invalidCharacters
        }
        return .valid
    }

    /// Asks the server whether a username is free.
    ///
    /// This is a UX affordance, not a guarantee. Two people can get `true` back at
    /// the same instant — the unique index is what actually decides, and
    /// `setUsername` handles the 23505 that the loser gets.
    static func isUsernameAvailable(_ username: String) async throws -> Bool {
        try await client
            .rpc("is_username_available", params: ["p_username": username])
            .execute()
            .value
    }

    /// Claims a username for the signed-in user.
    ///
    /// Lowercases before sending. The DB CHECK is case-sensitive by design (see
    /// the comment on `profiles_username_format`), so an uppercase character would
    /// otherwise be rejected by the server after passing client validation.
    @discardableResult
    static func setUsername(_ username: String, displayName: String?) async throws -> Profile {
        let userID = try await client.auth.session.user.id
        let normalized = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let trimmedDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)

        let update = ProfileUpdate(
            username: normalized,
            displayName: (trimmedDisplayName?.isEmpty ?? true) ? nil : trimmedDisplayName
        )

        return try await client
            .from("profiles")
            .update(update)
            .eq("id", value: userID.uuidString)
            .select()
            .single()
            .execute()
            .value
    }

    // MARK: - Profile edits

    @discardableResult
    static func updateProfile(displayName: String?, bio: String?) async throws -> Profile {
        let userID = try await client.auth.session.user.id

        // An emptied field must reach Postgres as SQL NULL, not "": the column
        // CHECKs require 1+ characters when non-null, and omitting the key would
        // leave the old value in place (user clears their bio, saves, bio is
        // still there). `ProfileDetailsUpdate` encodes nil as an explicit null.
        let update = ProfileDetailsUpdate(
            displayName: nilIfBlank(displayName),
            bio: nilIfBlank(bio)
        )

        return try await client
            .from("profiles")
            .update(update)
            .eq("id", value: userID.uuidString)
            .select()
            .single()
            .execute()
            .value
    }

    // MARK: - Avatar

    /// Uploads a JPEG to `avatars/{user_id}/avatar.jpg` and records the public URL.
    ///
    /// The path is fixed per user (not a fresh UUID each time) so old avatars don't
    /// accumulate in the bucket. That requires upsert, which is why the bucket has
    /// both an INSERT and an UPDATE storage policy — with only INSERT, the first
    /// avatar works and every change after it fails.
    ///
    /// A cache-busting query item is appended to the stored URL because the path is
    /// stable and the CDN would otherwise keep serving the previous image.
    @discardableResult
    static func uploadAvatar(_ jpegData: Data) async throws -> Profile {
        let userID = try await client.auth.session.user.id
        let path = "\(userID.uuidString.lowercased())/avatar.jpg"

        _ = try await client.storage
            .from("avatars")
            .upload(
                path,
                data: jpegData,
                options: FileOptions(contentType: "image/jpeg", upsert: true)
            )

        let publicURL = try client.storage.from("avatars").getPublicURL(path: path)
        let bustedURL = "\(publicURL.absoluteString)?v=\(Int(Date().timeIntervalSince1970))"

        // Seed the local cache with the bytes we just uploaded, under the new
        // URL. Without this the user's own new picture is the one image in the
        // app that has to be downloaded to be seen — and it is the image they
        // are most obviously waiting on. It also sidesteps the window where the
        // CDN has not yet picked the object up.
        //
        // Writing under the busted URL is what retires the previous version:
        // `AvatarCache` keys on that URL and deletes the file the old one was
        // cached under, so a person who changes their picture often leaves one
        // file behind rather than one per upload.
        AvatarCache.shared.prime(jpegData, for: bustedURL)

        return try await client
            .from("profiles")
            .update(ProfileUpdate(avatarURL: bustedURL))
            .eq("id", value: userID.uuidString)
            .select()
            .single()
            .execute()
            .value
    }

    // MARK: - Helpers

    private static func nilIfBlank(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

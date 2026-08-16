import Foundation

// ============================================================================
// Codable mirrors of the Postgres tables.
// ============================================================================
// These are DTOs, not app models. The SwiftData `@Model` types in Models.swift
// remain the app's source of truth; these types exist only to move rows across
// the wire. Deliberately kept as separate types rather than making the SwiftData
// classes Codable — a schema change on either side should not silently reshape
// the other, and the mapping between them is where sync logic will live.
//
// Every property maps snake_case → camelCase through explicit CodingKeys rather
// than a `.convertFromSnakeCase` strategy, because that strategy also mangles
// keys on the way out and produces confusing round-trip bugs with acronyms.
//
// `RemoteX` naming keeps these from colliding with the SwiftData `Place` /
// `Visit` / `Photo` classes already in the target.
// ============================================================================

// MARK: - Profile

struct Profile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// `nil` until the user completes username setup. Drives `AuthState.needsUsername`.
    var username: String?
    var displayName: String?
    var avatarURL: String?
    var bio: String?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
        case avatarURL   = "avatar_url"
        case bio
        case createdAt   = "created_at"
        case updatedAt   = "updated_at"
    }

    /// Best label for the UI: display name, else the handle, else a neutral fallback.
    var bestName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let username, !username.isEmpty { return username }
        return "New user"
    }

    var handle: String? {
        guard let username, !username.isEmpty else { return nil }
        return "@\(username)"
    }
}

/// Partial update payload. Only non-nil fields are sent, so a PATCH that changes
/// the bio doesn't blank the avatar.
///
/// Because nil means "leave alone", this type cannot express "clear this column" —
/// use `ProfileDetailsUpdate` for the editable text fields, which can.
struct ProfileUpdate: Encodable, Sendable {
    var username: String?
    var displayName: String?
    var avatarURL: String?
    var bio: String?

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
        case avatarURL   = "avatar_url"
        case bio
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encodeIfPresent(bio, forKey: .bio)
    }
}

/// Update payload for the user-editable text fields, where nil means **clear the
/// column** rather than "leave it alone".
///
/// The distinction matters: `display_name` and `bio` carry
/// `char_length(...) between 1 and 50` style CHECK constraints, so clearing a
/// field has to send SQL NULL. Sending `""` would fail the constraint, and
/// omitting the key would silently keep the old value — the user clears their bio,
/// taps Save, and the bio is still there.
struct ProfileDetailsUpdate: Encodable, Sendable {
    var displayName: String?
    var bio: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case bio
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // `encode` (not `encodeIfPresent`) so nil is written as JSON null.
        try container.encode(displayName, forKey: .displayName)
        try container.encode(bio, forKey: .bio)
    }
}

// MARK: - Place

struct RemotePlace: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var mapkitID: String?
    var name: String
    /// Generated column. Read-only — Postgres rejects any attempt to write it.
    var normalizedName: String?
    var streetAddress: String?
    var locality: String?
    var adminArea: String?
    var country: String?
    var postalCode: String?
    var latitude: Double
    var longitude: Double
    /// Generated column. Read-only.
    var geohash7: String?
    var category: String?
    var phone: String?
    var websiteURL: String?
    var createdAt: Date?
    var createdBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case mapkitID       = "mapkit_id"
        case name
        case normalizedName = "normalized_name"
        case streetAddress  = "street_address"
        case locality
        case adminArea      = "admin_area"
        case country
        case postalCode     = "postal_code"
        case latitude
        case longitude
        case geohash7
        case category
        case phone
        case websiteURL     = "website_url"
        case createdAt      = "created_at"
        case createdBy      = "created_by"
    }
}

/// Argument list for the `find_or_create_place` RPC.
///
/// Never insert into `places` directly — the function is the only write path, and
/// it is what makes concurrent check-ins at the same venue resolve to one row.
struct FindOrCreatePlaceParams: Encodable, Sendable {
    var mapkitID: String?
    var name: String
    var latitude: Double
    var longitude: Double
    var streetAddress: String?
    var locality: String?
    var adminArea: String?
    var country: String?
    var postalCode: String?
    var category: String?
    var phone: String?
    var websiteURL: String?

    enum CodingKeys: String, CodingKey {
        case mapkitID      = "p_mapkit_id"
        case name          = "p_name"
        case latitude      = "p_latitude"
        case longitude     = "p_longitude"
        case streetAddress = "p_street_address"
        case locality      = "p_locality"
        case adminArea     = "p_admin_area"
        case country       = "p_country"
        case postalCode    = "p_postal_code"
        case category      = "p_category"
        case phone         = "p_phone"
        case websiteURL    = "p_website_url"
    }
}

// MARK: - Visit

struct RemoteVisit: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var userID: UUID
    var placeID: UUID
    var visitedAt: Date
    /// Verbatim voice-memo transcription. The audio itself is never uploaded.
    var transcript: String?
    /// On-device AI write-up.
    var summary: String?
    var tags: [String]
    var note: String?
    /// Unused today; the column exists for a future Beli-style ranking.
    var rating: Double?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userID    = "user_id"
        case placeID   = "place_id"
        case visitedAt = "visited_at"
        case transcript
        case summary
        case tags
        case note
        case rating
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Visit photo

struct RemoteVisitPhoto: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var visitID: UUID
    /// Path inside the `visit-photos` bucket — `{user_id}/{visit_id}/{uuid}.jpg`.
    /// Not a URL; URLs are generated at read time from this.
    var storagePath: String
    var width: Int?
    var height: Int?
    var sortOrder: Int
    var capturedAt: Date?
    var exifLatitude: Double?
    var exifLongitude: Double?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case visitID       = "visit_id"
        case storagePath   = "storage_path"
        case width
        case height
        case sortOrder     = "sort_order"
        case capturedAt    = "captured_at"
        case exifLatitude  = "exif_latitude"
        case exifLongitude = "exif_longitude"
        case createdAt     = "created_at"
    }
}

// MARK: - Friendship

enum FriendshipStatus: String, Codable, Sendable {
    case pending
    case accepted
    case blocked
}

struct Friendship: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var requesterID: UUID
    var addresseeID: UUID
    var status: FriendshipStatus
    var createdAt: Date?
    var respondedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case requesterID = "requester_id"
        case addresseeID = "addressee_id"
        case status
        case createdAt   = "created_at"
        case respondedAt = "responded_at"
    }

    /// The other party, from `viewer`'s perspective.
    func otherParty(from viewer: UUID) -> UUID {
        requesterID == viewer ? addresseeID : requesterID
    }
}

// MARK: - Recommendation

enum RecommendationStatus: String, Codable, Sendable {
    case unread
    case read
    case dismissed
}

struct Recommendation: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var senderID: UUID
    var recipientID: UUID
    var placeID: UUID
    var message: String?
    var status: RecommendationStatus
    var createdAt: Date?
    var readAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case senderID    = "sender_id"
        case recipientID = "recipient_id"
        case placeID     = "place_id"
        case message
        case status
        case createdAt   = "created_at"
        case readAt      = "read_at"
    }
}

// MARK: - Wishlist

enum WishlistSource: String, Codable, Sendable {
    case manual
    case recommendation
}

struct WishlistItem: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var userID: UUID
    var placeID: UUID
    var source: WishlistSource
    var sourceRecommendationID: UUID?
    /// Set when the user actually goes: the item stays on record instead of
    /// being deleted, so "wanted to go → went" is queryable.
    var resolvedVisitID: UUID?
    var createdAt: Date?
    var resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userID                 = "user_id"
        case placeID                = "place_id"
        case source
        case sourceRecommendationID = "source_recommendation_id"
        case resolvedVisitID        = "resolved_visit_id"
        case createdAt              = "created_at"
        case resolvedAt             = "resolved_at"
    }

    var isResolved: Bool { resolvedVisitID != nil }
}

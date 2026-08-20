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
    /// Sub-locality ("West Village"). Distinct from `locality`, which is the city.
    var neighborhood: String?
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
        case neighborhood
        case createdAt      = "created_at"
        case createdBy      = "created_by"
    }

    /// Best single line to show under a venue name.
    var displayAddress: String? {
        let parts = [streetAddress, neighborhood ?? locality].compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
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
    var neighborhood: String?

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
        case neighborhood  = "p_neighborhood"
    }
}

/// Argument list for the `update_place_category` RPC.
///
/// Separate from `find_or_create_place`: that function only ever fills in a
/// null `category`, so correcting an already-set one (e.g. a MapKit
/// restaurant mislabeled as a cafe) needs its own explicit write path.
struct UpdatePlaceCategoryParams: Encodable, Sendable {
    var placeID: UUID
    var category: String

    enum CodingKeys: String, CodingKey {
        case placeID  = "p_place_id"
        case category = "p_category"
    }
}

// MARK: - Visit

struct RemoteVisit: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var userID: UUID
    var placeID: UUID
    var visitedAt: Date
    /// Verbatim voice-memo transcription. The audio itself is never uploaded —
    /// it is deleted on device the moment this text is produced.
    var transcript: String?
    /// On-device AI write-up.
    var summary: String?
    var tags: [String]
    var note: String?
    /// This user's heading for the entry. Distinct from the shared `places.name`.
    var title: String?
    /// Pull quote lifted from the transcript by the on-device model.
    var topQuote: String?
    /// `loved` | `liked` | `fine` | `no` — what the user tapped.
    var ratingLabel: String?
    var returnIntent: String?
    /// `visited` | `wantToTry`.
    var kind: String
    /// Reserved for a future Beli-style 0–10 ranking; not what the user tapped.
    var rating: Double?
    /// Tombstone. Non-null means the row is deleted.
    var deletedAt: Date?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userID       = "user_id"
        case placeID      = "place_id"
        case visitedAt    = "visited_at"
        case transcript
        case summary
        case tags
        case note
        case title
        case topQuote     = "top_quote"
        case ratingLabel  = "rating_label"
        case returnIntent = "return_intent"
        case kind
        case rating
        case deletedAt    = "deleted_at"
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
    }

    var isDeleted: Bool { deletedAt != nil }
}

/// Payload for the visit upsert.
///
/// Separate from `RemoteVisit` because that type carries read-only server
/// columns (`created_at`, `updated_at`) — sending them back would either be
/// ignored or fight the `visits_touch_updated_at` trigger, and `updated_at` in
/// particular must be the server's clock, not the device's, or the pull
/// watermark starts skipping rows written by a device with a slow clock.
struct VisitUpsert: Encodable, Sendable {
    var id: UUID
    var userID: UUID
    var placeID: UUID
    var visitedAt: Date
    var transcript: String?
    var summary: String?
    var tags: [String]
    var title: String?
    var topQuote: String?
    var ratingLabel: String?
    var returnIntent: String?
    var kind: String
    /// Always written, and always explicitly — an upsert that omitted this could
    /// never un-delete, and "undo a delete" is a real path (a tombstone that
    /// fails and the user re-creates the entry).
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userID       = "user_id"
        case placeID      = "place_id"
        case visitedAt    = "visited_at"
        case transcript
        case summary
        case tags
        case title
        case topQuote     = "top_quote"
        case ratingLabel  = "rating_label"
        case returnIntent = "return_intent"
        case kind
        case deletedAt    = "deleted_at"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userID, forKey: .userID)
        try container.encode(placeID, forKey: .placeID)
        try container.encode(visitedAt, forKey: .visitedAt)
        try container.encode(tags, forKey: .tags)
        try container.encode(kind, forKey: .kind)
        // `encode` not `encodeIfPresent` for the nullable text: clearing a field
        // locally has to reach Postgres as SQL NULL. Omitting the key on an
        // upsert leaves the previous value in place, so the user deletes their
        // note, it syncs "successfully", and the note comes back on reinstall.
        try container.encode(transcript, forKey: .transcript)
        try container.encode(summary, forKey: .summary)
        try container.encode(title, forKey: .title)
        try container.encode(topQuote, forKey: .topQuote)
        try container.encode(ratingLabel, forKey: .ratingLabel)
        try container.encode(returnIntent, forKey: .returnIntent)
        try container.encode(deletedAt, forKey: .deletedAt)
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
    /// ~400px companion object. Null falls back to `storagePath`.
    var thumbPath: String?
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
        case thumbPath     = "thumb_path"
        case createdAt     = "created_at"
    }

    /// Path to fetch for a small render. Prefers the thumbnail, falls back to the
    /// full image so a photo whose thumb upload failed still shows something.
    var smallestPath: String { thumbPath ?? storagePath }
}

/// Upsert payload for a photo row — omits the server-managed `created_at`.
struct VisitPhotoUpsert: Encodable, Sendable {
    var id: UUID
    var visitID: UUID
    var storagePath: String
    var thumbPath: String?
    var width: Int?
    var height: Int?
    var sortOrder: Int
    var capturedAt: Date?
    var exifLatitude: Double?
    var exifLongitude: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case visitID       = "visit_id"
        case storagePath   = "storage_path"
        case thumbPath     = "thumb_path"
        case width
        case height
        case sortOrder     = "sort_order"
        case capturedAt    = "captured_at"
        case exifLatitude  = "exif_latitude"
        case exifLongitude = "exif_longitude"
    }
}

/// A visit fetched together with its place and photos, in one round trip.
///
/// PostgREST embeds related rows when the select string names them
/// (`*, place:places(*), photos:visit_photos(*)`). Doing it as one request
/// rather than three is what keeps the pull cheap: a user with 200 visits would
/// otherwise make 401 requests, and the two follow-ups can't start until the
/// first finishes.
struct RemoteVisitWithRelations: Decodable, Identifiable, Sendable {
    let id: UUID
    var userID: UUID
    var placeID: UUID
    var visitedAt: Date
    var transcript: String?
    var summary: String?
    var tags: [String]
    var note: String?
    var title: String?
    var topQuote: String?
    var ratingLabel: String?
    var returnIntent: String?
    var kind: String
    var deletedAt: Date?
    var updatedAt: Date?
    var place: RemotePlace?
    var photos: [RemoteVisitPhoto]
    var tagged: [RemoteVisitTag]

    enum CodingKeys: String, CodingKey {
        case id
        case userID       = "user_id"
        case placeID      = "place_id"
        case visitedAt    = "visited_at"
        case transcript
        case summary
        case tags
        case note
        case title
        case topQuote     = "top_quote"
        case ratingLabel  = "rating_label"
        case returnIntent = "return_intent"
        case kind
        case deletedAt    = "deleted_at"
        case updatedAt    = "updated_at"
        case place
        case photos
        case tagged
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userID = try container.decode(UUID.self, forKey: .userID)
        placeID = try container.decode(UUID.self, forKey: .placeID)
        visitedAt = try container.decode(Date.self, forKey: .visitedAt)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        // `tags` is `not null default '{}'` upstream, but decoding defensively
        // here means one unexpected null doesn't fail the whole page of results.
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        topQuote = try container.decodeIfPresent(String.self, forKey: .topQuote)
        ratingLabel = try container.decodeIfPresent(String.self, forKey: .ratingLabel)
        returnIntent = try container.decodeIfPresent(String.self, forKey: .returnIntent)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "visited"
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        place = try container.decodeIfPresent(RemotePlace.self, forKey: .place)
        photos = try container.decodeIfPresent([RemoteVisitPhoto].self, forKey: .photos) ?? []
        tagged = try container.decodeIfPresent([RemoteVisitTag].self, forKey: .tagged) ?? []
    }

    var isDeleted: Bool { deletedAt != nil }
}

/// A `visit_tags` row with the tagged person's profile joined in, as it arrives
/// on the pull's embedded select.
///
/// The profile half is its own nested type rather than the full `Profile` DTO:
/// the embed asks for four columns, and `Profile` requires `created_at` and
/// `updated_at`, so decoding into it would throw on every row.
struct RemoteVisitTag: Decodable, Sendable {
    /// Present even when the profile embed comes back null — a deleted account
    /// part-way through its cascade — so the row can still be matched against a
    /// local one and removed.
    var userID: UUID
    var createdAt: Date?
    var profile: TaggedProfile?

    struct TaggedProfile: Decodable, Sendable {
        var id: UUID
        var username: String?
        var displayName: String?
        var avatarURL: String?

        enum CodingKeys: String, CodingKey {
            case id
            case username
            case displayName = "display_name"
            case avatarURL   = "avatar_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case userID    = "user_id"
        case createdAt = "created_at"
        case profile
    }

    var person: PersonSummary {
        PersonSummary(
            id: userID,
            username: profile?.username,
            displayName: profile?.displayName,
            avatarURL: profile?.avatarURL
        )
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

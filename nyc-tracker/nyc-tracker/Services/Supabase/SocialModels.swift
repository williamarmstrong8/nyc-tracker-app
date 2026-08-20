import Foundation

// ============================================================================
// DTOs for the social RPCs in 20260816000200_social_graph.sql.
// ============================================================================
// Same rules as RemoteModels.swift: these are wire types, never app models, and
// every key is spelled out rather than inferred by a snake_case strategy.
//
// They are kept in their own file because none of them mirror a table. Each one
// is the shape of a *function's* result — a join that only exists at the API
// boundary — and mixing them in with the table mirrors would blur the one
// distinction that matters when the schema changes: a table DTO breaks when a
// column moves, these break when a function's signature moves.
//
// Nothing here ever reaches SwiftData. Friend data is browsable, not owned; the
// local store is the user's own mirror and stays that way.
// ============================================================================

// MARK: - Person

/// The minimum needed to render someone: an avatar, a name, a handle.
///
/// Three different RPCs return a person alongside their payload (a search hit, a
/// friendship edge, the author of a visit). Normalising them onto one type here
/// means the avatar and name views are written once instead of three times.
struct PersonSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var username: String?
    var displayName: String?
    var avatarURL: String?

    /// Display name, else handle, else a neutral fallback. Matches `Profile.bestName`
    /// so a person reads identically wherever they appear.
    var bestName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let username, !username.isEmpty { return username }
        return "New user"
    }

    var handle: String? {
        guard let username, !username.isEmpty else { return nil }
        return "@\(username)"
    }

    /// First name only, for possessive copy ("Sam's map").
    var shortName: String {
        bestName.split(separator: " ").first.map(String.init) ?? bestName
    }
}

// MARK: - Relationship

/// The caller's relationship to another user, as computed by `search_profiles`.
///
/// This drives which action button a search row shows, which is why it is a
/// closed enum rather than a pair of booleans: "they requested me" and "I
/// requested them" are mutually exclusive by the pair index, and modelling them
/// separately invites a UI that can render both at once.
enum RelationshipState: String, Codable, Sendable {
    /// No row for this pair.
    case none
    /// I sent a request that is still pending.
    case outgoing
    /// They sent me a request that is still pending.
    case incoming
    /// Accepted, in either direction.
    case friends
    /// One party blocked the other. No UI acts on this yet.
    case blocked
    /// The row is the signed-in user. Renders no action at all.
    case isSelf = "self"

    /// Unknown values decode to `.none` rather than throwing.
    ///
    /// A future status added server-side should degrade one row to a plain "Add
    /// friend" button, not fail the decode of the whole search page.
    init(lenient raw: String?) {
        self = raw.flatMap(RelationshipState.init(rawValue:)) ?? .none
    }
}

// MARK: - search_profiles

struct ProfileSearchResult: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    var username: String?
    var displayName: String?
    var avatarURL: String?
    var bio: String?
    var relationship: RelationshipState
    /// The friendship row backing `relationship`, when there is one. Needed to
    /// accept, decline, cancel or unfriend straight from a search row without a
    /// second lookup.
    var friendshipID: UUID?

    var person: PersonSummary {
        PersonSummary(id: id, username: username, displayName: displayName, avatarURL: avatarURL)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName  = "display_name"
        case avatarURL    = "avatar_url"
        case bio
        case relationship
        case friendshipID = "friendship_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        relationship = RelationshipState(
            lenient: try container.decodeIfPresent(String.self, forKey: .relationship)
        )
        friendshipID = try container.decodeIfPresent(UUID.self, forKey: .friendshipID)
    }
}

// MARK: - friendship_edges

/// One friendship, flattened to "the other person + which way it points".
///
/// The server already resolved which column the caller sits in, so no view has
/// to ask "am I the requester here" — that question does not survive past the
/// API boundary.
struct FriendshipEdge: Decodable, Identifiable, Hashable, Sendable {
    enum Direction: String, Codable, Sendable {
        case outgoing
        case incoming
    }

    let friendshipID: UUID
    var status: FriendshipStatus
    var direction: Direction
    var createdAt: Date?
    var respondedAt: Date?

    /// The OTHER party. Never the caller.
    var userID: UUID
    var username: String?
    var displayName: String?
    var avatarURL: String?
    var bio: String?

    /// Identity is the friendship, not the person: the same person can appear
    /// only once, but keying on the row keeps SwiftUI stable if a request is
    /// declined and re-sent as a new row.
    var id: UUID { friendshipID }

    var person: PersonSummary {
        PersonSummary(id: userID, username: username, displayName: displayName, avatarURL: avatarURL)
    }

    var isAcceptedFriend: Bool { status == .accepted }
    var isIncomingRequest: Bool { status == .pending && direction == .incoming }
    var isOutgoingRequest: Bool { status == .pending && direction == .outgoing }

    enum CodingKeys: String, CodingKey {
        case friendshipID = "friendship_id"
        case status
        case direction
        case createdAt    = "created_at"
        case respondedAt  = "responded_at"
        case userID       = "user_id"
        case username
        case displayName  = "display_name"
        case avatarURL    = "avatar_url"
        case bio
    }
}

// MARK: - visits_in_bounds

/// A photo belonging to a friend's visit.
///
/// Arrives as a `jsonb` array inlined in the visit row rather than as a second
/// request. Only the fields a carousel needs — there is no editing of someone
/// else's photo, so width/height/EXIF would be dead weight over the wire.
struct FriendVisitPhoto: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    var storagePath: String
    var thumbPath: String?
    var sortOrder: Int

    /// Prefers the thumbnail, falls back to the full image — same rule as
    /// `RemoteVisitPhoto.smallestPath`, so a photo whose thumb upload failed
    /// still renders.
    var smallestPath: String { thumbPath ?? storagePath }

    enum CodingKeys: String, CodingKey {
        case id
        case storagePath = "storage_path"
        case thumbPath   = "thumb_path"
        case sortOrder   = "sort_order"
    }
}

/// A person tagged in someone's visit, as the `tagged` jsonb array carries them.
///
/// Its own type rather than decoding straight into `PersonSummary` because the
/// identity column upstream is `user_id`, not `id` — `PersonSummary` is an app
/// type shared by half a dozen surfaces and does not get reshaped to match one
/// RPC's column naming.
struct TaggedPerson: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    var username: String?
    var displayName: String?
    var avatarURL: String?

    var person: PersonSummary {
        PersonSummary(id: id, username: username, displayName: displayName, avatarURL: avatarURL)
    }

    enum CodingKeys: String, CodingKey {
        case id          = "user_id"
        case username
        case displayName = "display_name"
        case avatarURL   = "avatar_url"
    }
}

/// One visit as returned by `visits_in_bounds` — the visit, its place, and its
/// author, denormalised into a flat row.
struct FriendVisit: Decodable, Identifiable, Hashable, Sendable {
    let visitID: UUID
    var visitedAt: Date
    var title: String?
    var summary: String?
    var transcript: String?
    var topQuote: String?
    var tags: [String]
    var ratingLabel: String?
    var returnIntent: String?
    /// `visited` | `wantToTry`.
    var kind: String

    var placeID: UUID
    var placeName: String
    var placeCategory: String?
    var neighborhood: String?
    var streetAddress: String?
    var latitude: Double
    var longitude: Double

    var userID: UUID
    var username: String?
    var displayName: String?
    var avatarURL: String?

    var photos: [FriendVisitPhoto]
    /// People the author said were there. Empty for a visit with nobody tagged,
    /// and empty on any server that predates the `visit_tags` migration.
    var tagged: [TaggedPerson]

    var id: UUID { visitID }

    var person: PersonSummary {
        PersonSummary(id: userID, username: username, displayName: displayName, avatarURL: avatarURL)
    }

    /// Falls back to `.other` on an unrecognised category, matching how the sync
    /// engine maps `places.category` onto the local enum.
    var category: PlaceCategory {
        placeCategory.flatMap(PlaceCategory.init(rawValue:)) ?? .other
    }

    var visitKind: VisitKind {
        VisitKind(rawValue: kind) ?? .visited
    }

    var rating: Rating? {
        Rating.from(loose: ratingLabel)
    }

    /// Best heading for the entry: the author's own title, else the venue name.
    var headline: String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return placeName
    }

    /// The shared venue behind this visit — enough to save or send it.
    var placeSummary: PlaceSummary {
        PlaceSummary(
            id: placeID,
            name: placeName,
            categoryRaw: placeCategory,
            neighborhood: neighborhood,
            streetAddress: streetAddress,
            latitude: latitude,
            longitude: longitude
        )
    }

    enum CodingKeys: String, CodingKey {
        case visitID       = "visit_id"
        case visitedAt     = "visited_at"
        case title
        case summary
        case transcript
        case topQuote      = "top_quote"
        case tags
        case ratingLabel   = "rating_label"
        case returnIntent  = "return_intent"
        case kind
        case placeID       = "place_id"
        case placeName     = "place_name"
        case placeCategory = "place_category"
        case neighborhood
        case streetAddress = "street_address"
        case latitude
        case longitude
        case userID        = "user_id"
        case username
        case displayName   = "display_name"
        case avatarURL     = "avatar_url"
        case photos
        case tagged
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visitID = try container.decode(UUID.self, forKey: .visitID)
        visitedAt = try container.decode(Date.self, forKey: .visitedAt)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        topQuote = try container.decodeIfPresent(String.self, forKey: .topQuote)
        // Defensive default, same reasoning as RemoteVisitWithRelations: one
        // unexpected null must not fail an entire page of map results.
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        ratingLabel = try container.decodeIfPresent(String.self, forKey: .ratingLabel)
        returnIntent = try container.decodeIfPresent(String.self, forKey: .returnIntent)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "visited"
        placeID = try container.decode(UUID.self, forKey: .placeID)
        placeName = try container.decode(String.self, forKey: .placeName)
        placeCategory = try container.decodeIfPresent(String.self, forKey: .placeCategory)
        neighborhood = try container.decodeIfPresent(String.self, forKey: .neighborhood)
        streetAddress = try container.decodeIfPresent(String.self, forKey: .streetAddress)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        userID = try container.decode(UUID.self, forKey: .userID)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        photos = try container.decodeIfPresent([FriendVisitPhoto].self, forKey: .photos) ?? []
        tagged = try container.decodeIfPresent([TaggedPerson].self, forKey: .tagged) ?? []
    }
}

// MARK: - friend_profile

/// Header + stats for someone else's profile.
///
/// `isFriend` exists for the action button only. Nothing on the profile is
/// gated on it — every field here is world-readable by design, and adding a
/// permission branch would be inventing a privacy model the schema does not have.
struct FriendProfileSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    var username: String?
    var displayName: String?
    var avatarURL: String?
    var bio: String?
    var isFriend: Bool
    var isSelf: Bool
    var visitCount: Int
    var wantToTryCount: Int
    var placeCount: Int
    var firstVisitAt: Date?
    var lastVisitAt: Date?

    var person: PersonSummary {
        PersonSummary(id: id, username: username, displayName: displayName, avatarURL: avatarURL)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName    = "display_name"
        case avatarURL      = "avatar_url"
        case bio
        case isFriend       = "is_friend"
        case isSelf         = "is_self"
        case visitCount     = "visit_count"
        case wantToTryCount = "want_to_try_count"
        case placeCount     = "place_count"
        case firstVisitAt   = "first_visit_at"
        case lastVisitAt    = "last_visit_at"
    }
}

// MARK: - RPC parameter payloads

/// Arguments for `visits_in_bounds`.
///
/// `resultLimit`, not `limit`: the SQL parameter is renamed because `limit` is a
/// reserved word that would need quoting at every call site.
struct VisitsInBoundsParams: Encodable, Sendable {
    var minLat: Double
    var maxLat: Double
    var minLng: Double
    var maxLng: Double
    /// `nil` means "the caller and their friends", resolved server-side with
    /// `friend_ids()`.
    var userIDs: [UUID]?
    var resultLimit: Int

    enum CodingKeys: String, CodingKey {
        case minLat      = "min_lat"
        case maxLat      = "max_lat"
        case minLng      = "min_lng"
        case maxLng      = "max_lng"
        case userIDs     = "user_ids"
        case resultLimit = "result_limit"
    }
}

struct SearchProfilesParams: Encodable, Sendable {
    var query: String
    var limit: Int

    enum CodingKeys: String, CodingKey {
        case query = "p_query"
        case limit = "p_limit"
    }
}

/// Arguments for `user_visits` and `tagged_visits` — the two RPCs share a
/// signature as well as a return shape.
struct UserVisitsParams: Encodable, Sendable {
    var user: UUID
    var limit: Int

    enum CodingKeys: String, CodingKey {
        case user  = "p_user"
        case limit = "p_limit"
    }
}

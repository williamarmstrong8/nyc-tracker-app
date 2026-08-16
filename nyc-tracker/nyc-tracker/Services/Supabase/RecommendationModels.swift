import Foundation

// ============================================================================
// DTOs for 20260816000300_recommendations_and_wishlist.sql.
// ============================================================================
// Same rules as SocialModels.swift: wire shapes for function results, explicit
// CodingKeys, never persisted to SwiftData.
//
// Wishlist and recommendation rows are the user's OWN data, unlike friend
// visits — so in principle they could live in the local store. They don't, and
// that is a considered choice: they are small, they change from other people's
// actions (a friend sends you a place while your app is closed), and the local
// store's whole value is offline authorship of things the user typed. A pointer
// someone else created has no offline authorship to protect. Mirroring them
// would mean a second sync loop, a second conflict story, and a second
// sign-out cleanup path for data that is one indexed query away.
// ============================================================================

// MARK: - Sending

/// What happened for one recipient of a `recommend_place` call.
///
/// Every case is a normal outcome, not an error — which is why the RPC returns
/// rows instead of raising. A batch send to five friends where two already have
/// the place should still succeed for the other three.
enum RecommendationOutcome: String, Decodable, Sendable {
    /// New recommendation; the place was added to their wishlist.
    case sent
    /// `(sender, recipient, place)` already exists. The anti-spam constraint
    /// doing its job — shown as "already sent", never as a failure.
    case alreadySent = "already_sent"
    /// Sent, but they have already been. The wishlist item was created already
    /// resolved against their existing visit.
    case alreadyVisited = "already_visited"
    /// Not an accepted friend. Unreachable from the picker, which only offers
    /// friends; enforced server-side because `recommendations` is the one table
    /// a stranger could otherwise write into a private inbox.
    case notFriends = "not_friends"
    case isSelf = "self"

    /// Unknown values degrade to `.sent` rather than throwing — the row was
    /// created either way, and failing the decode would lose the whole batch.
    init(lenient raw: String?) {
        self = raw.flatMap(RecommendationOutcome.init(rawValue:)) ?? .sent
    }

    /// Did this recipient end up with the recommendation, however it got there?
    var didDeliver: Bool {
        switch self {
        case .sent, .alreadyVisited, .alreadySent: true
        case .notFriends, .isSelf:                 false
        }
    }
}

struct RecommendationSendResult: Decodable, Identifiable, Sendable {
    let recipientID: UUID
    var outcome: RecommendationOutcome
    var recommendationID: UUID?

    var id: UUID { recipientID }

    enum CodingKeys: String, CodingKey {
        case recipientID     = "recipient_id"
        case outcome
        case recommendationID = "recommendation_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recipientID = try container.decode(UUID.self, forKey: .recipientID)
        outcome = RecommendationOutcome(
            lenient: try container.decodeIfPresent(String.self, forKey: .outcome)
        )
        recommendationID = try container.decodeIfPresent(UUID.self, forKey: .recommendationID)
    }
}

struct RecommendPlaceParams: Encodable, Sendable {
    var place: UUID
    var recipients: [UUID]
    var message: String?

    enum CodingKeys: String, CodingKey {
        case place      = "p_place"
        case recipients = "p_recipients"
        case message    = "p_message"
    }
}

// MARK: - Place summary

/// The venue fields every social RPC returns alongside its payload.
///
/// Broken out because four different results carry the same seven columns, and
/// a place that renders differently on the inbox row than on the wishlist row
/// is a bug waiting to be reported as "the category is wrong on one screen".
struct PlaceSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var categoryRaw: String?
    var neighborhood: String?
    var streetAddress: String?
    var latitude: Double
    var longitude: Double

    var category: PlaceCategory {
        categoryRaw.flatMap(PlaceCategory.init(rawValue:)) ?? .other
    }

    var subtitle: String? {
        let parts = [streetAddress, neighborhood].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Recommender

/// Someone who sent you a place, and what they said about it.
struct Recommender: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    var username: String?
    var displayName: String?
    var avatarURL: String?
    var message: String?
    var createdAt: Date?

    var person: PersonSummary {
        PersonSummary(id: id, username: username, displayName: displayName, avatarURL: avatarURL)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
        case avatarURL   = "avatar_url"
        case message
        case createdAt   = "created_at"
    }
}

extension Array where Element == Recommender {
    /// "Sarah", "Sarah and Dev", "Sarah and 2 others".
    ///
    /// Names the first person rather than showing a bare count, because the
    /// useful part of a recommendation is who it came from.
    var attributionText: String? {
        guard let first = self.first else { return nil }
        switch count {
        case 1:  return first.person.shortName
        case 2:  return "\(first.person.shortName) and \(self[1].person.shortName)"
        default: return "\(first.person.shortName) and \(pluralized(count - 1, "other"))"
        }
    }
}

// MARK: - Inbox recommendation

struct InboxRecommendation: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    var status: RecommendationStatus
    var message: String?
    var createdAt: Date?
    var readAt: Date?

    var senderID: UUID
    var username: String?
    var displayName: String?
    var avatarURL: String?

    var place: PlaceSummary
    /// The recipient has logged a visit here. Drives the "you've already been"
    /// note, so the sender's gesture still lands somewhere meaningful.
    var alreadyVisited: Bool
    var onWishlist: Bool

    var isUnread: Bool { status == .unread }

    var sender: PersonSummary {
        PersonSummary(id: senderID, username: username, displayName: displayName, avatarURL: avatarURL)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case message
        case createdAt      = "created_at"
        case readAt         = "read_at"
        case senderID       = "sender_id"
        case username
        case displayName    = "display_name"
        case avatarURL      = "avatar_url"
        case placeID        = "place_id"
        case placeName      = "place_name"
        case placeCategory  = "place_category"
        case neighborhood
        case streetAddress  = "street_address"
        case latitude
        case longitude
        case alreadyVisited = "already_visited"
        case onWishlist     = "on_wishlist"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        status = (try? container.decode(RecommendationStatus.self, forKey: .status)) ?? .unread
        message = try container.decodeIfPresent(String.self, forKey: .message)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        readAt = try container.decodeIfPresent(Date.self, forKey: .readAt)
        senderID = try container.decode(UUID.self, forKey: .senderID)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        place = PlaceSummary(
            id: try container.decode(UUID.self, forKey: .placeID),
            name: try container.decode(String.self, forKey: .placeName),
            categoryRaw: try container.decodeIfPresent(String.self, forKey: .placeCategory),
            neighborhood: try container.decodeIfPresent(String.self, forKey: .neighborhood),
            streetAddress: try container.decodeIfPresent(String.self, forKey: .streetAddress),
            latitude: try container.decode(Double.self, forKey: .latitude),
            longitude: try container.decode(Double.self, forKey: .longitude)
        )
        alreadyVisited = try container.decodeIfPresent(Bool.self, forKey: .alreadyVisited) ?? false
        onWishlist = try container.decodeIfPresent(Bool.self, forKey: .onWishlist) ?? false
    }
}

// MARK: - Wishlist

struct WishlistEntry: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    var place: PlaceSummary
    var sourceRaw: String
    var createdAt: Date?
    /// Non-nil once the user actually went. The row is kept rather than deleted,
    /// so "wanted to go → went" stays visible.
    var resolvedVisitID: UUID?
    var resolvedAt: Date?
    var recommenders: [Recommender]

    var isResolved: Bool { resolvedVisitID != nil }
    var source: WishlistSource { WishlistSource(rawValue: sourceRaw) ?? .manual }

    enum CodingKeys: String, CodingKey {
        case id
        case placeID         = "place_id"
        case placeName       = "place_name"
        case placeCategory   = "place_category"
        case neighborhood
        case streetAddress   = "street_address"
        case latitude
        case longitude
        case source
        case createdAt       = "created_at"
        case resolvedVisitID = "resolved_visit_id"
        case resolvedAt      = "resolved_at"
        case recommenders
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        place = PlaceSummary(
            id: try container.decode(UUID.self, forKey: .placeID),
            name: try container.decode(String.self, forKey: .placeName),
            categoryRaw: try container.decodeIfPresent(String.self, forKey: .placeCategory),
            neighborhood: try container.decodeIfPresent(String.self, forKey: .neighborhood),
            streetAddress: try container.decodeIfPresent(String.self, forKey: .streetAddress),
            latitude: try container.decode(Double.self, forKey: .latitude),
            longitude: try container.decode(Double.self, forKey: .longitude)
        )
        sourceRaw = try container.decodeIfPresent(String.self, forKey: .source) ?? "manual"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        resolvedVisitID = try container.decodeIfPresent(UUID.self, forKey: .resolvedVisitID)
        resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
        recommenders = try container.decodeIfPresent([Recommender].self, forKey: .recommenders) ?? []
    }
}

// MARK: - Feed

/// One explore-feed entry: a friend's visit plus how many friends know the place.
///
/// Wraps `FriendVisit` rather than redeclaring twenty fields — `friend_feed`
/// returns the same columns as `visits_in_bounds` with one extra, and keeping
/// them structurally identical means the feed card and the place sheet render
/// from the same type.
struct FeedItem: Decodable, Identifiable, Sendable {
    var visit: FriendVisit
    /// Distinct friends who have been to this place — not visit count. One
    /// friend who goes weekly is one friend.
    var friendPlaceCount: Int

    var id: UUID { visit.visitID }

    private enum CodingKeys: String, CodingKey {
        case friendPlaceCount = "friend_place_count"
    }

    init(from decoder: any Decoder) throws {
        visit = try FriendVisit(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        friendPlaceCount = try container.decodeIfPresent(Int.self, forKey: .friendPlaceCount) ?? 0
    }
}

struct FriendFeedParams: Encodable, Sendable {
    var cursorVisitedAt: Date?
    var cursorID: UUID?
    var limit: Int

    enum CodingKeys: String, CodingKey {
        case cursorVisitedAt = "p_cursor_visited_at"
        case cursorID        = "p_cursor_id"
        case limit           = "p_limit"
    }

    /// `encode`, not `encodeIfPresent`: the first page has to send explicit
    /// nulls. Omitting the keys would fall back to the SQL defaults, which are
    /// also null — but relying on that couples the client to a default it
    /// cannot see.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cursorVisitedAt, forKey: .cursorVisitedAt)
        try container.encode(cursorID, forKey: .cursorID)
        try container.encode(limit, forKey: .limit)
    }
}

// MARK: - Social stats

/// A friend who has been to a place, with how often.
struct PlaceVisitor: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    var username: String?
    var displayName: String?
    var avatarURL: String?
    var visitCount: Int

    var person: PersonSummary {
        PersonSummary(id: id, username: username, displayName: displayName, avatarURL: avatarURL)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
        case avatarURL   = "avatar_url"
        case visitCount  = "visit_count"
    }
}

struct PlaceSocial: Decodable, Sendable {
    var placeID: UUID
    /// Total visits by friends.
    var friendVisitCount: Int
    /// Distinct friends. This is the number to show — "3 friends have been here".
    var friendPlaceCount: Int
    var friends: [PlaceVisitor]
    var iHaveVisited: Bool
    var onMyWishlist: Bool
    var wishlistItemID: UUID?
    var recommenders: [Recommender]

    enum CodingKeys: String, CodingKey {
        case placeID          = "place_id"
        case friendVisitCount = "friend_visit_count"
        case friendPlaceCount = "friend_place_count"
        case friends
        case iHaveVisited     = "i_have_visited"
        case onMyWishlist     = "on_my_wishlist"
        case wishlistItemID   = "wishlist_item_id"
        case recommenders
    }
}

struct CommonPlace: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var category: String?
}

struct FriendOverlap: Decodable, Sendable {
    var userID: UUID
    var placesInCommon: Int
    var commonPlaces: [CommonPlace]

    enum CodingKeys: String, CodingKey {
        case userID         = "user_id"
        case placesInCommon = "places_in_common"
        case commonPlaces   = "common_places"
    }
}

/// A place friends rate that the user hasn't been to.
struct GapPlace: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var category: String?
    var neighborhood: String?
    var latitude: Double
    var longitude: Double
    var friendCount: Int

    var placeCategory: PlaceCategory {
        category.flatMap(PlaceCategory.init(rawValue:)) ?? .other
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case neighborhood
        case latitude
        case longitude
        case friendCount = "friend_count"
    }
}

struct OwnSocialStats: Decodable, Sendable {
    var friendCount: Int
    var gapCount: Int
    var gapPlaces: [GapPlace]

    enum CodingKeys: String, CodingKey {
        case friendCount = "friend_count"
        case gapCount    = "gap_count"
        case gapPlaces   = "gap_places"
    }
}

import Foundation

// ============================================================================
// DTOs for 20260816000400_direct_messages.sql.
// ============================================================================
// Same rules as SocialModels.swift and RecommendationModels.swift: wire shapes
// only, explicit CodingKeys, never persisted to SwiftData.
//
// Messages are emphatically NOT mirrored locally. The local store exists to
// protect offline authorship — a write-up the user dictated on the subway has
// to survive with no network. A message is the opposite: it is worthless until
// it reaches the other person, so there is nothing to protect by queueing it,
// and a "sent" bubble that is actually sitting in a local table is a lie the
// user will act on.
// ============================================================================

// MARK: - conversation_threads

/// One thread in the list: who it's with, what was said last, how much of it is
/// unread.
///
/// Only threads that exist come back from the server, so the friends list treats
/// a missing thread as "never messaged" rather than as an empty conversation.
struct ConversationThread: Decodable, Identifiable, Hashable, Sendable {
    let conversationID: UUID

    /// The OTHER participant. Never the caller — the server already resolved
    /// which side of the pair that is.
    var userID: UUID
    var username: String?
    var displayName: String?
    var avatarURL: String?

    var createdAt: Date?
    /// Nil for a thread that was opened but never used. Sorts last.
    var lastMessageAt: Date?
    var lastMessageBody: String?
    var lastMessageSenderID: UUID?
    /// The venue attached to the last message, for a preview line that reads
    /// "Lucali · still the best" rather than just the note.
    var lastMessagePlaceName: String?

    /// Messages from the other person since the caller's read cursor.
    var unreadCount: Int

    var id: UUID { conversationID }

    var person: PersonSummary {
        PersonSummary(id: userID, username: username, displayName: displayName, avatarURL: avatarURL)
    }

    var hasUnread: Bool { unreadCount > 0 }

    /// The one-line preview under a name in the friends list.
    ///
    /// Venue first when there is one: in a product where every message is about
    /// a place, the place is the subject and the note is the comment on it.
    var preview: String? {
        let body = lastMessageBody?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (lastMessagePlaceName, body) {
        case let (place?, note?) where !place.isEmpty && !note.isEmpty:
            return "\(place) · \(note)"
        case let (place?, _) where !place.isEmpty:
            return place
        case let (_, note?) where !note.isEmpty:
            return note
        default:
            return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case conversationID       = "conversation_id"
        case userID               = "user_id"
        case username
        case displayName          = "display_name"
        case avatarURL            = "avatar_url"
        case createdAt            = "created_at"
        case lastMessageAt        = "last_message_at"
        case lastMessageBody      = "last_message_body"
        case lastMessageSenderID  = "last_message_sender_id"
        case lastMessagePlaceName = "last_message_place_name"
        case unreadCount          = "unread_count"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try container.decode(UUID.self, forKey: .conversationID)
        userID = try container.decode(UUID.self, forKey: .userID)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        lastMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        lastMessageBody = try container.decodeIfPresent(String.self, forKey: .lastMessageBody)
        lastMessageSenderID = try container.decodeIfPresent(UUID.self, forKey: .lastMessageSenderID)
        lastMessagePlaceName = try container.decodeIfPresent(String.self, forKey: .lastMessagePlaceName)
        // Defensive default, same reasoning as `FriendVisit.tags`: one
        // unexpected null must not fail the decode of the whole thread list and
        // blank the friends page.
        unreadCount = try container.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0
    }
}

// MARK: - message_details

/// One message, with everything its card needs already joined on.
///
/// `place` is optional because the column is: the schema allows a plain note
/// even though today's composer never sends one. The card branches on it rather
/// than assuming a venue is always there.
struct ChatMessage: Decodable, Identifiable, Hashable, Sendable {
    let id: UUID
    var conversationID: UUID
    var senderID: UUID
    var body: String
    var createdAt: Date

    var username: String?
    var displayName: String?
    var avatarURL: String?

    var place: PlaceSummary?
    /// The sender's own visit being shared, when they picked one from their log.
    /// Nil once that visit is deleted — the message survives it.
    var visitID: UUID?
    var visitTitle: String?
    var visitTags: [String]
    var ratingLabel: String?

    /// The shared visit's photos, or the sender's most recent photos of the same
    /// venue. Inlined by the view so a card draws as soon as its row arrives.
    var photos: [FriendVisitPhoto]

    var sender: PersonSummary {
        PersonSummary(id: senderID, username: username, displayName: displayName, avatarURL: avatarURL)
    }

    var rating: Rating? { Rating.from(loose: ratingLabel) }

    /// Best heading for the attached place: the sender's own title for the
    /// visit, else the venue name. Matches `FriendVisit.headline`.
    var placeHeadline: String? {
        guard let place else { return nil }
        if let visitTitle, !visitTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return visitTitle
        }
        return place.name
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case senderID       = "sender_id"
        case body
        case createdAt      = "created_at"
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
        case visitID        = "visit_id"
        case visitTitle     = "visit_title"
        case visitTags      = "visit_tags"
        case ratingLabel    = "visit_rating_label"
        case photos
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        conversationID = try container.decode(UUID.self, forKey: .conversationID)
        senderID = try container.decode(UUID.self, forKey: .senderID)
        body = try container.decode(String.self, forKey: .body)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)

        // The place is a LEFT JOIN, so every one of its columns is nullable in
        // the result even though none of them are nullable on `places`. Built
        // only when the identity and the coordinate are both there — a
        // half-decoded venue would put a pin at (0, 0).
        if let placeID = try container.decodeIfPresent(UUID.self, forKey: .placeID),
           let placeName = try container.decodeIfPresent(String.self, forKey: .placeName),
           let latitude = try container.decodeIfPresent(Double.self, forKey: .latitude),
           let longitude = try container.decodeIfPresent(Double.self, forKey: .longitude) {
            place = PlaceSummary(
                id: placeID,
                name: placeName,
                categoryRaw: try container.decodeIfPresent(String.self, forKey: .placeCategory),
                neighborhood: try container.decodeIfPresent(String.self, forKey: .neighborhood),
                streetAddress: try container.decodeIfPresent(String.self, forKey: .streetAddress),
                latitude: latitude,
                longitude: longitude
            )
        } else {
            place = nil
        }

        visitID = try container.decodeIfPresent(UUID.self, forKey: .visitID)
        visitTitle = try container.decodeIfPresent(String.self, forKey: .visitTitle)
        visitTags = try container.decodeIfPresent([String].self, forKey: .visitTags) ?? []
        ratingLabel = try container.decodeIfPresent(String.self, forKey: .ratingLabel)
        photos = try container.decodeIfPresent([FriendVisitPhoto].self, forKey: .photos) ?? []
    }
}

// MARK: - RPC parameter payloads

struct SendMessageParams: Encodable, Sendable {
    var conversation: UUID
    var body: String
    var place: UUID?
    var visit: UUID?

    enum CodingKeys: String, CodingKey {
        case conversation = "p_conversation"
        case body         = "p_body"
        case place        = "p_place"
        case visit        = "p_visit"
    }

    /// `encode`, not `encodeIfPresent`, for the two optionals — matching
    /// `FriendFeedParams`. Omitting a key falls back to the SQL default, which
    /// is also null, but relying on that couples the client to a default it
    /// cannot see.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(body, forKey: .body)
        try container.encode(place, forKey: .place)
        try container.encode(visit, forKey: .visit)
    }
}

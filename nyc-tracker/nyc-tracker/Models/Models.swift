import Foundation
import CoreLocation
import SwiftData

// MARK: - Enums

enum PlaceCategory: String, Codable, CaseIterable, Sendable {
    case restaurant
    case bar
    case cafe
    case bakery
    case other
}

enum Rating: String, Codable, CaseIterable, Sendable, Identifiable {
    case loved
    case liked
    case fine
    case no

    var id: String { rawValue }

    var label: String {
        switch self {
        case .loved: "Loved"
        case .liked: "Liked"
        case .fine:  "Fine"
        case .no:    "No"
        }
    }

    var symbol: String {
        switch self {
        case .loved: "heart.fill"
        case .liked: "hand.thumbsup.fill"
        case .fine:  "hand.raised.fill"
        case .no:    "hand.thumbsdown.fill"
        }
    }

    /// Map a free-form model suggestion to a real Rating case; nil if it can't be reasonably mapped.
    static func from(loose text: String?) -> Rating? {
        guard let raw = text?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.contains("love") { return .loved }
        if raw.contains("like") || raw.contains("good") { return .liked }
        if raw.contains("fine") || raw.contains("ok") || raw.contains("meh") { return .fine }
        if raw.contains("no") || raw.contains("bad") || raw.contains("skip") { return .no }
        return nil
    }
}

enum ReturnIntent: String, Codable, CaseIterable, Sendable, Identifiable {
    case immediately
    case whenNearby
    case ifSuggested
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .immediately: "Immediately"
        case .whenNearby:  "When nearby"
        case .ifSuggested: "If suggested"
        case .never:       "Never"
        }
    }
}

enum LocationSource: String, Codable, Sendable {
    case photoGPS
    case device
    case manual
}

enum VisitKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case visited
    case wantToTry

    var id: String { rawValue }
    var label: String {
        switch self {
        case .visited:    "Visited"
        case .wantToTry:  "Want to try"
        }
    }
    var symbol: String {
        switch self {
        case .visited:    "checkmark.circle.fill"
        case .wantToTry:  "bookmark.fill"
        }
    }
}

// MARK: - SwiftData models

@Model
final class Place {
    @Attribute(.unique) var id: UUID
    var name: String
    var categoryRaw: String
    var neighborhood: String
    var lat: Double
    var lng: Double
    var externalPOIId: String?

    @Relationship(deleteRule: .cascade, inverse: \Visit.place)
    var visits: [Visit] = []

    init(
        id: UUID = UUID(),
        name: String,
        category: PlaceCategory,
        neighborhood: String,
        lat: Double,
        lng: Double,
        externalPOIId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.categoryRaw = category.rawValue
        self.neighborhood = neighborhood
        self.lat = lat
        self.lng = lng
        self.externalPOIId = externalPOIId
    }

    var category: PlaceCategory {
        get { PlaceCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

@Model
final class Visit {
    @Attribute(.unique) var id: UUID
    var visitedOn: Date
    var title: String
    var tags: [String]
    var enrichedDescription: String
    /// Verbatim transcript from the user's voice note. Never overwritten by enrichment.
    var transcript: String
    var topQuote: String
    var ratingRaw: String?
    var returnIntentRaw: String?
    var address: String?
    var nameOverride: String?
    var locationSourceRaw: String
    var published: Bool
    var createdAt: Date
    /// Path relative to Application Support, if a voice note was captured.
    var audioRelativePath: String?
    /// The model's best guess of the raw place name if the venue picker was not used.
    var rawPlaceGuess: String?
    /// Whether the entry represents an actual visit or a "want to try" bookmark.
    var kindRaw: String = VisitKind.visited.rawValue

    @Relationship var place: Place?

    @Relationship(deleteRule: .cascade, inverse: \Photo.visit)
    var photos: [Photo] = []

    init(
        id: UUID = UUID(),
        visitedOn: Date = Date(),
        title: String,
        tags: [String] = [],
        enrichedDescription: String = "",
        transcript: String = "",
        topQuote: String = "",
        rating: Rating? = nil,
        returnIntent: ReturnIntent? = nil,
        address: String? = nil,
        nameOverride: String? = nil,
        locationSource: LocationSource = .manual,
        published: Bool = false,
        createdAt: Date = Date(),
        audioRelativePath: String? = nil,
        rawPlaceGuess: String? = nil,
        kind: VisitKind = .visited,
        place: Place? = nil
    ) {
        self.id = id
        self.visitedOn = visitedOn
        self.title = title
        self.tags = tags
        self.enrichedDescription = enrichedDescription
        self.transcript = transcript
        self.topQuote = topQuote
        self.ratingRaw = rating?.rawValue
        self.returnIntentRaw = returnIntent?.rawValue
        self.address = address
        self.nameOverride = nameOverride
        self.locationSourceRaw = locationSource.rawValue
        self.published = published
        self.createdAt = createdAt
        self.audioRelativePath = audioRelativePath
        self.rawPlaceGuess = rawPlaceGuess
        self.kindRaw = kind.rawValue
        self.place = place
    }

    var kind: VisitKind {
        get { VisitKind(rawValue: kindRaw) ?? .visited }
        set { kindRaw = newValue.rawValue }
    }

    var rating: Rating? {
        get { ratingRaw.flatMap(Rating.init(rawValue:)) }
        set { ratingRaw = newValue?.rawValue }
    }

    var returnIntent: ReturnIntent? {
        get { returnIntentRaw.flatMap(ReturnIntent.init(rawValue:)) }
        set { returnIntentRaw = newValue?.rawValue }
    }

    var locationSource: LocationSource {
        get { LocationSource(rawValue: locationSourceRaw) ?? .manual }
        set { locationSourceRaw = newValue.rawValue }
    }
}

@Model
final class Photo {
    @Attribute(.unique) var id: UUID
    /// Path (relative to Application Support) of the on-disk copy of the photo.
    var relativePath: String?
    /// PHAsset local identifier if the source is the user's photo library.
    var assetLocalIdentifier: String?
    /// Ordering within a visit (0 = first).
    var order: Int
    /// SF Symbol placeholder for seeded / stub content.
    var sfSymbol: String?

    @Relationship var visit: Visit?

    init(
        id: UUID = UUID(),
        relativePath: String? = nil,
        assetLocalIdentifier: String? = nil,
        order: Int = 0,
        sfSymbol: String? = nil,
        visit: Visit? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.assetLocalIdentifier = assetLocalIdentifier
        self.order = order
        self.sfSymbol = sfSymbol
        self.visit = visit
    }

    var isSFSymbolPlaceholder: Bool { sfSymbol != nil }
}

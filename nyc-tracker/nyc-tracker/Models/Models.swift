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

/// Where a local row stands relative to the cloud.
///
/// The local store is a mirror plus a write-ahead queue; Supabase is the source
/// of truth. This enum is the queue's state machine, and it only ever moves in
/// one direction per attempt: `pendingUpload -> uploading -> synced | failed`,
/// with `failed` returning to `pendingUpload` when a retry is scheduled.
///
/// `uploading` is persisted rather than kept in memory on purpose. If the app is
/// killed mid-upload the row is found in `uploading` on next launch, which is
/// exactly the signal that an attempt was interrupted — see
/// `SyncEngine.recoverInterruptedUploads()`.
enum SyncState: String, Codable, CaseIterable, Sendable {
    case pendingUpload
    case uploading
    case synced
    case failed

    /// Rows the user would lose if the local store were discarded.
    var isUnsent: Bool { self != .synced }
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

    /// The `places.id` this row resolved to, once `find_or_create_place()` has
    /// been called for it.
    ///
    /// This is the one identifier that genuinely differs between local and
    /// remote. `Visit.id` and `Photo.id` are generated on device and used
    /// verbatim as primary keys upstream, but a place is *deduped server-side* —
    /// two users photographing the same restaurant, or the same user logging it
    /// from two devices, produce different local `Place` rows that all collapse
    /// onto one remote row. So the mapping has to be stored, not assumed.
    ///
    /// Caching it also means a re-sync of a second visit to the same venue skips
    /// the RPC entirely.
    var remotePlaceID: UUID?

    /// Set when the user corrects `category` locally after the place has
    /// already synced (e.g. Apple's MapKit classification mislabeled a
    /// restaurant as a cafe). `find_or_create_place()` never overwrites an
    /// existing `places.category`, so a correction needs its own push via
    /// `update_place_category()` — this flag is what tells `SyncEngine` a
    /// place is waiting on that call. Irrelevant (and left `false`) for a
    /// place that hasn't synced yet, since its first upload already carries
    /// the corrected value.
    var categorySyncPending: Bool = false

    /// Which signed-in user's mirror this row belongs to.
    ///
    /// Places are shared and public upstream; locally they are partitioned per
    /// user so that two accounts on one device never see each other's data. The
    /// cost is a duplicate `Place` row per user for a shared venue, which is a
    /// few hundred bytes and keeps every query a single predicate on one field.
    ///
    /// `nil` means "captured before auth existed" — see `LegacyDataMigrator`.
    var ownerUserID: UUID?

    @Relationship(deleteRule: .cascade, inverse: \Visit.place)
    var visits: [Visit] = []

    init(
        id: UUID = UUID(),
        name: String,
        category: PlaceCategory,
        neighborhood: String,
        lat: Double,
        lng: Double,
        externalPOIId: String? = nil,
        remotePlaceID: UUID? = nil,
        ownerUserID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.categoryRaw = category.rawValue
        self.neighborhood = neighborhood
        self.lat = lat
        self.lng = lng
        self.externalPOIId = externalPOIId
        self.remotePlaceID = remotePlaceID
        self.ownerUserID = ownerUserID
    }

    var category: PlaceCategory {
        get { PlaceCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// User-initiated correction to the venue's category (e.g. "this is a
    /// restaurant, not a cafe"). Queues the change for `SyncEngine` to push via
    /// `update_place_category()` if this place has already synced.
    func correctCategory(to newCategory: PlaceCategory) {
        guard newCategory != category else { return }
        category = newCategory
        if remotePlaceID != nil {
            categorySyncPending = true
        }
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
    /// True if a voice note was recorded for this entry.
    ///
    /// Replaces the old `audioRelativePath`. The audio file is deleted the moment
    /// transcription finishes — the transcript is the only record kept, and
    /// nothing about the recording is ever uploaded. This flag exists purely so
    /// the "Voice notes" profile stat still has something to count.
    var hadVoiceNote: Bool = false
    /// The model's best guess of the raw place name if the venue picker was not used.
    var rawPlaceGuess: String?
    /// Whether the entry represents an actual visit or a "want to try" bookmark.
    var kindRaw: String = VisitKind.visited.rawValue

    // MARK: Sync

    /// Which signed-in user owns this row. `nil` = captured before auth existed.
    ///
    /// Every query in the app filters on this. It is the whole of the cross-user
    /// scoping story, which is why it is checked in one place
    /// (`LocalStore.scope(for:)`) rather than spelled out at each call site.
    var ownerUserID: UUID?

    /// The `visits.id` upstream. Equal to `id` by construction, always.
    ///
    /// Stored rather than assumed because the *reason* it is equal is load
    /// bearing and worth making visible: the upload is a four-step sequence
    /// (resolve place, upload photos, upsert visit, upsert photo rows) and any
    /// step can fail after an earlier one committed. With a client-generated id
    /// a retry is an idempotent upsert that converges on the same row. With a
    /// server-generated id, a retry that resumes after a partially-succeeded
    /// insert has no way to name the row it already created, and makes a second
    /// one. Every duplicate-visit bug in this design starts with giving that
    /// decision away to Postgres.
    var remoteID: UUID?

    var syncStateRaw: String = SyncState.pendingUpload.rawValue
    var lastSyncedAt: Date?
    /// Human-readable reason the last attempt failed. Shown in the retry UI.
    var syncError: String?
    /// Consecutive failures, used to size the backoff. Reset on success.
    var syncAttemptCount: Int = 0
    /// Earliest time the next attempt may run. `nil` = eligible now.
    var nextAttemptAt: Date?

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
        hadVoiceNote: Bool = false,
        rawPlaceGuess: String? = nil,
        kind: VisitKind = .visited,
        ownerUserID: UUID? = nil,
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
        self.hadVoiceNote = hadVoiceNote
        self.rawPlaceGuess = rawPlaceGuess
        self.kindRaw = kind.rawValue
        self.ownerUserID = ownerUserID
        self.remoteID = id
        self.place = place
    }

    var kind: VisitKind {
        get { VisitKind(rawValue: kindRaw) ?? .visited }
        set { kindRaw = newValue.rawValue }
    }

    var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .pendingUpload }
        set { syncStateRaw = newValue.rawValue }
    }

    /// Flag this row as having local changes the cloud hasn't seen.
    ///
    /// Call after *any* user edit. Resetting the attempt counter is deliberate:
    /// a fresh edit is new work, and it should not inherit a long backoff earned
    /// by a previous version of the row that may have failed for a reason the
    /// edit just fixed (an over-long field, a bad character).
    func markDirty() {
        syncState = .pendingUpload
        syncError = nil
        syncAttemptCount = 0
        nextAttemptAt = nil
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
    /// Path (relative to Application Support) of the ~400px thumbnail.
    var thumbRelativePath: String?
    /// PHAsset local identifier if the source is the user's photo library.
    var assetLocalIdentifier: String?
    /// Ordering within a visit (0 = first).
    var order: Int
    /// SF Symbol placeholder for seeded / stub content.
    var sfSymbol: String?

    // MARK: Remote

    /// Object path inside the `visit-photos` bucket once uploaded, e.g.
    /// `{user_id}/{visit_id}/{photo_id}.jpg`. Non-nil means the bytes are up.
    ///
    /// Checked before re-uploading, which is what makes a resumed upload skip
    /// photos that already made it in a previous attempt.
    var remoteStoragePath: String?
    /// Object path of the uploaded thumbnail.
    var remoteThumbPath: String?

    // MARK: EXIF, read before the upload copy is stripped

    /// Capture time read out of the original's EXIF.
    ///
    /// This and the two coordinates below are lifted from the source image and
    /// written to the database *before* the uploaded copy is re-encoded (which
    /// drops all metadata). The location a photo was taken is not something to
    /// leave silently embedded in a file served from a public bucket, but it is
    /// genuinely useful — it is the evidence behind the resolved venue — so it
    /// belongs in a row governed by RLS instead.
    var capturedAt: Date?
    var exifLatitude: Double?
    var exifLongitude: Double?

    var pixelWidth: Int?
    var pixelHeight: Int?

    @Relationship var visit: Visit?

    init(
        id: UUID = UUID(),
        relativePath: String? = nil,
        thumbRelativePath: String? = nil,
        assetLocalIdentifier: String? = nil,
        order: Int = 0,
        sfSymbol: String? = nil,
        remoteStoragePath: String? = nil,
        remoteThumbPath: String? = nil,
        capturedAt: Date? = nil,
        exifLatitude: Double? = nil,
        exifLongitude: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        visit: Visit? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.thumbRelativePath = thumbRelativePath
        self.assetLocalIdentifier = assetLocalIdentifier
        self.order = order
        self.sfSymbol = sfSymbol
        self.remoteStoragePath = remoteStoragePath
        self.remoteThumbPath = remoteThumbPath
        self.capturedAt = capturedAt
        self.exifLatitude = exifLatitude
        self.exifLongitude = exifLongitude
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.visit = visit
    }

    var isSFSymbolPlaceholder: Bool { sfSymbol != nil }
}

// MARK: - Deletion tombstone

/// A visit the user deleted locally that still has to be tombstoned upstream.
///
/// Deleting is expected to feel instant and to work offline, so the local `Visit`
/// row goes away immediately and this stands in for the unfinished remote half
/// of the job. Keeping it as its own tiny model — rather than a `isDeleted` flag
/// on `Visit` — means every query in the app stays a plain fetch with no
/// "...and not deleted" clause that someone will eventually forget to write.
///
/// Rows are created only for visits that actually reached the cloud. A visit
/// deleted before it ever uploaded has nothing upstream to tombstone, so it is
/// simply removed.
@Model
final class PendingDeletion {
    @Attribute(.unique) var visitID: UUID
    var ownerUserID: UUID?
    var requestedAt: Date
    var attemptCount: Int = 0
    var nextAttemptAt: Date?
    /// Storage object paths owned by the deleted visit, so the bucket can be
    /// cleaned up in the same pass rather than leaking orphans.
    var storagePaths: [String] = []

    init(
        visitID: UUID,
        ownerUserID: UUID?,
        requestedAt: Date = Date(),
        storagePaths: [String] = []
    ) {
        self.visitID = visitID
        self.ownerUserID = ownerUserID
        self.requestedAt = requestedAt
        self.storagePaths = storagePaths
    }
}

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

/// Did you like it or not. The whole verdict on a place.
///
/// This used to be a four-point scale (`loved` / `liked` / `fine` / `no`) with a
/// separate "would you return" question next to it. Two answers on a scale
/// nobody calibrates the same way twice is more precision than anyone has about
/// dinner, so it is one question now.
///
/// `notLiked` keeps `no` as its raw value: `visits.rating_label` carries a CHECK
/// constraint listing the four old labels, and reusing one of them is cheaper
/// than a migration for a column whose meaning didn't change. `Visit.rating`
/// reads through `from(loose:)` rather than `init(rawValue:)` so a row written
/// as `loved` still resolves instead of coming back empty.
enum Rating: String, Codable, CaseIterable, Sendable, Identifiable {
    case liked
    case notLiked = "no"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .liked:    "Liked it"
        case .notLiked: "Didn't like it"
        }
    }

    var symbol: String {
        switch self {
        case .liked:    "hand.thumbsup.fill"
        case .notLiked: "hand.thumbsdown.fill"
        }
    }

    /// Resolve a stored or free-form label to one of the two cases.
    ///
    /// Negatives are tested first because "not liked" contains "liked". `fine`
    /// and `meh` from the old scale return nil rather than being forced onto a
    /// side the user never picked.
    static func from(loose text: String?) -> Rating? {
        guard let raw = text?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasPrefix("no") || raw.contains("dislike") || raw.contains("bad") || raw.contains("skip") {
            return .notLiked
        }
        if raw.contains("love") || raw.contains("like") || raw.contains("good") {
            return .liked
        }
        return nil
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
    /// Raw `VenueTag` values the user picked. Free-form strings on the model
    /// rather than an enum array so a tag written before the vocabulary changed
    /// still round-trips instead of failing to decode.
    var tags: [String]
    /// What the user wrote — or dictated — about the place.
    ///
    /// The only body text on an entry. There used to be three fields here: a
    /// verbatim `transcript`, an `enrichedDescription` the on-device model wrote
    /// from it, and a `topQuote` it lifted out. With no model in the loop the
    /// distinction was only ever between the same sentence stored twice, so this
    /// keeps the column the app already displayed and drops the other two.
    @Attribute(originalName: "enrichedDescription") var note: String
    var ratingRaw: String?
    var address: String?
    var nameOverride: String?
    var locationSourceRaw: String
    var published: Bool
    var createdAt: Date
    /// True if a voice note was recorded for this entry.
    ///
    /// Replaces the old `audioRelativePath`. The audio file is deleted the moment
    /// transcription finishes — the dictated text in `note` is the only record
    /// kept, and nothing about the recording is ever uploaded. This flag exists
    /// purely so the "Voice notes" profile stat still has something to count.
    var hadVoiceNote: Bool = false
    /// What the user typed in the location field, kept even when the venue
    /// picker later resolved to something else.
    var rawPlaceGuess: String?
    /// Whether the entry represents an actual visit or a "want to try" bookmark.
    var kindRaw: String = VisitKind.visited.rawValue
    /// True when this row was created by `WantToTryMirror` from a wishlist save
    /// rather than typed by the user. Lets unsave remove a mirrored entry even
    /// after it picked up a friend's photos and note.
    var wishlistMirror: Bool = false

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

    /// People the author says were there with them.
    ///
    /// Mirrors `visit_tags` upstream. Each row carries the tagged person's name
    /// and avatar alongside their id — denormalised on purpose. The alternative
    /// is resolving ids against `SocialGraph` at render time, which is correct
    /// only while the friendship lasts: unfriend someone and every entry you
    /// were both in loses its label. A tag is a record of who was there, so it
    /// keeps the name it was written with until a sync replaces it.
    @Relationship(deleteRule: .cascade, inverse: \VisitTag.visit)
    var taggedPeople: [VisitTag] = []

    init(
        id: UUID = UUID(),
        visitedOn: Date = Date(),
        title: String,
        tags: [String] = [],
        note: String = "",
        rating: Rating? = nil,
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
        self.note = note
        self.ratingRaw = rating?.rawValue
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

    /// Read loosely so an entry rated on the old four-point scale still shows a
    /// verdict. Written back as the current raw value, so it converges the first
    /// time the user touches the entry.
    var rating: Rating? {
        get { Rating.from(loose: ratingRaw) }
        set { ratingRaw = newValue?.rawValue }
    }

    var locationSource: LocationSource {
        get { LocationSource(rawValue: locationSourceRaw) ?? .manual }
        set { locationSourceRaw = newValue.rawValue }
    }

    /// Tagged people in a stable order. SwiftData relationships are unordered
    /// sets, so anything user-visible has to sort explicitly or the row of
    /// avatars reshuffles between launches.
    var taggedPeopleOrdered: [VisitTag] {
        taggedPeople.sorted { ($0.order, $0.userID.uuidString) < ($1.order, $1.userID.uuidString) }
    }

    /// Photos in display order. Same story as `taggedPeopleOrdered` — SwiftData
    /// relationships are unordered sets.
    var photosOrdered: [Photo] {
        photos.sorted { $0.order < $1.order }
    }
}

/// One person tagged in one visit — the local mirror of a `visit_tags` row.
///
/// Its own model rather than an array of ids on `Visit` because it carries the
/// person's name and avatar too (see `Visit.taggedPeople`), and because the sync
/// engine needs to diff the set to know which rows to delete upstream.
@Model
final class VisitTag {
    /// The tagged person's `profiles.id`. Unique per visit, not globally —
    /// the same person appears in many visits.
    var userID: UUID
    var username: String?
    var displayName: String?
    var avatarURL: String?
    /// Position in the author's chosen order. Not synced: upstream ordering is
    /// by `created_at`, which reproduces the same sequence on any device that
    /// pulls the rows.
    var order: Int

    @Relationship var visit: Visit?

    init(
        userID: UUID,
        username: String? = nil,
        displayName: String? = nil,
        avatarURL: String? = nil,
        order: Int = 0,
        visit: Visit? = nil
    ) {
        self.userID = userID
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.order = order
        self.visit = visit
    }

    /// The shape every avatar and name view in the app already takes.
    var person: PersonSummary {
        PersonSummary(
            id: userID,
            username: username,
            displayName: displayName,
            avatarURL: avatarURL
        )
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

/// A photo the user removed from an already-synced visit that still has to be
/// deleted upstream.
///
/// Removing a `Photo` from `Visit.photos` locally is not the whole job: the
/// push pipeline only ever upserts the photos still attached to a visit, it
/// never deletes rows for ones that aren't — so a `visit_photos` row for a
/// removed photo would otherwise linger forever, and the next pull (which
/// merges remote rows by id, not "what's currently local") would recreate it.
/// Same shape as `PendingDeletion`, scoped to one photo instead of one visit.
///
/// Rows are created only for photos that had already synced (`remoteStoragePath
/// != nil`). A photo removed before it ever uploaded has nothing upstream to
/// tombstone.
@Model
final class PendingPhotoDeletion {
    @Attribute(.unique) var photoID: UUID
    var visitID: UUID
    var ownerUserID: UUID?
    var requestedAt: Date
    var attemptCount: Int = 0
    var nextAttemptAt: Date?
    /// Storage object paths owned by the deleted photo, so the bucket can be
    /// cleaned up in the same pass rather than leaking orphans.
    var storagePaths: [String] = []

    init(
        photoID: UUID,
        visitID: UUID,
        ownerUserID: UUID?,
        requestedAt: Date = Date(),
        storagePaths: [String] = []
    ) {
        self.photoID = photoID
        self.visitID = visitID
        self.ownerUserID = ownerUserID
        self.requestedAt = requestedAt
        self.storagePaths = storagePaths
    }
}

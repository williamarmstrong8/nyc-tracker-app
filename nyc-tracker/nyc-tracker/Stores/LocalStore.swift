import Foundation
import SwiftData
import SwiftUI
import CoreLocation

/// Shared SwiftData container for the whole app.
///
/// Now a *local mirror plus a write-ahead queue* rather than the source of truth
/// — Supabase holds that role, and `SyncEngine` moves rows between the two. What
/// hasn't changed is that every user-facing write lands here first and returns
/// immediately, which is what keeps the app fast and usable with no network.
enum LocalStore {
    /// Model types that make up the schema.
    static let schemaTypes: [any PersistentModel.Type] = [
        Place.self,
        Visit.self,
        Photo.self,
        VisitTag.self,
        PendingDeletion.self,
        PendingPhotoDeletion.self
    ]

    /// One shared, disk-backed container for the app.
    ///
    /// The in-memory fallback is a last resort for a container that refuses to
    /// open. It used to mean silently losing everything; now the pull sync
    /// rehydrates from the cloud on the next launch, so the blast radius is the
    /// rows that had not yet uploaded. Still bad, still worth a proper versioned
    /// migration before any schema change that SwiftData can't infer.
    @MainActor
    static let shared: ModelContainer = {
        do {
            let schema = Schema(schemaTypes)
            let configuration = ModelConfiguration(schema: schema)
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            do {
                let schema = Schema(schemaTypes)
                let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("SwiftData container could not be created: \(error)")
            }
        }
    }()

    // MARK: - User scoping

    /// The predicate every visit query in the app must apply.
    ///
    /// Cross-user scoping lives here, in one expression, on purpose. Two accounts
    /// on one device share a store file, and the failure mode of getting this
    /// wrong is not subtle — user B opens the app and sees user A's restaurants,
    /// notes and photos. Spreading the check across seven `@Query`
    /// declarations means seven chances to forget it and no single place to audit.
    ///
    /// `ownerUserID == nil` rows are deliberately excluded: those are pre-auth
    /// captures that have not been claimed yet. They are invisible until
    /// `SyncEngine` attributes them on first sign-in, which is the correct
    /// behaviour — an unclaimed row belongs to nobody and showing it to whoever
    /// signs in next is exactly the leak this guards against.
    static func visitsPredicate(for userID: UUID) -> Predicate<Visit> {
        // Bound as an explicit `UUID?` so the comparison inside the macro is
        // optional-to-optional. Comparing a `UUID?` column against a non-optional
        // `UUID` relies on implicit promotion, which `#Predicate` does not always
        // translate the way plain Swift would.
        let owner: UUID? = userID
        return #Predicate<Visit> { visit in
            visit.ownerUserID == owner
        }
    }

    static func placesPredicate(for userID: UUID) -> Predicate<Place> {
        let owner: UUID? = userID
        return #Predicate<Place> { place in
            place.ownerUserID == owner
        }
    }
}

// MARK: - Repository facade

/// Thin repository used by the capture flow so the UI doesn't touch ModelContext
/// directly.
///
/// This is where local-first is actually implemented: every method writes to
/// SwiftData, stamps the row for the sync queue, and returns. None of them is
/// `async` and none of them touches the network. `SyncEngine` observes the queue
/// afterwards.
@MainActor
struct VisitRepository {
    let context: ModelContext
    /// The signed-in user rows are attributed to. Optional only so previews and
    /// the pre-auth code paths still compile; in the running app it is always set.
    var userID: UUID?

    init(context: ModelContext, userID: UUID? = nil) {
        self.context = context
        self.userID = userID
    }

    func insert(place: Place, visit: Visit, photos: [Photo], tagged: [PersonSummary] = []) {
        for photo in photos {
            photo.visit = visit
        }
        visit.place = place
        place.ownerUserID = userID
        visit.ownerUserID = userID
        visit.remoteID = visit.id
        visit.markDirty()

        context.insert(place)
        context.insert(visit)
        photos.forEach { context.insert($0) }
        applyTags(tagged, to: visit)
        try? context.save()
    }

    /// Replace a visit's tagged people, then re-queue it.
    ///
    /// The whole set is rewritten rather than diffed. Tag sets are single digits,
    /// the rows carry no state worth preserving across an edit, and `SyncEngine`
    /// replaces them wholesale upstream anyway — a diff here would only be a
    /// second place for the two to disagree.
    func setTags(_ people: [PersonSummary], on visit: Visit) {
        applyTags(people, to: visit)
        visit.markDirty()
        try? context.save()
    }

    private func applyTags(_ people: [PersonSummary], to visit: Visit) {
        for existing in Array(visit.taggedPeople) {
            context.delete(existing)
        }

        for (index, person) in people.enumerated() {
            let tag = VisitTag(
                userID: person.id,
                username: person.username,
                displayName: person.displayName,
                avatarURL: person.avatarURL,
                order: index
            )
            context.insert(tag)
            tag.visit = visit
        }
    }

    func save() {
        try? context.save()
    }

    /// Persist an edit to an existing visit and re-queue it for upload.
    ///
    /// The one method every edit screen should call instead of `context.save()`.
    /// A saved-but-unqueued edit is the quietest possible bug: it looks right on
    /// this device forever and is simply absent from every other one.
    func saveEdit(to visit: Visit) {
        visit.markDirty()
        try? context.save()
    }

    /// An unvisited want-to-try for the same venue, if there is one.
    ///
    /// Matched on `externalPOIId` only — no name-and-distance fallback like
    /// `existingVisitedVisit` needs. Both sides of this comparison came from a
    /// MapKit result the user tapped, so either the identifiers match or these
    /// genuinely are two different places.
    ///
    /// Not private: `WantToTryView` checks this before inserting a want-to-try
    /// that started from a map POI, so tapping the same pin twice doesn't drop
    /// a second pin on top of the first.
    func existingWantToTry(matching candidate: VenueCandidate) -> Visit? {
        guard let poiID = candidate.externalPOIId, !poiID.isEmpty else { return nil }

        let places: [Place]
        if let userID {
            places = (try? context.fetch(
                FetchDescriptor<Place>(predicate: LocalStore.placesPredicate(for: userID))
            )) ?? []
        } else {
            places = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        }

        return places
            .first { $0.externalPOIId == poiID }?
            .visits
            .filter { $0.kind == .wantToTry }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    /// Look for a `Visit` (kind == .visited) at a place the user has already logged, so a repeat
    /// visit can be folded into the existing entry instead of creating a duplicate pin. Matches by
    /// `externalPOIId` first (same resolved MapKit venue), then falls back to a normalized name
    /// match within ~150m for venues that never got a confident POI match.
    func existingVisitedVisit(
        externalPOIId: String?,
        name: String,
        coordinate: CLLocationCoordinate2D
    ) -> Visit? {
        // Scoped: a repeat visit must never fold into another account's entry.
        let places: [Place]
        if let userID {
            places = (try? context.fetch(
                FetchDescriptor<Place>(predicate: LocalStore.placesPredicate(for: userID))
            )) ?? []
        } else {
            places = (try? context.fetch(FetchDescriptor<Place>())) ?? []
        }

        if let externalPOIId, !externalPOIId.isEmpty,
           let place = places.first(where: { $0.externalPOIId == externalPOIId }) {
            return mostRecentVisitedVisit(in: place)
        }

        let normalizedTarget = Self.normalize(name)
        guard !normalizedTarget.isEmpty else { return nil }
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        for place in places where Self.normalize(place.name) == normalizedTarget {
            let placeLocation = CLLocation(latitude: place.lat, longitude: place.lng)
            if targetLocation.distance(from: placeLocation) <= 150 {
                return mostRecentVisitedVisit(in: place)
            }
        }
        return nil
    }

    /// Fold a repeat visit into an existing entry: new photos append after the existing ones, the
    /// new note is appended date-stamped rather than overwriting the original, and tags merge in
    /// additively.
    func appendVisitOccasion(
        to visit: Visit,
        photos: [Photo],
        note: String,
        tags: [String],
        rating: Rating?,
        visitedOn: Date,
        tagged: [PersonSummary] = []
    ) {
        let startOrder = (visit.photos.map(\.order).max() ?? -1) + 1
        for (offset, photo) in photos.enumerated() {
            photo.order = startOrder + offset
            photo.visit = visit
            context.insert(photo)
        }

        // Date-stamped and appended, never replaced: the first occasion's note is
        // still true about the first occasion.
        if !note.isEmpty, note != visit.note {
            let stamp = visitedOn.formatted(.dateTime.month(.abbreviated).day().year())
            let entry = "— \(stamp) —\n\(note)"
            visit.note = visit.note.isEmpty ? entry : "\(visit.note)\n\n\(entry)"
        }

        if !tags.isEmpty {
            visit.tags = VenueTag.sorted(Array(Set(visit.tags).union(tags)))
        }
        // The verdict is the one field that replaces rather than merges — the
        // latest visit is the one that counts.
        if let rating { visit.rating = rating }
        visit.visitedOn = max(visit.visitedOn, visitedOn)

        // Additive, like tags and description: someone tagged on the first
        // occasion was still there for it, so a second occasion adds names
        // rather than replacing the list.
        if !tagged.isEmpty {
            let existingIDs = Set(visit.taggedPeople.map(\.userID))
            let merged = visit.taggedPeopleOrdered.map(\.person)
                + tagged.filter { !existingIDs.contains($0.id) }
            applyTags(merged, to: visit)
        }

        // The merged entry is new content the cloud hasn't seen, including the
        // freshly attached photos — which still need their objects uploaded.
        visit.markDirty()
        try? context.save()
    }

    // MARK: - Photo edits

    /// Append newly-picked photos to a persisted visit, ordered after
    /// whatever is already there, then re-queue the visit for upload.
    func addPhotos(_ photos: [Photo], to visit: Visit) {
        let startOrder = (visit.photos.map(\.order).max() ?? -1) + 1
        for (offset, photo) in photos.enumerated() {
            photo.order = startOrder + offset
            photo.visit = visit
            context.insert(photo)
        }
        visit.markDirty()
        try? context.save()
    }

    /// Reorder a persisted visit's photos in memory, live as the user drags —
    /// the same feel as the capture flow's array-backed photo strip, where
    /// dragging just reorders a plain `[PhotosPickerItem]` and nothing hits
    /// disk until the surrounding form is submitted.
    ///
    /// No `markDirty()` or `save()` here on purpose: `Photo` is a live
    /// SwiftData object, so the new order is visible immediately without
    /// either, and calling `context.save()` on every drag step — potentially
    /// several times per drag as the finger crosses each neighbor — is disk
    /// I/O the smoothness of a drag gesture shouldn't be paying for. The edit
    /// screen's own Save button (`saveEdit`) is what actually commits it, the
    /// same moment it commits every other field on the form; Cancel's
    /// `context.rollback()` un-does it the same way it un-does a title edit.
    func reorderPhotos(in visit: Visit, fromOffsets: IndexSet, toOffset: Int) {
        var ordered = visit.photosOrdered
        ordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (index, photo) in ordered.enumerated() {
            photo.order = index
        }
    }

    /// Remove one photo from a persisted visit: delete its on-disk copies,
    /// queue an upstream tombstone if it had already synced, close the gap in
    /// the remaining order, and re-queue the visit itself.
    func deletePhoto(_ photo: Photo, from visit: Visit) {
        if let path = photo.relativePath {
            FileStorage.shred(at: FileStorage.url(forRelativePath: path))
        }
        if let thumb = photo.thumbRelativePath {
            FileStorage.shred(at: FileStorage.url(forRelativePath: thumb))
        }

        // Only a photo that made it to the cloud has a row there to clean up.
        if let storagePath = photo.remoteStoragePath {
            context.insert(PendingPhotoDeletion(
                photoID: photo.id,
                visitID: visit.id,
                ownerUserID: visit.ownerUserID ?? userID,
                storagePaths: [storagePath, photo.remoteThumbPath].compactMap { $0 }
            ))
        }

        let remaining = visit.photosOrdered.filter { $0.id != photo.id }
        for (index, remainingPhoto) in remaining.enumerated() {
            remainingPhoto.order = index
        }

        context.delete(photo)
        visit.markDirty()
        try? context.save()
    }

    private func mostRecentVisitedVisit(in place: Place) -> Visit? {
        place.visits
            .filter { $0.kind == .visited }
            .sorted { $0.visitedOn > $1.visitedOn }
            .first
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Deletion

    /// Remove a Visit locally and queue the remote tombstone.
    ///
    /// Deleting is expected to be instant and to work offline, so the local row
    /// goes immediately and a `PendingDeletion` stands in for the unfinished
    /// remote half. `SyncEngine.drainDeletions` sets `deleted_at` upstream and
    /// removes the storage objects.
    ///
    /// A visit that never reached the cloud needs no tombstone — there is nothing
    /// upstream to mark — so it is simply removed. Enqueuing one anyway would
    /// leave a row that can never succeed, because the UPDATE would match zero
    /// rows and the tombstone would retry forever.
    func delete(_ visit: Visit) {
        let hasRemoteCounterpart = visit.lastSyncedAt != nil

        if hasRemoteCounterpart {
            let paths = visit.photos.flatMap { photo in
                [photo.remoteStoragePath, photo.remoteThumbPath].compactMap { $0 }
            }
            context.insert(PendingDeletion(
                visitID: visit.id,
                ownerUserID: visit.ownerUserID ?? userID,
                storagePaths: paths
            ))
        }

        cleanupFiles(for: visit)

        if let place = visit.place {
            let remainingVisits = place.visits.filter { $0.id != visit.id }
            if remainingVisits.isEmpty {
                context.delete(place)      // cascades to Visit → cascades to Photos
                try? context.save()
                return
            }
        }
        context.delete(visit)              // cascades to Photos
        try? context.save()
    }

    /// Remove on-disk photo copies owned by a visit.
    ///
    /// No audio branch any more: the voice memo is deleted the moment
    /// transcription finishes, so by the time a visit exists there is no audio
    /// file to clean up. `FileStorage.purgeAudioDirectory()` on launch covers
    /// anything a crash left behind.
    private func cleanupFiles(for visit: Visit) {
        for photo in visit.photos {
            if let path = photo.relativePath {
                FileStorage.shred(at: FileStorage.url(forRelativePath: path))
            }
            if let thumb = photo.thumbRelativePath {
                FileStorage.shred(at: FileStorage.url(forRelativePath: thumb))
            }
        }
    }
}

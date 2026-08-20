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
        PendingDeletion.self
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
    /// transcripts and photos. Spreading the check across seven `@Query`
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

    /// Save a want-to-try straight from a venue the user found in Apple Maps.
    ///
    /// The capture flow's own want-to-try path (`WantToTryView`) has to *guess*
    /// the venue from a typed name, photos, or OCR off a storefront sign. This
    /// one starts from an `MKMapItem` the user picked by hand, so there is
    /// nothing to infer: the name, coordinate, category and POI id all come
    /// from MapKit, and the entry is complete the moment it is created.
    ///
    /// Returns the new visit so the caller can pan the map to it — or the
    /// existing one, if this venue is already on the list. Saving the same place
    /// twice puts two pins at identical coordinates, which reads as a bug rather
    /// than as emphasis.
    @discardableResult
    func insertWantToTry(
        from candidate: VenueCandidate,
        neighborhood: String?
    ) -> Visit {
        if let existing = existingWantToTry(matching: candidate) {
            return existing
        }

        let place = Place(
            name: candidate.name,
            category: candidate.category,
            neighborhood: neighborhood ?? "NYC",
            lat: candidate.coordinate.latitude,
            lng: candidate.coordinate.longitude,
            externalPOIId: candidate.externalPOIId
        )

        let visit = Visit(
            title: candidate.name,
            address: candidate.address,
            // `.manual` rather than `.device`: the coordinate came from a venue
            // the user chose, not from where the phone happened to be.
            locationSource: .manual,
            kind: .wantToTry
        )

        insert(place: place, visit: visit, photos: [])
        return visit
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
    private func existingWantToTry(matching candidate: VenueCandidate) -> Visit? {
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
    /// new transcript is appended (date-stamped) rather than overwriting the original, and tags /
    /// description / rating merge in additively.
    func appendVisitOccasion(
        to visit: Visit,
        photos: [Photo],
        transcript: String,
        description: String,
        tags: [String],
        topQuote: String,
        rating: Rating?,
        returnIntent: ReturnIntent?,
        visitedOn: Date,
        tagged: [PersonSummary] = []
    ) {
        let startOrder = (visit.photos.map(\.order).max() ?? -1) + 1
        for (offset, photo) in photos.enumerated() {
            photo.order = startOrder + offset
            photo.visit = visit
            context.insert(photo)
        }

        if !transcript.isEmpty {
            let stamp = visitedOn.formatted(.dateTime.month(.abbreviated).day().year())
            let entry = "— \(stamp) —\n\(transcript)"
            visit.transcript = visit.transcript.isEmpty ? entry : "\(visit.transcript)\n\n\(entry)"
        }

        if !description.isEmpty, description != visit.enrichedDescription {
            visit.enrichedDescription = visit.enrichedDescription.isEmpty
                ? description
                : "\(visit.enrichedDescription)\n\n\(description)"
        }

        if !tags.isEmpty {
            visit.tags = Array(Set(visit.tags).union(tags)).sorted()
        }
        if !topQuote.isEmpty { visit.topQuote = topQuote }
        if let rating { visit.rating = rating }
        if let returnIntent { visit.returnIntent = returnIntent }
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

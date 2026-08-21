import Foundation
import CoreLocation
import SwiftData

/// Mirrors a saved wishlist place into the local **Want to try** list.
///
/// ## Why a mirror and not one list
///
/// The two lists answer to different owners. A wishlist item is a server row —
/// it can appear while the app is closed, because a friend sent it — and
/// `WishlistStore` deliberately does not live in SwiftData for that reason. The
/// Want to try list is authored: `Visit` rows with `kind == .wantToTry`, which
/// the map, the list, the filters, and the profile count all already read.
///
/// Saving from Explore has to land in both. Without the mirror the save is real
/// (the row exists upstream) and completely invisible: nothing on the map, the
/// list, or the profile moves, so the tap reads as a no-op.
///
/// ## What it refuses to do
///
/// - Never mirrors a place the user has already **been** to. A want-to-try pin
///   sitting on top of somewhere you wrote up is worse than no pin.
/// - Never creates a second entry for a place already in the local list.
/// - On unsave, only removes an entry it could plausibly have created — flagged
///   with `wishlistMirror`, or a bare want-to-try with no photos and no note.
///   A want-to-try the user wrote themselves is their writing; unsaving a
///   wishlist item must not delete it.
@MainActor
struct WantToTryMirror {
    let context: ModelContext
    let userID: UUID

    private var repository: VisitRepository {
        VisitRepository(context: context, userID: userID)
    }

    // MARK: - Save

    /// Add `place` to the local Want to try list. Idempotent.
    ///
    /// When `source` is a friend's visit, its photos, note, tags, and title are
    /// copied so the saved row opens in the same full write-up the user's own
    /// entries use. Returns whether a new entry was created or an existing mirror
    /// was enriched.
    @discardableResult
    func mirror(_ place: PlaceSummary, from source: FriendVisit? = nil) async -> Bool {
        if repository.existingVisitedVisit(
            externalPOIId: nil,
            name: place.name,
            coordinate: CLLocationCoordinate2D(
                latitude: place.latitude,
                longitude: place.longitude
            )
        ) != nil {
            return false
        }

        if let local = localPlace(forRemote: place.id),
           let existing = local.visits.first(where: { $0.kind == .wantToTry && $0.wishlistMirror }) {
            return await enrich(existing, from: source)
        }

        // Already represented locally under this remote id — a previous save, or
        // a pull of the same venue that is not a wishlist mirror.
        if let existing = localPlace(forRemote: place.id), !existing.visits.isEmpty {
            return false
        }

        let local = Place(
            name: place.name,
            category: place.category,
            neighborhood: place.neighborhood ?? "",
            lat: place.latitude,
            lng: place.longitude,
            remotePlaceID: place.id,
            ownerUserID: userID
        )

        let visit = Visit(
            title: source?.headline ?? place.name,
            tags: source?.tags ?? [],
            note: trimmedNote(from: source),
            address: place.streetAddress,
            locationSource: .manual,
            kind: .wantToTry
        )
        visit.wishlistMirror = true

        let photos = await photos(from: source)
        repository.insert(place: local, visit: visit, photos: photos)
        return true
    }

    // MARK: - Remove

    /// Drop the mirrored entry for `placeID`, if one is still there and still
    /// looks like a mirror rather than something the user wrote.
    @discardableResult
    func removeMirror(placeID: UUID) -> Bool {
        guard let local = localPlace(forRemote: placeID) else { return false }

        let candidates = local.visits.filter {
            $0.kind == .wantToTry
                && ($0.wishlistMirror || ($0.photos.isEmpty && $0.note.isEmpty))
        }
        guard !candidates.isEmpty else { return false }

        for visit in candidates {
            repository.delete(visit)
        }
        return true
    }

    // MARK: - Enrichment

    /// Fill in content on a bare mirror row — e.g. the wishlist refresh ran
    /// before the user opened the friend's write-up and tapped Save.
    @discardableResult
    private func enrich(_ visit: Visit, from source: FriendVisit?) async -> Bool {
        guard let source else { return false }

        var changed = false

        if visit.note.isEmpty {
            let note = trimmedNote(from: source)
            if !note.isEmpty {
                visit.note = note
                changed = true
            }
        }
        if visit.tags.isEmpty, !source.tags.isEmpty {
            visit.tags = source.tags
            changed = true
        }
        if visit.title == visit.place?.name || visit.title.isEmpty,
           visit.title != source.headline {
            visit.title = source.headline
            changed = true
        }
        if visit.photos.isEmpty {
            let photos = await photos(from: source)
            if !photos.isEmpty {
                for photo in photos {
                    photo.visit = visit
                    context.insert(photo)
                }
                changed = true
            }
        }

        guard changed else { return false }
        visit.markDirty()
        try? context.save()
        return true
    }

    // MARK: - Photos

    /// Copy a friend's photos into Application Support so the mirrored visit
    /// renders offline and sync uploads the user's own objects upstream.
    private func photos(from source: FriendVisit?) async -> [Photo] {
        guard let source, !source.photos.isEmpty else { return [] }

        var rows: [Photo] = []
        let ordered = source.photos.sorted { $0.sortOrder < $1.sortOrder }

        for (index, friendPhoto) in ordered.enumerated() {
            guard let fullURL = await resolvedFileURL(for: friendPhoto.storagePath),
                  let fullData = try? Data(contentsOf: fullURL),
                  let stored = try? FileStorage.writeData(fullData, kind: .photos, fileExtension: "jpg")
            else { continue }

            var thumbRelativePath: String?
            if let thumbPath = friendPhoto.thumbPath,
               let thumbURL = await resolvedFileURL(for: thumbPath),
               let thumbData = try? Data(contentsOf: thumbURL),
               let storedThumb = try? FileStorage.writeData(thumbData, kind: .photos, fileExtension: "jpg") {
                thumbRelativePath = storedThumb.relativePath
            }

            rows.append(Photo(
                relativePath: stored.relativePath,
                thumbRelativePath: thumbRelativePath,
                order: index
            ))
        }

        return rows
    }

    private func resolvedFileURL(for path: String) async -> URL? {
        if path.hasPrefix("asset:") { return nil }
        if path.hasPrefix("local:") {
            let relative = String(path.dropFirst("local:".count))
            let url = FileStorage.url(forRelativePath: relative)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return await PhotoCache.shared.file(for: path)
    }

    private func trimmedNote(from source: FriendVisit?) -> String {
        guard let summary = source?.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return ""
        }
        return summary
    }

    // MARK: - Lookup

    private func localPlace(forRemote remoteID: UUID) -> Place? {
        // Both bound as optionals so the macro compares like-for-like against the
        // nullable columns — same reason as `LocalStore.visitsPredicate`.
        let remote: UUID? = remoteID
        let owner: UUID? = userID
        let descriptor = FetchDescriptor<Place>(
            predicate: #Predicate<Place> { place in
                place.remotePlaceID == remote && place.ownerUserID == owner
            }
        )
        return try? context.fetch(descriptor).first
    }
}

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
/// - On unsave, only removes an entry it could plausibly have created — a
///   want-to-try with no photos and no transcript. A want-to-try the user typed
///   themselves, with a voice note and pictures, is their writing; unsaving a
///   wishlist item must not delete it.
struct WantToTryMirror {
    let context: ModelContext
    let userID: UUID

    private var repository: VisitRepository {
        VisitRepository(context: context, userID: userID)
    }

    // MARK: - Save

    /// Add `place` to the local Want to try list. Idempotent.
    ///
    /// Returns whether a new entry was created, so the caller can tell "saved"
    /// from "already there" without re-querying.
    @discardableResult
    func mirror(_ place: PlaceSummary) -> Bool {
        // Already represented locally under this remote id — a previous save, or
        // a pull of the same venue.
        if let existing = localPlace(forRemote: place.id), !existing.visits.isEmpty {
            return false
        }

        // Same venue, different local row: the user logged it before it was ever
        // deduped upstream. Reuses the repository's POI/name/150m matching so the
        // rule is the same one the capture flow uses.
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
            title: place.name,
            address: place.streetAddress,
            locationSource: .manual,
            kind: .wantToTry
        )

        repository.insert(place: local, visit: visit, photos: [])
        return true
    }

    // MARK: - Remove

    /// Drop the mirrored entry for `placeID`, if one is still there and still
    /// looks like a mirror rather than something the user wrote.
    @discardableResult
    func removeMirror(placeID: UUID) -> Bool {
        guard let local = localPlace(forRemote: placeID) else { return false }

        let candidates = local.visits.filter {
            $0.kind == .wantToTry && $0.photos.isEmpty && $0.transcript.isEmpty
        }
        guard !candidates.isEmpty else { return false }

        for visit in candidates {
            repository.delete(visit)
        }
        return true
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

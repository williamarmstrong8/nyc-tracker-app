import Foundation
import SwiftData
import SwiftUI
import CoreLocation

/// Shared SwiftData container for the whole app. Kept behind a store-shaped facade so the eventual
/// remote-sync layer can replace the persistence layer without touching the UI.
enum LocalStore {
    /// Model types that make up the schema.
    static let schemaTypes: [any PersistentModel.Type] = [
        Place.self,
        Visit.self,
        Photo.self
    ]

    /// One shared, disk-backed container for the app.
    @MainActor
    static let shared: ModelContainer = {
        do {
            let schema = Schema(schemaTypes)
            let configuration = ModelConfiguration(schema: schema)
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Fall back to an in-memory container so the app still runs (e.g. after a schema change).
            do {
                let schema = Schema(schemaTypes)
                let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("SwiftData container could not be created: \(error)")
            }
        }
    }()
}

// MARK: - Repository facade

/// Thin repository used by the capture flow so the UI doesn't touch ModelContext directly.
/// This is the seam the remote-sync layer will slot into later.
@MainActor
struct VisitRepository {
    let context: ModelContext

    func insert(place: Place, visit: Visit, photos: [Photo]) {
        for photo in photos {
            photo.visit = visit
        }
        visit.place = place
        context.insert(place)
        context.insert(visit)
        photos.forEach { context.insert($0) }
        try? context.save()
    }

    func save() {
        try? context.save()
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
        let places = (try? context.fetch(FetchDescriptor<Place>())) ?? []

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
        visitedOn: Date
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

    /// Remove a Visit + its Photos (via cascade) and any Place that no longer has visits attached.
    /// Also cleans up on-disk audio + photo files owned by the removed rows.
    func delete(_ visit: Visit) {
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

    private func cleanupFiles(for visit: Visit) {
        let fm = FileManager.default
        if let audioPath = visit.audioRelativePath {
            try? fm.removeItem(at: FileStorage.url(forRelativePath: audioPath))
        }
        for photo in visit.photos {
            if let path = photo.relativePath {
                try? fm.removeItem(at: FileStorage.url(forRelativePath: path))
            }
        }
    }
}

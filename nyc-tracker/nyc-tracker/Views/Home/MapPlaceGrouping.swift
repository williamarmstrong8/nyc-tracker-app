import Foundation
import CoreLocation
import MapKit

// ============================================================================
// One annotation per PLACE, not per visit.
// ============================================================================
// Four friends at the same restaurant is one pin. Rendering per visit produces a
// stack of identical markers at identical coordinates, which is unreadable and
// makes "who's been here" impossible to answer by looking.
//
// The grouping key is the interesting part. Own visits live in SwiftData and
// friend visits arrive from `visits_in_bounds`, and they have to collapse onto
// the same pin when they are the same venue — that is verification step 6. The
// join is `Place.remotePlaceID`, which the sync engine already stores when
// `find_or_create_place()` resolves a local place onto the shared row.
// ============================================================================

/// Identity for a pin.
///
/// A local place that has not synced yet has no remote id, so it groups under
/// its own local id and simply won't merge with a friend's visit to the same
/// venue until it syncs. That is the honest behaviour: before the round trip
/// nothing on the device knows the two are the same venue, and guessing by name
/// and proximity is what `find_or_create_place()` exists to do properly.
enum PlaceKey: Hashable {
    case remote(UUID)
    case local(UUID)
}

/// So a selected place can drive `.sheet(item:)` directly.
///
/// The map holds the *key* rather than the group it belongs to: the group is
/// recomputed whenever the visits change, and a captured copy would keep showing
/// a friend's visits after they were unfriended.
extension PlaceKey: Identifiable {
    var id: PlaceKey { self }
}

/// Everything to draw at one coordinate.
struct MapPlaceGroup: Identifiable {
    let key: PlaceKey
    let name: String
    let category: PlaceCategory
    let coordinate: CLLocationCoordinate2D
    /// The signed-in user's own visits here, newest first.
    var ownVisits: [Visit]
    /// Friends' visits here, newest first.
    var friendVisits: [FriendVisit]

    var id: PlaceKey { key }

    var hasOwnVisit: Bool { !ownVisits.isEmpty }
    var visitCount: Int { ownVisits.count + friendVisits.count }

    /// Distinct friends who have been here, in first-seen order so the avatar
    /// stack is stable between renders.
    var friendIDs: [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for visit in friendVisits where seen.insert(visit.userID).inserted {
            ordered.append(visit.userID)
        }
        return ordered
    }

    /// The people behind `friendIDs`, for avatar stacks.
    var friendPeople: [PersonSummary] {
        var seen = Set<UUID>()
        return friendVisits.compactMap { visit in
            guard seen.insert(visit.userID).inserted else { return nil }
            return visit.person
        }
    }

    /// True when this pin is only the user's own visits — drives the "yours" tint.
    var isOwnOnly: Bool { friendVisits.isEmpty }

    /// A want-to-try pin looks different from a visited one. Own bookmarks win
    /// the styling only when there is nothing else here.
    var isWantToTryOnly: Bool {
        let ownAllWant = ownVisits.allSatisfy { $0.kind == .wantToTry }
        let friendsAllWant = friendVisits.allSatisfy { $0.visitKind == .wantToTry }
        return ownAllWant && friendsAllWant && visitCount > 0
    }
}

/// A cluster of place groups drawn as a single badge at low zoom.
struct MapCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let groups: [MapPlaceGroup]

    /// The badge shows PLACES, not visits. "12" next to a cluster has to mean
    /// twelve venues — a count of visits would make one heavily-logged bar read
    /// as a whole neighbourhood.
    var placeCount: Int { groups.count }

    var isSingle: Bool { groups.count == 1 }
    var single: MapPlaceGroup? { groups.first }

    var containsOwnVisit: Bool { groups.contains(where: \.hasOwnVisit) }
}

enum MapPlaceGrouping {

    // MARK: - Grouping

    /// Collapse own visits and friend visits into one group per place.
    static func groups(
        ownVisits: [Visit],
        friendVisits: [FriendVisit]
    ) -> [MapPlaceGroup] {
        var accumulator: [PlaceKey: MapPlaceGroup] = [:]
        // Insertion order kept separately so pin identity is stable frame to
        // frame; a dictionary's order is not.
        var order: [PlaceKey] = []

        for visit in ownVisits {
            guard let place = visit.place else { continue }
            let key: PlaceKey = place.remotePlaceID.map(PlaceKey.remote) ?? .local(place.id)

            if var existing = accumulator[key] {
                existing.ownVisits.append(visit)
                accumulator[key] = existing
            } else {
                accumulator[key] = MapPlaceGroup(
                    key: key,
                    name: place.name,
                    category: place.category,
                    coordinate: place.coordinate,
                    ownVisits: [visit],
                    friendVisits: []
                )
                order.append(key)
            }
        }

        for visit in friendVisits {
            let key = PlaceKey.remote(visit.placeID)

            if var existing = accumulator[key] {
                existing.friendVisits.append(visit)
                accumulator[key] = existing
            } else {
                accumulator[key] = MapPlaceGroup(
                    key: key,
                    // The venue name from `places` rather than the friend's
                    // personal title: the pin labels a place, and their title
                    // may be "Katz's, 2am".
                    name: visit.placeName,
                    category: visit.category,
                    coordinate: CLLocationCoordinate2D(
                        latitude: visit.latitude,
                        longitude: visit.longitude
                    ),
                    ownVisits: [],
                    friendVisits: [visit]
                )
                order.append(key)
            }
        }

        return order.compactMap { key in
            guard var group = accumulator[key] else { return nil }
            group.ownVisits.sort { $0.visitedOn > $1.visitedOn }
            group.friendVisits.sort { $0.visitedAt > $1.visitedAt }
            return group
        }
    }

    // MARK: - Clustering

    /// Number of cells across the visible width. Higher means smaller cells and
    /// less aggressive clustering. 14 keeps clusters roughly a thumb-width apart
    /// at any zoom, which is the useful property — cluster size in *screen* terms
    /// stays constant even though the geographic cell shrinks as you zoom in.
    private static let cellsAcross: Double = 14

    /// Grid-cluster groups against the visible region.
    ///
    /// A grid rather than true distance clustering (k-means, DBSCAN): those are
    /// O(n²)-ish and have to re-run on every camera change, whereas this is one
    /// pass with a dictionary. At the scale this map ever reaches — a few hundred
    /// pins in view — the visual difference is negligible and the cost is not.
    static func clusters(
        for groups: [MapPlaceGroup],
        in region: MKCoordinateRegion
    ) -> [MapCluster] {
        guard !groups.isEmpty else { return [] }

        let latCell = max(region.span.latitudeDelta / cellsAcross, 1e-9)
        let lngCell = max(region.span.longitudeDelta / cellsAcross, 1e-9)

        var buckets: [String: [MapPlaceGroup]] = [:]
        var order: [String] = []

        for group in groups {
            let latIndex = (group.coordinate.latitude / latCell).rounded(.down)
            let lngIndex = (group.coordinate.longitude / lngCell).rounded(.down)
            let id = "\(latIndex)|\(lngIndex)"

            if buckets[id] == nil {
                buckets[id] = []
                order.append(id)
            }
            buckets[id]?.append(group)
        }

        return order.compactMap { id in
            guard let bucket = buckets[id], !bucket.isEmpty else { return nil }
            return MapCluster(
                id: id,
                // Centroid of the members rather than the cell centre, so a
                // cluster sits on its pins instead of floating off-centre in a
                // sparsely occupied cell.
                coordinate: centroid(of: bucket),
                groups: bucket
            )
        }
    }

    private static func centroid(of groups: [MapPlaceGroup]) -> CLLocationCoordinate2D {
        guard !groups.isEmpty else {
            return CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        let count = Double(groups.count)
        let lat = groups.reduce(0.0) { $0 + $1.coordinate.latitude } / count
        let lng = groups.reduce(0.0) { $0 + $1.coordinate.longitude } / count
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

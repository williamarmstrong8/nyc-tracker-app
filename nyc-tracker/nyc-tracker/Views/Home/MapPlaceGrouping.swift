import Foundation
import CoreLocation

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
}
